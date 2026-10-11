import Foundation
import Launcher
import Testing

@testable import GenshinCN

/// Answers every request of a session from a closure keyed by URL; counts requests per session.
final class BackgroundStub: URLProtocol, @unchecked Sendable {
  typealias Handler = @Sendable (URL) -> (status: Int, body: Data)?
  private static let idHeader = "X-Stub-ID"
  private static let lock = NSLock()
  nonisolated(unsafe) private static var handlers: [String: Handler] = [:]
  nonisolated(unsafe) private static var seenURLs: [String: [URL]] = [:]

  static func session(_ handler: @escaping Handler) -> (URLSession, String) {
    let id = UUID().uuidString
    lock.withLock { handlers[id] = handler }
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [BackgroundStub.self]
    configuration.httpAdditionalHeaders = [idHeader: id]
    return (URLSession(configuration: configuration), id)
  }

  static func seen(_ id: String) -> [URL] { lock.withLock { seenURLs[id] ?? [] } }

  override class func canInit(with request: URLRequest) -> Bool { true }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

  override func startLoading() {
    let id = request.value(forHTTPHeaderField: Self.idHeader) ?? ""
    let url = request.url!
    let handler = Self.lock.withLock { () -> Handler? in
      Self.seenURLs[id, default: []].append(url)
      return Self.handlers[id]
    }
    guard let reply = handler?(url) else {
      client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
      return
    }
    let response = HTTPURLResponse(
      url: url, statusCode: reply.status, httpVersion: "HTTP/1.1", headerFields: nil)!
    client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
    client?.urlProtocol(self, didLoad: reply.body)
    client?.urlProtocolDidFinishLoading(self)
  }

  override func stopLoading() {}
}

@Suite struct BackgroundImageProviderTests {
  static let imageURL = "https://launcher-webstatic.example/a.webp"
  static let otherURL = "https://launcher-webstatic.example/b.webp"
  /// 1x1 PNG, a real image so that the provider's decode check passes.
  static let png = Data(
    base64Encoded:
      "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==")!

  static func info(_ backgrounds: [(url: String, video: Bool)], biz: String = "hk4e_cn") -> Data {
    let entries = backgrounds.map { entry in
      """
      {"id":"x","background":{"url":"\(entry.url)","link":""},\
      "type":"\(entry.video ? "BACKGROUND_TYPE_VIDEO" : "BACKGROUND_TYPE_PICTURE")"}
      """
    }.joined(separator: ",")
    return Data(
      """
      {"retcode":0,"message":"OK","data":{"game_info_list":[\
      {"game":{"id":"other","biz":"hkrpg_cn"},"backgrounds":[{"id":"y","background":{"url":"https://wrong.example/x.webp"},"type":"BACKGROUND_TYPE_PICTURE"}]},\
      {"game":{"id":"1Z8W5NHUQb","biz":"\(biz)"},"backgrounds":[\(entries)]}]}}
      """.utf8)
  }

  func makeCache() -> URL {
    FileManager.default.temporaryDirectory.appending(path: "bg-\(UUID().uuidString)", directoryHint: .isDirectory)
  }

  func provider(_ cache: URL, _ session: URLSession) -> BackgroundImageProvider {
    BackgroundImageProvider(cacheDirectory: cache, session: session)
  }

  @Test func APP_021_downloadsOfficialImageIntoCacheAndReturnsFileURL() async throws {
    let cache = makeCache()
    defer { try? FileManager.default.removeItem(at: cache) }
    let (session, id) = BackgroundStub.session { url in
      url.path.hasSuffix("getAllGameBasicInfo")
        ? (200, Self.info([(Self.imageURL, false)])) : (200, Self.png)
    }
    let result = await provider(cache, session).backgroundImage()
    guard case .remote(let file) = result else { Issue.record("expected remote, got \(result)"); return }
    #expect(file.isFileURL)
    #expect(file.deletingLastPathComponent().standardizedFileURL == cache.standardizedFileURL)
    #expect(try Data(contentsOf: file) == Self.png)
    let info = try #require(BackgroundStub.seen(id).first)
    #expect(info.query?.contains("launcher_id=jGHBHlcOq1") == true)
    #expect(info.query?.contains("language=zh-cn") == true)
  }

  @Test func APP_021_prefersVideoTypeEntryStaticImage() async throws {
    let cache = makeCache()
    defer { try? FileManager.default.removeItem(at: cache) }
    let (session, id) = BackgroundStub.session { url in
      url.path.hasSuffix("getAllGameBasicInfo")
        ? (200, Self.info([(Self.otherURL, false), (Self.imageURL, true)])) : (200, Self.png)
    }
    _ = await provider(cache, session).backgroundImage()
    #expect(BackgroundStub.seen(id).map(\.absoluteString).contains(Self.imageURL))
    #expect(!BackgroundStub.seen(id).map(\.absoluteString).contains(Self.otherURL))
  }

  @Test func APP_021_cacheHitSkipsImageDownload() async throws {
    let cache = makeCache()
    defer { try? FileManager.default.removeItem(at: cache) }
    let (session, id) = BackgroundStub.session { url in
      url.path.hasSuffix("getAllGameBasicInfo")
        ? (200, Self.info([(Self.imageURL, false)])) : (200, Self.png)
    }
    let first = await provider(cache, session).backgroundImage()
    let second = await provider(cache, session).backgroundImage()
    #expect(first == second)
    #expect(BackgroundStub.seen(id).filter { $0.absoluteString == Self.imageURL }.count == 1)
  }

  @Test func APP_021_supersededImageIsPrunedAfterRetention() async throws {
    let cache = makeCache()
    defer { try? FileManager.default.removeItem(at: cache) }
    let current = LockedBox(Self.imageURL)
    let (session, _) = BackgroundStub.session { url in
      url.path.hasSuffix("getAllGameBasicInfo")
        ? (200, Self.info([(current.value, false)])) : (200, Self.png)
    }
    _ = await BackgroundImageProvider(cacheDirectory: cache, session: session, retention: 0).backgroundImage()
    try await Task.sleep(for: .milliseconds(20))
    current.value = Self.otherURL
    _ = await BackgroundImageProvider(cacheDirectory: cache, session: session, retention: 0).backgroundImage()
    #expect(try FileManager.default.contentsOfDirectory(atPath: cache.path).count == 1)
  }

  @Test func APP_021_recentImagesSurviveRapidRotation() async throws {
    let cache = makeCache()
    defer { try? FileManager.default.removeItem(at: cache) }
    let current = LockedBox(Self.imageURL)
    let (session, _) = BackgroundStub.session { url in
      url.path.hasSuffix("getAllGameBasicInfo")
        ? (200, Self.info([(current.value, false)])) : (200, Self.png)
    }
    var handedOut: [BackgroundImage] = []
    for version in [Self.imageURL, Self.otherURL, Self.imageURL + "?v=3"] {
      current.value = version
      handedOut.append(await provider(cache, session).backgroundImage())
    }
    for case .remote(let file) in handedOut {
      #expect(FileManager.default.fileExists(atPath: file.path))
    }
  }

  @Test func APP_021_concurrentUpdatesNeverReturnADeletedFile() async throws {
    let cache = makeCache()
    defer { try? FileManager.default.removeItem(at: cache) }
    let calls = LockedBox(0)
    let (session, _) = BackgroundStub.session { url in
      guard url.path.hasSuffix("getAllGameBasicInfo") else { return (200, Self.png) }
      calls.value += 1  // old and new URL interleave, as when upstream rotates the image mid-launch
      return (200, Self.info([(calls.value.isMultiple(of: 2) ? Self.imageURL : Self.otherURL, false)]))
    }
    let results = await withTaskGroup(of: BackgroundImage.self) { group in
      for _ in 0..<8 { group.addTask { await provider(cache, session).backgroundImage() } }
      return await group.reduce(into: []) { $0.append($1) }
    }
    #expect(results.count == 8)
    for case .remote(let file) in results {
      #expect(FileManager.default.fileExists(atPath: file.path))
    }
  }

  @Test func APP_021_headerOnlyImageIsNotCached() async throws {
    let cache = makeCache()
    defer { try? FileManager.default.removeItem(at: cache) }
    // Signature and IHDR intact, no pixel data: counts as an image container but has no decodable frame.
    let corrupt = Self.png.prefix(40)
    let (session, _) = BackgroundStub.session { url in
      url.path.hasSuffix("getAllGameBasicInfo")
        ? (200, Self.info([(Self.imageURL, false)])) : (200, Data(corrupt))
    }
    #expect(await provider(cache, session).backgroundImage() == .bundledDefault)
    #expect(((try? FileManager.default.contentsOfDirectory(atPath: cache.path)) ?? []).isEmpty)
  }

  @Test func APP_021_failedWriteKeepsTheOldCachedImage() async throws {
    let cache = makeCache()
    defer {
      try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: cache.path)
      try? FileManager.default.removeItem(at: cache)
    }
    let current = LockedBox(Self.imageURL)
    let (session, _) = BackgroundStub.session { url in
      url.path.hasSuffix("getAllGameBasicInfo")
        ? (200, Self.info([(current.value, false)])) : (200, Self.png)
    }
    let old = await BackgroundImageProvider(cacheDirectory: cache, session: session, retention: 0).backgroundImage()
    try await Task.sleep(for: .milliseconds(20))
    try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: cache.path)
    current.value = Self.otherURL
    let result = await BackgroundImageProvider(cacheDirectory: cache, session: session, retention: 0).backgroundImage()
    #expect(result == old)
    guard case .remote(let file) = old else { return }
    #expect(FileManager.default.fileExists(atPath: file.path))
  }

  @Test func APP_021_apiFailureWithoutCacheFallsBackToBundledDefault() async {
    let cache = makeCache()
    defer { try? FileManager.default.removeItem(at: cache) }
    let (session, _) = BackgroundStub.session { _ in nil }
    #expect(await provider(cache, session).backgroundImage() == .bundledDefault)
  }

  @Test func APP_021_apiFailureReusesLastCachedImage() async throws {
    let cache = makeCache()
    defer { try? FileManager.default.removeItem(at: cache) }
    let online = LockedBox(true)
    let (session, _) = BackgroundStub.session { url in
      guard online.value else { return nil }
      return url.path.hasSuffix("getAllGameBasicInfo")
        ? (200, Self.info([(Self.imageURL, false)])) : (200, Self.png)
    }
    let first = await provider(cache, session).backgroundImage()
    online.value = false
    #expect(await provider(cache, session).backgroundImage() == first)
  }

  @Test func APP_021_missingGameOrEmptyBackgroundsFallBack() async {
    for body in [Self.info([(Self.imageURL, false)], biz: "hk4e_global"), Self.info([])] {
      let cache = makeCache()
      defer { try? FileManager.default.removeItem(at: cache) }
      let (session, _) = BackgroundStub.session { _ in (200, body) }
      #expect(await provider(cache, session).backgroundImage() == .bundledDefault)
    }
  }

  @Test func APP_021_badRetcodeOrMalformedJSONFallBack() async {
    for body in [Data(#"{"retcode":-1,"message":"x","data":null}"#.utf8), Data("<html>".utf8)] {
      let cache = makeCache()
      defer { try? FileManager.default.removeItem(at: cache) }
      let (session, _) = BackgroundStub.session { _ in (200, body) }
      #expect(await provider(cache, session).backgroundImage() == .bundledDefault)
    }
  }

  @Test func APP_021_nonImageOrHTTPErrorDownloadIsNotCached() async throws {
    for image in [(200, Data("not an image".utf8)), (404, Self.png)] {
      let cache = makeCache()
      defer { try? FileManager.default.removeItem(at: cache) }
      let (session, _) = BackgroundStub.session { url in
        url.path.hasSuffix("getAllGameBasicInfo")
          ? (200, Self.info([(Self.imageURL, false)])) : image
      }
      #expect(await provider(cache, session).backgroundImage() == .bundledDefault)
      let leftovers = (try? FileManager.default.contentsOfDirectory(atPath: cache.path)) ?? []
      #expect(leftovers.isEmpty)
    }
  }
}

final class LockedBox<Value: Sendable>: @unchecked Sendable {
  private let lock = NSLock()
  private var stored: Value
  init(_ value: Value) { stored = value }
  var value: Value {
    get { lock.withLock { stored } }
    set { lock.withLock { stored = newValue } }
  }
}
