import Foundation
import Launcher
import Testing
import TestSupport

@testable import GenshinCN

/// `StubURLProtocol` keyed by URL; a `nil` reply fails the request as if offline.
enum BackgroundStub {
  static func session(_ handler: @escaping @Sendable (URL) -> (status: Int, body: Data)?) -> (URLSession, String) {
    StubURLProtocol.session { request in
      guard let reply = handler(request.url!) else { throw URLError(.notConnectedToInternet) }
      return reply
    }
  }

  static func seen(_ id: String) -> [URL] { StubURLProtocol.seen(id).compactMap(\.url) }
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

  /// Answers the info request with `info` (read on every request) and every other URL with `image`.
  static func server(
    info: @autoclosure @escaping @Sendable () -> Data = BackgroundImageProviderTests.info([(imageURL, false)]),
    image: (status: Int, body: Data) = (200, png)
  ) -> @Sendable (URL) -> (status: Int, body: Data)? {
    { url in url.path.hasSuffix("getAllGameBasicInfo") ? (200, info()) : image }
  }

  /// Makes every cached file older than any retention, without waiting for the clock to move.
  func ageCache(_ cache: URL) throws {
    let past = Date().addingTimeInterval(-60)
    for name in try FileManager.default.contentsOfDirectory(atPath: cache.path) {
      try FileManager.default.setAttributes([.modificationDate: past], ofItemAtPath: cache.appending(path: name).path)
    }
  }

  func makeCache() -> URL {
    temporaryURL("bg")
  }

  func provider(_ cache: URL, _ session: URLSession) -> BackgroundImageProvider {
    BackgroundImageProvider(cacheDirectory: cache, session: session)
  }

  @Test func APP_021_downloadsOfficialImageIntoCacheAndReturnsFileURL() async throws {
    let cache = makeCache()
    let (session, id) = BackgroundStub.session(Self.server())
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
    let (session, id) = BackgroundStub.session(Self.server(info: Self.info([(Self.otherURL, false), (Self.imageURL, true)])))
    _ = await provider(cache, session).backgroundImage()
    #expect(BackgroundStub.seen(id).map(\.absoluteString).contains(Self.imageURL))
    #expect(!BackgroundStub.seen(id).map(\.absoluteString).contains(Self.otherURL))
  }

  @Test func APP_021_cacheHitSkipsImageDownload() async throws {
    let cache = makeCache()
    let (session, id) = BackgroundStub.session(Self.server())
    let first = await provider(cache, session).backgroundImage()
    let second = await provider(cache, session).backgroundImage()
    #expect(first == second)
    #expect(BackgroundStub.seen(id).filter { $0.absoluteString == Self.imageURL }.count == 1)
  }

  @Test func APP_021_supersededImageIsPrunedAfterRetention() async throws {
    let cache = makeCache()
    let current = Locked(Self.imageURL)
    let (session, _) = BackgroundStub.session(Self.server(info: Self.info([(current.value, false)])))
    _ = await BackgroundImageProvider(cacheDirectory: cache, session: session, retention: 0).backgroundImage()
    try ageCache(cache)
    current.value = Self.otherURL
    _ = await BackgroundImageProvider(cacheDirectory: cache, session: session, retention: 0).backgroundImage()
    #expect(try FileManager.default.contentsOfDirectory(atPath: cache.path).count == 1)
  }

  @Test func APP_021_recentImagesSurviveRapidRotation() async throws {
    let cache = makeCache()
    let current = Locked(Self.imageURL)
    let (session, _) = BackgroundStub.session(Self.server(info: Self.info([(current.value, false)])))
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
    let calls = Locked(0)
    let (session, _) = BackgroundStub.session { url in
      guard url.path.hasSuffix("getAllGameBasicInfo") else { return (200, Self.png) }
      // old and new URL interleave, as when upstream rotates the image mid-launch
      let call = calls.mutate { count -> Int in
        count += 1
        return count
      }
      return (200, Self.info([(call.isMultiple(of: 2) ? Self.imageURL : Self.otherURL, false)]))
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
    // Signature and IHDR intact, no pixel data: counts as an image container but has no decodable frame.
    let corrupt = Self.png.prefix(40)
    let (session, _) = BackgroundStub.session(Self.server(image: (200, Data(corrupt))))
    #expect(await provider(cache, session).backgroundImage() == .bundledDefault)
    #expect(((try? FileManager.default.contentsOfDirectory(atPath: cache.path)) ?? []).isEmpty)
  }

  @Test func APP_021_failedWriteKeepsTheOldCachedImage() async throws {
    let cache = makeCache()
    // Writable again, so TestSupport can remove it.
    defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: cache.path) }
    let current = Locked(Self.imageURL)
    let (session, _) = BackgroundStub.session(Self.server(info: Self.info([(current.value, false)])))
    let old = await BackgroundImageProvider(cacheDirectory: cache, session: session, retention: 0).backgroundImage()
    try ageCache(cache)
    try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: cache.path)
    current.value = Self.otherURL
    let result = await BackgroundImageProvider(cacheDirectory: cache, session: session, retention: 0).backgroundImage()
    #expect(result == old)
    guard case .remote(let file) = old else { return }
    #expect(FileManager.default.fileExists(atPath: file.path))
  }

  @Test func APP_021_apiFailureWithoutCacheFallsBackToBundledDefault() async {
    let cache = makeCache()
    let (session, _) = BackgroundStub.session { _ in nil }
    #expect(await provider(cache, session).backgroundImage() == .bundledDefault)
  }

  @Test func APP_021_apiFailureReusesLastCachedImage() async throws {
    let cache = makeCache()
    let online = Locked(true)
    let serve = Self.server()
    let (session, _) = BackgroundStub.session { online.value ? serve($0) : nil }
    let first = await provider(cache, session).backgroundImage()
    online.value = false
    #expect(await provider(cache, session).backgroundImage() == first)
  }

  @Test func APP_021_missingGameOrEmptyBackgroundsFallBack() async {
    for body in [Self.info([(Self.imageURL, false)], biz: "hk4e_global"), Self.info([])] {
      let cache = makeCache()
      let (session, _) = BackgroundStub.session { _ in (200, body) }
      #expect(await provider(cache, session).backgroundImage() == .bundledDefault)
    }
  }

  @Test func APP_021_badRetcodeOrMalformedJSONFallBack() async {
    for body in [Data(#"{"retcode":-1,"message":"x","data":null}"#.utf8), Data("<html>".utf8)] {
      let cache = makeCache()
      let (session, _) = BackgroundStub.session { _ in (200, body) }
      #expect(await provider(cache, session).backgroundImage() == .bundledDefault)
    }
  }

  @Test func APP_021_nonImageOrHTTPErrorDownloadIsNotCached() async throws {
    for image in [(200, Data("not an image".utf8)), (404, Self.png)] {
      let cache = makeCache()
      let (session, _) = BackgroundStub.session(Self.server(image: image))
      #expect(await provider(cache, session).backgroundImage() == .bundledDefault)
      let leftovers = (try? FileManager.default.contentsOfDirectory(atPath: cache.path)) ?? []
      #expect(leftovers.isEmpty)
    }
  }
}
