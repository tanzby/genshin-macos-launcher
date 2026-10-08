import Foundation
import Testing

/// Serves canned responses to a `URLSession`. Handlers are keyed by a per-session id header so tests
/// that run in parallel never see each other's requests.
final class StubURLProtocol: URLProtocol, @unchecked Sendable {
  typealias Handler = @Sendable (URLRequest) throws -> (status: Int, body: Data)

  private static let idHeader = "X-Stub-ID"
  private static let lock = NSLock()
  nonisolated(unsafe) private static var handlers: [String: Handler] = [:]
  nonisolated(unsafe) private static var requests: [String: [URLRequest]] = [:]

  /// A session whose requests are answered by `handler`.
  static func session(_ handler: @escaping Handler) -> (session: URLSession, id: String) {
    let id = UUID().uuidString
    lock.withLock { handlers[id] = handler }
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [StubURLProtocol.self]
    configuration.httpAdditionalHeaders = [idHeader: id]
    return (URLSession(configuration: configuration), id)
  }

  /// Requests seen so far by the session `id`, oldest first.
  static func seen(_ id: String) -> [URLRequest] { lock.withLock { requests[id] ?? [] } }

  override class func canInit(with request: URLRequest) -> Bool { true }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

  override func startLoading() {
    let id = request.value(forHTTPHeaderField: Self.idHeader) ?? ""
    let handler = Self.lock.withLock { () -> Handler? in
      Self.requests[id, default: []].append(request)
      return Self.handlers[id]
    }
    guard let handler else {
      client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
      return
    }
    do {
      let (status, body) = try handler(request)
      let response = HTTPURLResponse(
        url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)!
      client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
      client?.urlProtocol(self, didLoad: body)
      client?.urlProtocolDidFinishLoading(self)
    } catch {
      client?.urlProtocol(self, didFailWithError: error)
    }
  }

  override func stopLoading() {}
}

enum Fixture {
  static func data(_ name: String, _ ext: String) throws -> Data {
    let url = try #require(
      Bundle.module.url(forResource: name, withExtension: ext, subdirectory: "Fixtures"))
    return try Data(contentsOf: url)
  }
}
