import Foundation
import Testing

@testable import Sophon

@Suite struct SophonManifestTests {
  // MARK: zstd

  @Test func APP_009_zstdDecompressesAStandardFrame() throws {
    let framed = try Fixture.data("manifest-chunk", "zst")
    let raw = try Zstd.decompress(framed)
    #expect(raw.count > framed.count)
  }

  @Test func APP_009_zstdRejectsGarbage() {
    #expect(throws: SophonError.decompressionFailed) {
      _ = try Zstd.decompress(Data("definitely not zstd".utf8))
    }
  }

  @Test func APP_009_zstdRejectsTruncatedFrames() throws {
    let framed = try Fixture.data("manifest-chunk", "zst")
    #expect(throws: SophonError.decompressionFailed) {
      _ = try Zstd.decompress(framed.prefix(framed.count / 2))
    }
  }

  @Test func APP_009_zstdEnforcesAnOutputLimit() throws {
    let framed = try Fixture.data("manifest-chunk", "zst")
    #expect(throws: SophonError.decompressionFailed) {
      _ = try Zstd.decompress(framed, maxOutputSize: 100)
    }
  }

  // MARK: chunk manifest

  @Test func APP_009_chunkManifestParsesFilesAndChunks() throws {
    let manifest = try SophonManifest(zstdCompressed: Fixture.data("manifest-chunk", "zst"))
    #expect(manifest.files.count == 3)
    let first = manifest.files[0]
    #expect(first.path == "Audio_Chinese_pkg_version")
    #expect(first.size == 30322)
    #expect(first.md5 == "b12c32cd08f9a84a4795ee92eaa6c490")
    #expect(!first.isDirectory)
    let chunk = try #require(first.chunks.first)
    #expect(chunk.id == "03a7ba13abf7714a_b12c32cd08f9a84a4795ee92eaa6c490")
    #expect(chunk.compressedSize == 6482)
    #expect(chunk.uncompressedSize == 30322)
    #expect(chunk.offset == 0)
    #expect(chunk.compressedMD5 == "c7fd79c9a560cebad0bd713df7aeff3b")
  }

  @Test func APP_009_chunkManifestKeepsOffsetsOfMultiChunkFiles() throws {
    let manifest = try SophonManifest(zstdCompressed: Fixture.data("manifest-chunk", "zst"))
    let multi = try #require(manifest.files.first { $0.chunks.count > 1 })
    var expected: UInt64 = 0
    for chunk in multi.chunks {
      #expect(chunk.offset == expected)
      expected += UInt64(chunk.uncompressedSize)
    }
    #expect(expected == UInt64(multi.size))
  }

  @Test func APP_008_installSizeIsTheSumOfCompressedChunkSizes() throws {
    let manifest = try SophonManifest(zstdCompressed: Fixture.data("manifest-chunk", "zst"))
    let sum = manifest.files.flatMap(\.chunks).reduce(Int64(0)) { $0 + Int64($1.compressedSize) }
    #expect(manifest.totalCompressedSize == sum)
    #expect(sum > 0)
  }

  @Test func APP_009_directoryEntriesAreFlagged() throws {
    var proto = PbManifest()
    var dir = PbFileInfo()
    dir.filename = "YuanShen_Data/Plugins"
    dir.flags = 64
    proto.files = [dir]
    let manifest = try SophonManifest(raw: proto)
    #expect(manifest.files[0].isDirectory)
    #expect(manifest.files[0].size == 0)
  }

  @Test func APP_009_unknownFlagsAreRejected() {
    var proto = PbManifest()
    var file = PbFileInfo()
    file.filename = "a"
    file.flags = 7
    proto.files = [file]
    #expect(throws: SophonError.invalidManifest("unknown flags 7 for a")) {
      _ = try SophonManifest(raw: proto)
    }
  }

  @Test func APP_009_negativeSizesFromInt32OverflowAreRejected() {
    var proto = PbManifest()
    var file = PbFileInfo()
    file.filename = "big.pck"
    file.size = -5
    proto.files = [file]
    #expect(throws: SophonError.self) { _ = try SophonManifest(raw: proto) }
  }

  @Test func APP_009_garbageProtobufIsRejected() throws {
    let framed = try zstdCompress(Data([0xff, 0xff, 0xff, 0xff, 0x0f]))
    #expect(throws: SophonError.self) { _ = try SophonManifest(zstdCompressed: framed) }
  }

  // MARK: ldiff manifest

  @Test func UPG_009_ldiffManifestParsesPatchesPerOldVersion() throws {
    let manifest = try SophonDiffManifest(zstdCompressed: Fixture.data("manifest-ldiff", "zst"))
    #expect(manifest.files.count == 3)
    let patched = manifest.files[0]
    #expect(patched.path == "YuanShen_Data/StreamingAssets/AssetBundles/blocks/02/27275853.blk")
    #expect(patched.size == 1_253_109)
    #expect(patched.md5 == "7fa87b4ce342fa59aec23aeded00dc8d")
    #expect(Set(patched.patches.keys) == ["7.0.0", "6.7.0"])
    let patch = try #require(patched.patches["7.0.0"])
    #expect(patch.patchID == "eb9af3ffa39b6a42_360eb2b3c69d11b0ed694734a7a0ccc4")
    #expect(patch.patchSize == 69_946_772)
    #expect(patch.offset == 11_373_208)
    #expect(patch.length == 1_252_724)
    #expect(patch.originalPath == patched.path)
    #expect(patch.originalSize == 1_226_453)
    #expect(patch.originalMD5 == "7c8c76f298da94470bc2452d2fae08c9")
  }

  @Test func UPG_008_filesWithoutPatchesAreNewFiles() throws {
    let manifest = try SophonDiffManifest(zstdCompressed: Fixture.data("manifest-ldiff", "zst"))
    #expect(manifest.files.last?.patches.isEmpty == true)
  }

  @Test func UPG_007_deleteListsAreGroupedByOldVersion() throws {
    let manifest = try SophonDiffManifest(zstdCompressed: Fixture.data("manifest-ldiff", "zst"))
    #expect(!manifest.deletions.isEmpty)
    let (version, entries) = try #require(manifest.deletions.first)
    #expect(!version.isEmpty)
    let entry = try #require(entries.first)
    #expect(!entry.path.isEmpty)
    #expect(entry.md5.count == 32)
    #expect(entry.size > 0)
  }

  // MARK: download

  @Test func APP_009_manifestIsDownloadedFromPrefixSlashId() async throws {
    let framed = try Fixture.data("manifest-chunk", "zst")
    let (session, id) = StubURLProtocol.session { _ in (200, framed) }
    let api = SophonAPI(session: session)
    let ref = SophonManifestRef.stub(
      id: "manifest_x", manifestPrefix: "https://cdn.example.invalid/manifests/a/b")
    let manifest = try await api.manifest(for: ref)
    #expect(manifest.files.count == 3)
    let url = try #require(StubURLProtocol.seen(id).first?.url)
    #expect(url.absoluteString == "https://cdn.example.invalid/manifests/a/b/manifest_x")
  }

  @Test func APP_009_manifestDownloadHTTPErrorIsNotParsed() async throws {
    let (session, _) = StubURLProtocol.session { _ in (404, Data("<html/>".utf8)) }
    let api = SophonAPI(session: session)
    let ref = SophonManifestRef.stub(id: "m", manifestPrefix: "https://cdn.example.invalid/m")
    await #expect(throws: SophonError.http(status: 404)) { _ = try await api.manifest(for: ref) }
  }

  @Test func UPG_009_diffManifestIsDownloadedAndParsed() async throws {
    let framed = try Fixture.data("manifest-ldiff", "zst")
    let (session, _) = StubURLProtocol.session { _ in (200, framed) }
    let api = SophonAPI(session: session)
    let ref = SophonManifestRef.stub(id: "m", manifestPrefix: "https://cdn.example.invalid/m")
    #expect(try await api.diffManifest(for: ref).files.count == 3)
  }
}

/// Compresses with the system `zstd` frame format: a stored (raw) block inside a valid frame.
private func zstdCompress(_ raw: Data) throws -> Data {
  var frame = Data([0x28, 0xb5, 0x2f, 0xfd])  // magic
  frame.append(0x20)  // frame header: single segment, no checksum, no dict
  frame.append(UInt8(raw.count))  // content size (1 byte)
  let header = UInt32(raw.count << 3) | 1  // last block, raw type
  frame.append(contentsOf: [UInt8(header & 0xff), UInt8((header >> 8) & 0xff), UInt8((header >> 16) & 0xff)])
  frame.append(raw)
  return frame
}

extension SophonManifestRef {
  /// A manifest reference with only the fields the manifest download needs.
  static func stub(id: String, manifestPrefix: String) -> SophonManifestRef {
    SophonManifestRef(
      categoryID: "1", matchingField: "game", manifestID: id, manifestURLPrefix: manifestPrefix)
  }
}
