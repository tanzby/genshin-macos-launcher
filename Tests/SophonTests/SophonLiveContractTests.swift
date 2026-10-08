import CryptoKit
import Foundation
import Testing

@testable import Sophon

/// Read-only checks against the real CN servers. Skipped unless `YAAGL_LIVE=1`; the
/// `live-contract` workflow runs them, they are not part of the required `swift` check.
@Suite(
  .serialized,
  .enabled(if: ProcessInfo.processInfo.environment["YAAGL_LIVE"] == "1", "set YAAGL_LIVE=1")
)
struct SophonLiveContractTests {
  private let api = SophonAPI()

  @Test func APP_009_live_branchesBuildAndPatchBuildAnswer() async throws {
    let main = try #require(try await api.gameBranches().main)
    #expect(!main.tag.isEmpty)
    let build = try await api.build(for: main)
    #expect(build.tag == main.tag)
    #expect(try build.manifest(matching: "game").chunkURLPrefix != nil)
    // UPG-004: the POST on api-takumi answers for CN.
    let patch = try await api.patchBuild(for: main)
    #expect(patch.tag == main.tag)
    #expect(try patch.manifest(matching: "game").diffURLPrefix != nil)
  }

  @Test func APP_009_live_gameManifestsParse() async throws {
    let main = try #require(try await api.gameBranches().main)
    let game = try await api.build(for: main).manifest(matching: "game")
    let manifest = try await api.manifest(for: game)
    #expect(Int64(manifest.files.count) == game.stats?.fileCount)
    #expect(manifest.totalCompressedSize > 0)

    let diffRef = try await api.patchBuild(for: main).manifest(matching: "game")
    let diff = try await api.diffManifest(for: diffRef)
    #expect(!diff.files.isEmpty)
  }

  @Test func APP_009_live_smallestChunkDownloadsAndVerifies() async throws {
    let main = try #require(try await api.gameBranches().main)
    let ref = try await api.build(for: main).manifest(matching: "zh-cn")
    let manifest = try await api.manifest(for: ref)
    let chunk = try #require(manifest.files.flatMap(\.chunks).min { $0.compressedSize < $1.compressedSize })
    let prefix = try #require(ref.chunkURLPrefix)
    let (data, response) = try await URLSession.shared.data(from: URL(string: "\(prefix)/\(chunk.id)")!)
    #expect((response as? HTTPURLResponse)?.statusCode == 200)
    #expect(data.count == Int(chunk.compressedSize))
    let raw = try Zstd.decompress(data)
    #expect(raw.count == Int(chunk.uncompressedSize))
    let digest = Insecure.MD5.hash(data: raw).map { String(format: "%02x", $0) }.joined()
    #expect(digest == chunk.md5)
  }
}
