import Foundation
import Testing

/// Serves canned responses to a `URLSession`. Handlers are keyed by a per-session id header so tests
/// that run in parallel never see each other's requests.
final class StubURLProtocol: URLProtocol, @unchecked Sendable {
  typealias Handler = @Sendable (URLRequest) throws -> (status: Int, body: Data)
  typealias ReplyHandler = @Sendable (URLRequest) -> StubReply

  private static let idHeader = "X-Stub-ID"
  private static let lock = NSLock()
  nonisolated(unsafe) private static var handlers: [String: Handler] = [:]
  nonisolated(unsafe) private static var requests: [String: [URLRequest]] = [:]
  nonisolated(unsafe) private static var replyHandlers: [String: ReplyHandler] = [:]
  nonisolated(unsafe) private static var inFlightCounts: [String: Int] = [:]
  nonisolated(unsafe) private static var maxInFlightCounts: [String: Int] = [:]

  /// A session whose requests are answered by `handler`.
  static func session(_ handler: @escaping Handler) -> (session: URLSession, id: String) {
    let id = UUID().uuidString
    lock.withLock { handlers[id] = handler }
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [StubURLProtocol.self]
    configuration.httpAdditionalHeaders = [idHeader: id]
    return (URLSession(configuration: configuration), id)
  }

  /// A session whose requests are answered by `reply`. Unlike `session(_:)` it can serve partial
  /// bodies, delay, fail, or hold a response until a `StubGate` opens. Also tracks in-flight requests.
  static func session(reply: @escaping ReplyHandler) -> (session: URLSession, id: String) {
    let id = UUID().uuidString
    lock.withLock { replyHandlers[id] = reply }
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [StubURLProtocol.self]
    configuration.httpAdditionalHeaders = [idHeader: id]
    return (URLSession(configuration: configuration), id)
  }

  /// Requests of session `id` that have started and not yet finished, failed or been cancelled.
  static func inFlight(_ id: String) -> Int { lock.withLock { inFlightCounts[id] ?? 0 } }
  /// The highest `inFlight` value session `id` ever reached.
  static func maxInFlight(_ id: String) -> Int { lock.withLock { maxInFlightCounts[id] ?? 0 } }

  /// Requests seen so far by the session `id`, oldest first.
  static func seen(_ id: String) -> [URLRequest] { lock.withLock { requests[id] ?? [] } }

  override class func canInit(with request: URLRequest) -> Bool { true }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

  private let stateLock = NSLock()
  private var finished = false

  /// Marks the request as over. Returns false when it already was, so counters drop exactly once.
  private func finishOnce() -> Bool {
    let first = stateLock.withLock { () -> Bool in
      if finished { return false }
      finished = true
      return true
    }
    if first {
      let id = request.value(forHTTPHeaderField: Self.idHeader) ?? ""
      Self.lock.withLock { Self.inFlightCounts[id, default: 0] -= 1 }
    }
    return first
  }

  private var isFinished: Bool { stateLock.withLock { finished } }

  override func startLoading() {
    let id = request.value(forHTTPHeaderField: Self.idHeader) ?? ""
    let (handler, replyHandler) = Self.lock.withLock { () -> (Handler?, ReplyHandler?) in
      Self.requests[id, default: []].append(request)
      Self.inFlightCounts[id, default: 0] += 1
      Self.maxInFlightCounts[id] = max(
        Self.maxInFlightCounts[id] ?? 0, Self.inFlightCounts[id] ?? 0)
      return (Self.handlers[id], Self.replyHandlers[id])
    }
    if let replyHandler {
      perform(replyHandler(request))
      return
    }
    guard let handler else {
      if finishOnce() { client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL)) }
      return
    }
    do {
      let (status, body) = try handler(request)
      deliver(status: status, headers: [:], body: body, sending: body.count, failWith: nil)
    } catch {
      if finishOnce() { client?.urlProtocol(self, didFailWithError: error) }
    }
  }

  /// Never blocks: delays and holds hop through GCD or the gate's callback list.
  private func perform(_ reply: StubReply) {
    switch reply {
    case .response(let status, let body, let headers, let delay):
      after(delay) {
        self.deliver(status: status, headers: headers, body: body, sending: body.count, failWith: nil)
      }
    case .truncated(let status, let body, let headers, let sending, let code):
      deliver(
        status: status, headers: headers, body: body, sending: min(sending, body.count),
        failWith: URLError(code))
    case .failure(let code):
      if finishOnce() { client?.urlProtocol(self, didFailWithError: URLError(code)) }
    case .held(let gate, let then):
      gate.notify { self.perform(then) }
    }
  }

  private func after(_ delay: Duration, _ work: @escaping @Sendable () -> Void) {
    if delay == .zero {
      work()
      return
    }
    let seconds = Double(delay.components.seconds) + Double(delay.components.attoseconds) / 1e18
    DispatchQueue.global().asyncAfter(deadline: .now() + seconds, execute: work)
  }

  private func deliver(
    status: Int, headers: [String: String], body: Data, sending: Int, failWith error: URLError?
  ) {
    guard !isFinished else { return }
    var fields = headers
    if fields["Content-Length"] == nil { fields["Content-Length"] = String(body.count) }
    let response = HTTPURLResponse(
      url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: fields)!
    client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
    if sending > 0 { client?.urlProtocol(self, didLoad: Data(body.prefix(sending))) }
    if let error {
      // Give the session a moment to hand the delivered bytes to the consumer before the drop.
      after(.milliseconds(50)) {
        guard self.finishOnce() else { return }
        self.client?.urlProtocol(self, didFailWithError: error)
      }
      return
    }
    guard finishOnce() else { return }
    client?.urlProtocolDidFinishLoading(self)
  }

  override func stopLoading() { _ = finishOnce() }
}

enum Fixture {
  static func data(_ name: String, _ ext: String) throws -> Data {
    let url = try #require(
      Bundle.module.url(forResource: name, withExtension: ext, subdirectory: "Fixtures"))
    return try Data(contentsOf: url)
  }
}

/// What `StubURLProtocol.session(reply:)` should do with one request.
indirect enum StubReply: Sendable {
  /// Answer with `status` and `body` after `delay`. `Content-Length` defaults to the body size.
  case response(status: Int, body: Data, headers: [String: String] = [:], delay: Duration = .zero)
  /// Answer with the headers and only the first `sending` bytes of `body`, then fail the connection.
  case truncated(status: Int, body: Data, headers: [String: String] = [:], sending: Int, error: URLError.Code = .networkConnectionLost)
  /// Fail without any response.
  case failure(URLError.Code)
  /// Do nothing until `gate` opens, then behave as `then`. A request cancelled meanwhile never answers.
  case held(StubGate, then: StubReply)
}

/// A one-shot latch a test opens to let held requests continue.
final class StubGate: @unchecked Sendable {
  private let lock = NSLock()
  private var isOpen = false
  private var waiters: [@Sendable () -> Void] = []

  func open() {
    let pending = lock.withLock { () -> [@Sendable () -> Void] in
      isOpen = true
      defer { waiters = [] }
      return waiters
    }
    for waiter in pending { waiter() }
  }

  /// Runs `work` once the gate is open (immediately if it already is). Never blocks.
  func notify(_ work: @escaping @Sendable () -> Void) {
    let runNow = lock.withLock { () -> Bool in
      if !isOpen { waiters.append(work) }
      return isOpen
    }
    if runNow { work() }
  }
}
