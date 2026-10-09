import CryptoKit
import Foundation
import Testing

@testable import Platform

// A URLProtocol stub that behaves like a Range-capable server: 206 + Content-Range for `bytes=N-`, 416 when N is
// at or past the end, optionally dropping the connection after `failAfter` bytes of a response.
private final class RangeStubProtocol: URLProtocol, @unchecked Sendable {
  struct Server: Sendable {
    var body: Data
    var supportsRange = true
    var failAfter: Int?
    var chunkSize = 50_000
    /// Seconds to wait before each chunk, so a test can act mid-download.
    var chunkDelay: TimeInterval = 0
  }

  nonisolated(unsafe) private static var servers: [URL: Server] = [:]
  nonisolated(unsafe) private static var rangeHeaders: [URL: [String?]] = [:]
  private static let lock = NSLock()

  static func register(_ server: Server, for url: URL) {
    lock.withLock {
      servers[url] = server
      rangeHeaders[url] = []
    }
  }
  static func update(_ url: URL, _ change: (inout Server) -> Void) { lock.withLock { change(&servers[url]!) } }
  static func requests(for url: URL) -> [String?] { lock.withLock { rangeHeaders[url] ?? [] } }
  static func unregister(_ url: URL) {
    lock.withLock {
      servers.removeValue(forKey: url)
      rangeHeaders.removeValue(forKey: url)
    }
  }

  override class func canInit(with request: URLRequest) -> Bool { true }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

  private let stopped = LockedFlag()

  override func startLoading() {
    guard let url = request.url, let server = Self.lock.withLock({ Self.servers[url] }) else {
      client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
      return
    }
    let range = request.value(forHTTPHeaderField: "Range")
    Self.lock.withLock { Self.rangeHeaders[url, default: []].append(range) }
    let total = server.body.count
    var start = 0
    if server.supportsRange, let range, range.hasPrefix("bytes="), range.hasSuffix("-"),
      let from = Int(range.dropFirst(6).dropLast())
    {
      start = from
    }
    var headers: [String: String] = [:]
    var status = 200
    if start > 0 {
      if start >= total {
        status = 416
        headers["Content-Range"] = "bytes */\(total)"
        headers["Content-Length"] = "0"
      } else {
        status = 206
        headers["Content-Range"] = "bytes \(start)-\(total - 1)/\(total)"
        headers["Content-Length"] = String(total - start)
      }
    } else {
      headers["Content-Length"] = String(total)
    }
    let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
    client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
    if status != 416 {
      var offset = start
      var sent = 0
      while offset < total {
        if stopped.isSet { return }
        if server.chunkDelay > 0 { Thread.sleep(forTimeInterval: server.chunkDelay) }
        if let failAfter = server.failAfter, sent >= failAfter {
          client?.urlProtocol(self, didFailWithError: URLError(.networkConnectionLost))
          return
        }
        let end = min(offset + server.chunkSize, total)
        client?.urlProtocol(self, didLoad: server.body.subdata(in: offset..<end))
        sent += end - offset
        offset = end
      }
    }
    client?.urlProtocolDidFinishLoading(self)
  }

  override func stopLoading() { stopped.set() }
}

private final class LockedFlag: @unchecked Sendable {
  private let lock = NSLock()
  private var value = false
  var isSet: Bool { lock.withLock { value } }
  func set() { lock.withLock { value = true } }
}

private final class ResumeProgressBox: @unchecked Sendable {
  private let lock = NSLock()
  private var items: [DownloadProgress] = []
  func add(_ p: DownloadProgress) { lock.withLock { items.append(p) } }
  var all: [DownloadProgress] { lock.withLock { items } }
}

private func sha(_ data: Data) -> String {
  SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

private let body = Data((0..<300_000).map { UInt8($0 % 251) })

private func withResumeFixture(
  server: RangeStubProtocol.Server = .init(body: body),
  _ test: (Downloader, URL, URL, URL) async throws -> Void
) async throws {
  let dir = FileManager.default.temporaryDirectory
    .appending(path: "yaagl-resume-test-\(UUID().uuidString)", directoryHint: .isDirectory)
  try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
  let url = URL(string: "https://downloads.invalid/\(UUID().uuidString)/archive.bin")!
  RangeStubProtocol.register(server, for: url)
  defer {
    RangeStubProtocol.unregister(url)
    try? FileManager.default.removeItem(at: dir)
  }
  let configuration = URLSessionConfiguration.ephemeral
  configuration.protocolClasses = [RangeStubProtocol.self]
  try await test(Downloader(configuration: configuration), url, dir.appending(path: "archive.bin"), dir)
}

private func partFile(of destination: URL) -> URL { URL(filePath: destination.path + ".part") }

@Suite("WIN-007 resumable download") struct DownloaderResumeTests {
  @Test("WIN-007 a dropped connection keeps the partial file and the next attempt sends Range from its size")
  func resumesAfterDroppedConnection() async throws {
    var server = RangeStubProtocol.Server(body: body)
    server.failAfter = 100_000
    try await withResumeFixture(server: server) { downloader, url, destination, _ in
      await #expect(throws: (any Error).self) {
        try await downloader.download(from: url, to: destination, sha256: sha(body)) { _ in }
      }
      #expect(!FileManager.default.fileExists(atPath: destination.path))
      let partial = try Data(contentsOf: partFile(of: destination))
      #expect(partial == body.prefix(100_000))

      RangeStubProtocol.update(url) { $0.failAfter = nil }
      let box = ResumeProgressBox()
      try await downloader.download(from: url, to: destination, sha256: sha(body)) { box.add($0) }

      #expect(RangeStubProtocol.requests(for: url) == [nil, "bytes=100000-"])
      #expect(try Data(contentsOf: destination) == body)
      #expect(!FileManager.default.fileExists(atPath: partFile(of: destination).path))
      // progress continues from the resumed offset and reports the full size
      #expect(box.all.first.map { $0.completed >= 100_000 } == true)
      #expect(box.all.allSatisfy { $0.total == Int64(body.count) })
      #expect(zip(box.all, box.all.dropFirst()).allSatisfy { $0.completed <= $1.completed })
      #expect(box.all.last?.completed == Int64(body.count))
    }
  }

  @Test("WIN-007 a server that ignores Range (200) makes the download start over instead of appending")
  func serverIgnoringRange() async throws {
    var server = RangeStubProtocol.Server(body: body)
    server.supportsRange = false
    try await withResumeFixture(server: server) { downloader, url, destination, _ in
      try Data(repeating: 0xAB, count: 100_000).write(to: partFile(of: destination))
      try await downloader.download(from: url, to: destination, sha256: sha(body)) { _ in }
      #expect(try Data(contentsOf: destination) == body)
    }
  }

  @Test("WIN-007 a complete partial file and a 416 answer finish without downloading again")
  func completePartialWith416() async throws {
    try await withResumeFixture { downloader, url, destination, _ in
      try body.write(to: partFile(of: destination))
      try await downloader.download(from: url, to: destination, sha256: sha(body)) { _ in }
      #expect(try Data(contentsOf: destination) == body)
      #expect(RangeStubProtocol.requests(for: url) == [("bytes=\(body.count)-")])
    }
  }

  @Test("WIN-007 a stale partial file that no longer matches the checksum is dropped and fetched fresh once")
  func stalePartialRetriedFromScratch() async throws {
    try await withResumeFixture { downloader, url, destination, _ in
      try Data(repeating: 0xCD, count: 100_000).write(to: partFile(of: destination))
      try await downloader.download(from: url, to: destination, sha256: sha(body)) { _ in }
      #expect(try Data(contentsOf: destination) == body)
      #expect(RangeStubProtocol.requests(for: url) == ["bytes=100000-", nil])
    }
  }

  @Test("WIN-007 a fresh download with a wrong checksum fails once and leaves no partial file")
  func freshMismatchLeavesNothing() async throws {
    try await withResumeFixture { downloader, url, destination, _ in
      let wrong = String(repeating: "0", count: 64)
      await #expect(throws: DownloadError.checksumMismatch(expected: wrong, actual: sha(body))) {
        try await downloader.download(from: url, to: destination, sha256: wrong) { _ in }
      }
      #expect(RangeStubProtocol.requests(for: url) == [nil])
      #expect(!FileManager.default.fileExists(atPath: partFile(of: destination).path))
      #expect(!FileManager.default.fileExists(atPath: destination.path))
    }
  }

  @Test("WIN-007 a destination that already matches the checksum is not downloaded again")
  func cachedArchiveIsReused() async throws {
    try await withResumeFixture { downloader, url, destination, _ in
      try body.write(to: destination)
      let box = ResumeProgressBox()
      try await downloader.download(from: url, to: destination, sha256: sha(body)) { box.add($0) }
      #expect(RangeStubProtocol.requests(for: url).isEmpty)
      #expect(box.all.last == DownloadProgress(completed: Int64(body.count), total: Int64(body.count)))
    }
  }

  @Test("WIN-007 without a checksum an existing destination is still replaced")
  func noChecksumAlwaysDownloads() async throws {
    try await withResumeFixture { downloader, url, destination, _ in
      try Data("old".utf8).write(to: destination)
      try await downloader.download(from: url, to: destination, sha256: nil) { _ in }
      #expect(try Data(contentsOf: destination) == body)
      #expect(RangeStubProtocol.requests(for: url) == [nil])
    }
  }

  @Test("WIN-007 cancelling mid-download keeps the partial file for the next attempt")
  func cancellationKeepsPartial() async throws {
    var server = RangeStubProtocol.Server(body: Data(repeating: 7, count: 2_000_000))
    server.chunkSize = 10_000
    server.chunkDelay = 0.01
    try await withResumeFixture(server: server) { downloader, url, destination, _ in
      let task = Task { try await downloader.download(from: url, to: destination, sha256: nil) { _ in } }
      let part = partFile(of: destination)
      for _ in 0..<200 {  // wait (at most ~4 s) until some bytes are on disk
        if ((try? FileManager.default.attributesOfItem(atPath: part.path)[.size] as? Int) ?? 0) >= 30_000 { break }
        try await Task.sleep(for: .milliseconds(20))
      }
      task.cancel()
      _ = try? await task.value

      let size = (try? FileManager.default.attributesOfItem(atPath: part.path)[.size] as? Int) ?? 0
      #expect(size >= 30_000)
      #expect(size < 2_000_000)
      #expect(!FileManager.default.fileExists(atPath: destination.path))
    }
  }
}
