import CryptoKit
import Foundation
import Testing

@testable import Platform

// URLProtocol stub keyed by URL; every test uses a unique URL so tests can run in parallel.
private final class DownloaderStubProtocol: URLProtocol, @unchecked Sendable {
  struct Response: Sendable {
    var status: Int
    var body: Data
    var chunkSize: Int
    var includeLength = true
  }

  nonisolated(unsafe) private static var responses: [URL: Response] = [:]
  private static let lock = NSLock()

  static func register(_ response: Response, for url: URL) { lock.withLock { responses[url] = response } }
  static func unregister(_ url: URL) { _ = lock.withLock { responses.removeValue(forKey: url) } }

  override class func canInit(with request: URLRequest) -> Bool { true }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

  override func startLoading() {
    guard let url = request.url, let stub = Self.lock.withLock({ Self.responses[url] }) else {
      client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
      return
    }
    var headers: [String: String] = [:]
    if stub.includeLength { headers["Content-Length"] = String(stub.body.count) }
    let response = HTTPURLResponse(url: url, statusCode: stub.status, httpVersion: "HTTP/1.1", headerFields: headers)!
    client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
    var offset = 0
    while offset < stub.body.count {
      let end = min(offset + stub.chunkSize, stub.body.count)
      client?.urlProtocol(self, didLoad: stub.body.subdata(in: offset..<end))
      offset = end
    }
    client?.urlProtocolDidFinishLoading(self)
  }

  override func stopLoading() {}
}

private final class DownloaderProgressBox: @unchecked Sendable {
  private let lock = NSLock()
  private var items: [DownloadProgress] = []
  func add(_ p: DownloadProgress) { lock.withLock { items.append(p) } }
  var all: [DownloadProgress] { lock.withLock { items } }
}

private func downloaderSHA(_ data: Data) -> String {
  SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

private func makeDownloader() -> Downloader {
  let configuration = URLSessionConfiguration.ephemeral
  configuration.protocolClasses = [DownloaderStubProtocol.self]
  return Downloader(configuration: configuration)
}

private func withDownloaderFixture(
  status: Int = 200, body: Data = Data((0..<200_000).map { UInt8($0 % 251) }), includeLength: Bool = true,
  _ test: (Downloader, URL, Data, URL) async throws -> Void
) async throws {
  let dir = FileManager.default.temporaryDirectory
    .appending(path: "yaagl-downloader-test-\(UUID().uuidString)", directoryHint: .isDirectory)
  try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
  let url = URL(string: "https://downloads.invalid/\(UUID().uuidString)/file.bin")!
  DownloaderStubProtocol.register(
    .init(status: status, body: body, chunkSize: 50_000, includeLength: includeLength), for: url)
  defer {
    DownloaderStubProtocol.unregister(url)
    try? FileManager.default.removeItem(at: dir)
  }
  try await test(makeDownloader(), url, body, dir)
}

@Suite("WIN-007 download") struct DownloaderTests {
  @Test("WIN-007 writes the response body to the destination")
  func writesBody() async throws {
    try await withDownloaderFixture { downloader, url, body, dir in
      let destination = dir.appending(path: "out.bin")
      try await downloader.download(from: url, to: destination, sha256: nil) { _ in }
      #expect(try Data(contentsOf: destination) == body)
    }
  }

  @Test("WIN-007 creates missing parent directories")
  func createsParents() async throws {
    try await withDownloaderFixture { downloader, url, body, dir in
      let destination = dir.appending(path: "a/b/c/out.bin")
      try await downloader.download(from: url, to: destination, sha256: nil) { _ in }
      #expect(try Data(contentsOf: destination) == body)
    }
  }

  @Test("WIN-007 replaces an existing destination file")
  func replacesExisting() async throws {
    try await withDownloaderFixture { downloader, url, body, dir in
      let destination = dir.appending(path: "out.bin")
      try Data("old".utf8).write(to: destination)
      try await downloader.download(from: url, to: destination, sha256: nil) { _ in }
      #expect(try Data(contentsOf: destination) == body)
    }
  }

  @Test("WIN-007 reports growing progress with total from Content-Length")
  func reportsProgress() async throws {
    try await withDownloaderFixture { downloader, url, body, dir in
      let box = DownloaderProgressBox()
      try await downloader.download(from: url, to: dir.appending(path: "out.bin"), sha256: nil) { box.add($0) }
      let all = box.all
      #expect(!all.isEmpty)
      #expect(all.allSatisfy { $0.total == Int64(body.count) })
      #expect(zip(all, all.dropFirst()).allSatisfy { $0.completed <= $1.completed })
      #expect(all.last?.completed == Int64(body.count))
    }
  }

  @Test("WIN-007 reports total -1 when the server announces no length")
  func unknownLength() async throws {
    try await withDownloaderFixture(includeLength: false) { downloader, url, _, dir in
      let box = DownloaderProgressBox()
      try await downloader.download(from: url, to: dir.appending(path: "out.bin"), sha256: nil) { box.add($0) }
      #expect(!box.all.isEmpty)
      #expect(box.all.allSatisfy { $0.total == -1 })
    }
  }

  @Test("WIN-007 non-2xx status throws httpStatus and creates no destination", arguments: [404, 500])
  func httpFailure(status: Int) async throws {
    try await withDownloaderFixture(status: status, body: Data("nope".utf8)) { downloader, url, _, dir in
      let destination = dir.appending(path: "out.bin")
      await #expect(throws: DownloadError.httpStatus(status)) {
        try await downloader.download(from: url, to: destination, sha256: nil) { _ in }
      }
      #expect(!FileManager.default.fileExists(atPath: destination.path))
    }
  }

  @Test("WIN-007 correct sha256 passes")
  func checksumPasses() async throws {
    try await withDownloaderFixture { downloader, url, body, dir in
      let destination = dir.appending(path: "out.bin")
      try await downloader.download(from: url, to: destination, sha256: downloaderSHA(body)) { _ in }
      #expect(try Data(contentsOf: destination) == body)
    }
  }

  @Test("WIN-007 wrong sha256 throws checksumMismatch and does not create the destination")
  func checksumMismatch() async throws {
    try await withDownloaderFixture { downloader, url, body, dir in
      let destination = dir.appending(path: "sub/out.bin")
      let wrong = String(repeating: "0", count: 64)
      await #expect(throws: DownloadError.checksumMismatch(expected: wrong, actual: downloaderSHA(body))) {
        try await downloader.download(from: url, to: destination, sha256: wrong) { _ in }
      }
      #expect(!FileManager.default.fileExists(atPath: destination.path))
      let leftovers = (try? FileManager.default.contentsOfDirectory(atPath: destination.deletingLastPathComponent().path)) ?? []
      #expect(leftovers.isEmpty)
    }
  }

  @Test("WIN-007 wrong sha256 leaves an existing destination unchanged")
  func checksumMismatchKeepsOld() async throws {
    try await withDownloaderFixture { downloader, url, _, dir in
      let destination = dir.appending(path: "out.bin")
      try Data("previous".utf8).write(to: destination)
      await #expect(throws: DownloadError.self) {
        try await downloader.download(from: url, to: destination, sha256: String(repeating: "0", count: 64)) { _ in }
      }
      #expect(try Data(contentsOf: destination) == Data("previous".utf8))
    }
  }
}
