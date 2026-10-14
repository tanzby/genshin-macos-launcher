import Foundation
import SwiftProtobuf

/// Where the Sophon APIs live. The ids are public identifiers (from DGP-Studio/Snap.Hutao, MIT).
package struct SophonEndpoints: Sendable, Equatable {
  package var hypConnectBase: URL
  /// Serves getBuild and getPatchBuild: install, repair, update and pre-download all use this host.
  package var downloaderBase: URL
  package var gameID: String
  package var launcherID: String

  package init(hypConnectBase: URL, downloaderBase: URL, gameID: String, launcherID: String) {
    self.hypConnectBase = hypConnectBase
    self.downloaderBase = downloaderBase
    self.gameID = gameID
    self.launcherID = launcherID
  }
}

/// The Sophon protocol: branches, builds, patch builds and manifests. Stateless and cache-free,
/// so no credential is ever written to disk.
package struct SophonAPI: Sendable {
  package let endpoints: SophonEndpoints
  let session: URLSession

  package init(endpoints: SophonEndpoints, session: URLSession = .shared) {
    self.endpoints = endpoints
    self.session = session
  }

  package func gameBranches() async throws -> SophonGameBranches {
    let url = try makeURL(
      endpoints.hypConnectBase, path: "getGameBranches",
      query: [("game_ids[]", endpoints.gameID), ("launcher_id", endpoints.launcherID)])
    return try SophonGameBranches.decode(try await send(URLRequest(url: url)))
  }

  package func build(for branch: SophonGameBranch) async throws -> SophonBuild {
    let url = try makeURL(endpoints.downloaderBase, path: "getBuild", query: query(for: branch))
    return try SophonBuild.decode(try await send(URLRequest(url: url)))
  }

  /// `getPatchBuild` only answers POST (with an empty body).
  package func patchBuild(for branch: SophonGameBranch) async throws -> SophonPatchBuild {
    let url = try makeURL(endpoints.downloaderBase, path: "getPatchBuild", query: query(for: branch))
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    return try SophonPatchBuild.decode(try await send(request))
  }

  /// Downloads and parses the chunk manifest of one category.
  package func manifest(for ref: SophonManifestRef) async throws -> SophonManifest {
    try SophonManifest(zstdCompressed: try await downloadManifest(ref))
  }

  /// Downloads and parses the ldiff manifest of one category.
  package func diffManifest(for ref: SophonManifestRef) async throws -> SophonDiffManifest {
    try SophonDiffManifest(zstdCompressed: try await downloadManifest(ref))
  }

  private func downloadManifest(_ ref: SophonManifestRef) async throws -> Data {
    let prefix = try SophonDownloaderLayout.httpsBase(ref.manifestURLPrefix)
    guard let url = URL(string: "\(prefix)/\(ref.manifestID)\(ref.manifestURLSuffix)") else {
      throw SophonError.malformedResponse
    }
    return try await send(URLRequest(url: url))
  }

  private func query(for branch: SophonGameBranch) -> [(String, String)] {
    [("branch", branch.branch), ("package_id", branch.packageID), ("password", branch.password)]
  }

  /// Builds `base/path?query` with strict percent-encoding, so a `+` or `&` in a value cannot leak.
  private func makeURL(_ base: URL, path: String, query: [(String, String)]) throws -> URL {
    var allowed = CharacterSet.alphanumerics
    allowed.insert(charactersIn: "-._~")
    let encoded = query.map { name, value in
      let n = name.addingPercentEncoding(withAllowedCharacters: allowed) ?? name
      let v = value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
      return "\(n)=\(v)"
    }.joined(separator: "&")
    guard let url = URL(string: base.appending(path: path).absoluteString + "?" + encoded) else {
      throw SophonError.malformedResponse
    }
    return url
  }

  private func send(_ request: URLRequest) async throws -> Data {
    var request = request
    request.timeoutInterval = 30
    let data: Data
    let response: URLResponse
    do {
      (data, response) = try await session.data(for: request)
    } catch let error as URLError {
      throw SophonError.from(error)
    }
    guard let http = response as? HTTPURLResponse else { throw SophonError.malformedResponse }
    guard http.statusCode == 200 else { throw SophonError.http(status: http.statusCode) }
    return data
  }
}
