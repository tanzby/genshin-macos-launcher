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

  /// The smallest real ldiff segment is an uncompressed HDiffPatch diff that the vendored patcher parses
  /// and applies. The old file is a sparse zero file of the right size, so the output is wrong but the
  /// format, the compressor name and the size fields are exercised without any game files.
  @Test func UPG_009_live_smallestLdiffSegmentIsAnUncompressedHDiffPatch() async throws {
    let main = try #require(try await api.gameBranches().main)
    let ref = try await api.patchBuild(for: main).manifest(matching: "game")
    let diff = try await api.diffManifest(for: ref)
    let candidates = diff.files.flatMap { file in file.patches.values.map { (file, $0) } }
    let (file, patch) = try #require(
      candidates.filter { $0.1.length > 0 }.min {
        max($0.0.size, $0.1.originalSize) + $0.1.length < max($1.0.size, $1.1.originalSize) + $1.1.length
      })
    let prefix = try #require(ref.diffURLPrefix)
    var request = URLRequest(url: URL(string: "\(prefix)/\(patch.patchID)")!)
    request.setValue("bytes=\(patch.offset)-\(patch.offset + patch.length - 1)", forHTTPHeaderField: "Range")
    let (segment, response) = try await URLSession.shared.data(for: request)
    #expect((response as? HTTPURLResponse)?.statusCode == 206)
    #expect(segment.count == Int(patch.length))
    #expect(segment.prefix(9) == Data("HDIFF13&\0".utf8))

    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("live-hdiff-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let old = directory.appendingPathComponent("old")
    let ldiff = directory.appendingPathComponent("ldiff")
    FileManager.default.createFile(atPath: old.path, contents: nil)
    let handle = try FileHandle(forWritingTo: old)
    try handle.truncate(atOffset: UInt64(patch.originalSize))
    try handle.close()
    try segment.write(to: ldiff)
    try HDiffPatcher.apply(
      old: old, ldiff: ldiff, offset: 0, length: patch.length, to: directory.appendingPathComponent("new"),
      expectedSize: file.size, name: file.path, cancelled: CancelFlag())
  }

  /// `pre_download` is null outside a pre-download window; then there is nothing to check.
  @Test func PRE_002_live_predownloadBranchWhenOpenHasAPatchBuild() async throws {
    guard let pre = try await api.gameBranches().preDownload else { return }
    let patch = try await api.patchBuild(for: pre)
    #expect(patch.tag == pre.tag)
    let ref = try patch.manifest(matching: "game")
    #expect(ref.diffURLPrefix != nil)
    #expect(try await !api.diffManifest(for: ref).files.isEmpty)
    #expect(try await api.build(for: pre).manifest(matching: "game").chunkURLPrefix != nil)
  }
}
