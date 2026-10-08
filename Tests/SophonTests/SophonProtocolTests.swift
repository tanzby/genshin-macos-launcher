import Foundation
import Testing

@testable import Sophon

private let packageID = "8xfMve0uwQ"

/// A client whose server answers by path. Unknown paths get 404.
private func makeClient(
  _ routes: [String: (status: Int, body: Data)]
) -> (SophonAPI, String) {
  let (session, id) = StubURLProtocol.session { request in
    let path = request.url!.path
    guard let route = routes[path] else { return (404, Data()) }
    return route
  }
  return (SophonAPI(session: session), id)
}

private func standardRoutes() throws -> [String: (status: Int, body: Data)] {
  [
    "/hyp/hyp-connect/api/getGameBranches": (200, try Fixture.data("getGameBranches", "json")),
    "/downloader/sophon_chunk/api/getBuild": (200, try Fixture.data("getBuild", "json")),
    "/downloader/sophon_chunk/api/getPatchBuild": (200, try Fixture.data("getPatchBuild", "json")),
  ]
}

@Suite struct SophonProtocolTests {
  // MARK: getGameBranches

  @Test func APP_009_getGameBranches_requestsTheCNHypConnectEndpoint() async throws {
    let (client, id) = makeClient(try standardRoutes())
    _ = try await client.gameBranches()
    let request = try #require(StubURLProtocol.seen(id).first)
    #expect(request.httpMethod == "GET")
    let url = try #require(request.url)
    #expect(url.host() == "hyp-api.mihoyo.com")
    #expect(url.path == "/hyp/hyp-connect/api/getGameBranches")
    let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
    #expect(items.contains(URLQueryItem(name: "game_ids[]", value: "1Z8W5NHUQb")))
    #expect(items.contains(URLQueryItem(name: "launcher_id", value: "jGHBHlcOq1")))
  }

  @Test func APP_009_getGameBranches_decodesTheMainBranchFromARealResponse() async throws {
    let (client, _) = makeClient(try standardRoutes())
    let branches = try await client.gameBranches()
    let main = try #require(branches.main)
    #expect(main.branch == "main")
    #expect(main.packageID == packageID)
    #expect(main.tag == "7.1.0")
    #expect(main.diffTags == ["7.0.0", "6.7.0"])
    #expect(main.categories.map(\.matchingField) == ["game", "zh-cn", "en-us", "ja-jp", "ko-kr"])
  }

  @Test func APP_009_getGameBranches_nullPreDownloadIsNilNotAnError() async throws {
    let (client, _) = makeClient(try standardRoutes())
    #expect(try await client.gameBranches().preDownload == nil)
  }

  @Test func APP_009_getGameBranches_decodesAPresentPreDownloadBranch() async throws {
    let json = """
      {"retcode":0,"message":"OK","data":{"game_branches":[{"main":
        {"package_id":"p1","branch":"main","password":"x","tag":"7.1.0","diff_tags":[],"categories":[]},
       "pre_download":
        {"package_id":"p2","branch":"predownload","password":"y","tag":"7.2.0","diff_tags":["7.1.0"],"categories":[]}}]}}
      """
    let (client, _) = makeClient([
      "/hyp/hyp-connect/api/getGameBranches": (200, Data(json.utf8))
    ])
    let pre = try #require(try await client.gameBranches().preDownload)
    #expect(pre.tag == "7.2.0")
    #expect(pre.branch == "predownload")
    #expect(pre.diffTags == ["7.1.0"])
  }

  @Test func APP_009_nonZeroRetcodeIsAnAPIError() async throws {
    let body = Data(#"{"retcode":-1,"message":"nope","data":null}"#.utf8)
    let (client, _) = makeClient(["/hyp/hyp-connect/api/getGameBranches": (200, body)])
    await #expect(throws: SophonError.api(retcode: -1, message: "nope")) {
      _ = try await client.gameBranches()
    }
  }

  @Test func APP_009_nonSuccessHTTPStatusIsAnErrorNotData() async throws {
    let (client, _) = makeClient([
      "/hyp/hyp-connect/api/getGameBranches": (503, Data("<html>busy</html>".utf8))
    ])
    await #expect(throws: SophonError.http(status: 503)) {
      _ = try await client.gameBranches()
    }
  }

  @Test func APP_009_garbageBodyIsMalformed() async throws {
    let (client, _) = makeClient([
      "/hyp/hyp-connect/api/getGameBranches": (200, Data("not json".utf8))
    ])
    await #expect(throws: SophonError.self) { _ = try await client.gameBranches() }
  }

  // MARK: getBuild / getPatchBuild

  @Test func APP_009_getBuild_isAGETOnApiTakumiCarryingBranchPackageAndPassword() async throws {
    let (client, id) = makeClient(try standardRoutes())
    let main = try #require(try await client.gameBranches().main)
    let build = try await client.build(for: main)
    let request = try #require(StubURLProtocol.seen(id).last)
    #expect(request.httpMethod == "GET")
    let url = try #require(request.url)
    #expect(url.host() == "api-takumi.mihoyo.com")
    #expect(url.path == "/downloader/sophon_chunk/api/getBuild")
    let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
    #expect(items.contains(URLQueryItem(name: "branch", value: "main")))
    #expect(items.contains(URLQueryItem(name: "package_id", value: packageID)))
    #expect(items.contains(URLQueryItem(name: "password", value: "REDACTED")))
    #expect(build.tag == "7.1.0")
    #expect(build.buildID == "dJsUs1m2gLGR")
  }

  @Test func APP_009_getBuild_decodesTheGameCategoryOfARealResponse() async throws {
    let (client, _) = makeClient(try standardRoutes())
    let main = try #require(try await client.gameBranches().main)
    let game = try await client.build(for: main).manifest(matching: "game")
    #expect(game.matchingField == "game")
    #expect(game.manifestID == "manifest_f3c70e565732550c_0a9e60a100ceda023ea7b7e276f96186")
    #expect(game.manifestURLPrefix.hasSuffix("/manifests/cxgf44wie1a8/dJsUs1m2gLGR"))
    #expect(game.chunkURLPrefix?.hasSuffix("/chunks/cxgf44wie1a8/dJsUs1m2gLGR") == true)
    #expect(game.diffURLPrefix == nil)
    #expect(game.stats?.compressedSize == 128_308_580_902)
    #expect(game.stats?.fileCount == 2744)
  }

  @Test func UPG_004_getPatchBuild_isAnEmptyPOSTOnApiTakumi() async throws {
    let (client, id) = makeClient(try standardRoutes())
    let main = try #require(try await client.gameBranches().main)
    _ = try await client.patchBuild(for: main)
    let request = try #require(StubURLProtocol.seen(id).last)
    #expect(request.httpMethod == "POST")
    #expect(request.url?.host() == "api-takumi.mihoyo.com")
    #expect(request.url?.path == "/downloader/sophon_chunk/api/getPatchBuild")
    let body = request.httpBody ?? Data()
    #expect(body.isEmpty)
    let items = URLComponents(url: try #require(request.url), resolvingAgainstBaseURL: false)?
      .queryItems ?? []
    #expect(items.contains(URLQueryItem(name: "password", value: "REDACTED")))
  }

  @Test func UPG_004_getPatchBuild_decodesPerVersionStatsAndDiffPrefix() async throws {
    let (client, _) = makeClient(try standardRoutes())
    let main = try #require(try await client.gameBranches().main)
    let patch = try await client.patchBuild(for: main)
    #expect(patch.patchID == "3RoSua5Y7N1v")
    #expect(patch.tag == "7.1.0")
    let game = try patch.manifest(matching: "game")
    #expect(game.diffURLPrefix?.hasSuffix("/diffs/cxgf44wie1a8/3RoSua5Y7N1v/10017") == true)
    #expect(game.chunkURLPrefix == nil)
    #expect(game.manifestID == "manifest_e001f7bdf0f8a968_d66726534cb7511b07a693f847411594")
  }

  @Test func UPG_004_preDownloadBranchUsesTheSameHostAndItsOwnParameters() async throws {
    let json = """
      {"retcode":0,"message":"OK","data":{"game_branches":[{"main":null,
       "pre_download":
        {"package_id":"p2","branch":"predownload","password":"y","tag":"7.2.0","diff_tags":["7.1.0"],"categories":[]}}]}}
      """
    var routes = try standardRoutes()
    routes["/hyp/hyp-connect/api/getGameBranches"] = (200, Data(json.utf8))
    let (client, id) = makeClient(routes)
    let pre = try #require(try await client.gameBranches().preDownload)
    _ = try await client.patchBuild(for: pre)
    let url = try #require(StubURLProtocol.seen(id).last?.url)
    #expect(url.host() == "api-takumi.mihoyo.com")
    let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
    #expect(items.contains(URLQueryItem(name: "branch", value: "predownload")))
    #expect(items.contains(URLQueryItem(name: "package_id", value: "p2")))
  }

  // MARK: category matching

  @Test func APP_009_categoryMatchingPrefersExactOverSubstring() throws {
    let build = try decodedBuild(fields: ["game", "game-extra"])
    #expect(try build.manifest(matching: "game").matchingField == "game")
  }

  @Test func APP_009_categoryMatchingFallsBackToASingleSubstringMatch() throws {
    let build = try decodedBuild(fields: ["game-resources", "zh-cn"])
    #expect(try build.manifest(matching: "game").matchingField == "game-resources")
  }

  @Test func APP_009_categoryMatchingRejectsAmbiguousSubstrings() throws {
    let build = try decodedBuild(fields: ["game-a", "game-b"])
    #expect(throws: SophonError.ambiguousCategory("game")) { try build.manifest(matching: "game") }
  }

  @Test func APP_009_categoryMatchingRejectsMissingCategories() throws {
    let build = try decodedBuild(fields: ["zh-cn"])
    #expect(throws: SophonError.noMatchingCategory("game")) { try build.manifest(matching: "game") }
  }

  // MARK: secrets

  @Test func APP_009_passwordNeverAppearsInDescriptionsOrErrors() async throws {
    let (client, _) = makeClient(try standardRoutes())
    let main = try #require(try await client.gameBranches().main)
    #expect(!String(describing: main).contains("REDACTED"))
    #expect(!String(reflecting: main).contains("REDACTED"))
    let (failing, _) = makeClient([:])
    let error = await #expect(throws: SophonError.self) { _ = try await failing.build(for: main) }
    #expect(!String(describing: error as Any).contains("REDACTED"))
    let message = error?.localizedDescription ?? ""
    #expect(!message.contains("REDACTED"))
  }

  // MARK: online info

  @Test func APP_008_onlineInfoCombinesBranchesAndGameStats() async throws {
    let (session, _) = StubURLProtocol.session { request in
      let routes = try standardRoutes()
      return routes[request.url!.path] ?? (404, Data())
    }
    let info = try await LiveSophonClient(api: SophonAPI(session: session)).onlineInfo()
    #expect(info.latestVersion == "7.1.0")
    #expect(info.patchableVersions == ["7.0.0", "6.7.0"])
    #expect(info.installSize == 128_308_580_902)
    #expect(info.preDownload == nil)
  }

  @Test func APP_008_onlineInfoReportsThePreDownloadVersion() async throws {
    let json = """
      {"retcode":0,"message":"OK","data":{"game_branches":[{
       "main":{"package_id":"p1","branch":"main","password":"x","tag":"7.1.0","diff_tags":[],"categories":[]},
       "pre_download":{"package_id":"p2","branch":"predownload","password":"y","tag":"7.2.0","diff_tags":["7.1.0"],"categories":[]}}]}}
      """
    let (session, _) = StubURLProtocol.session { request in
      var routes = try standardRoutes()
      routes["/hyp/hyp-connect/api/getGameBranches"] = (200, Data(json.utf8))
      return routes[request.url!.path] ?? (404, Data())
    }
    let info = try await LiveSophonClient(api: SophonAPI(session: session)).onlineInfo()
    #expect(info.preDownload == "7.2.0")
  }
}

private func decodedBuild(fields: [String]) throws -> SophonBuild {
  let manifests = fields.map {
    """
    {"category_id":"1","matching_field":"\($0)","manifest":{"id":"m","checksum":"c",
     "compressed_size":"1","uncompressed_size":"2"},
     "manifest_download":{"url_prefix":"https://example.invalid/m","url_suffix":""},
     "chunk_download":{"url_prefix":"https://example.invalid/c","url_suffix":""}}
    """
  }.joined(separator: ",")
  let json = #"{"retcode":0,"message":"OK","data":{"build_id":"b","tag":"1.0.0","manifests":[\#(manifests)]}}"#
  return try SophonBuild.decode(Data(json.utf8))
}
