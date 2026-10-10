import CryptoKit
import Foundation
import Testing

@testable import Sophon

// Tests for ldiff incremental update and pre-download (UPG-007..012, PRE-001/002).
//
// Binary fixtures: `Fixtures/ldiff/` holds old/new files and one ldiff that concatenates three real
// HDiffPatch diffs. `scripts/dev/make-ldiff-fixtures` regenerates them with hdiffz built from the
// vendored tag; the tests never run hdiffz. The CDN is a URLProtocol stub.

// MARK: - Fixture data

private func md5Hex(_ data: Data) -> String {
  Insecure.MD5.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

private func bytes(seed: UInt64, count: Int) -> Data {
  var state = seed &* 0x9E37_79B9_7F4A_7C15 | 1
  var result = [UInt8]()
  result.reserveCapacity(count)
  for _ in 0..<count {
    state ^= state << 13
    state ^= state >> 7
    state ^= state << 17
    result.append(UInt8(truncatingIfNeeded: state >> 24))
  }
  return Data(result)
}

/// A valid zstd frame of stored blocks (the vendored zstd only decompresses).
private func zstdRawFrame(_ raw: Data) -> Data {
  var frame = Data([0x28, 0xB5, 0x2F, 0xFD, 0x00, 0x58])
  let maxBlock = 128 * 1024
  var offset = 0
  repeat {
    let size = min(maxBlock, raw.count - offset)
    let last = offset + size >= raw.count
    let header = UInt32(last ? 1 : 0) | UInt32(size << 3)
    frame.append(contentsOf: [UInt8(header & 0xFF), UInt8((header >> 8) & 0xFF), UInt8((header >> 16) & 0xFF)])
    frame.append(raw.subdata(in: offset..<(offset + size)))
    offset += size
  } while offset < raw.count
  return frame
}

private struct LdiffMeta: Decodable {
  struct Entry: Decodable {
    let name: String
    let singleStream: Bool
    let offset: Int64
    let length: Int64
    let oldSize: Int64
    let oldMD5: String
    let newSize: Int64
    let newMD5: String
  }
  let files: [Entry]
  let ldiffSize: Int64

  static func load() throws -> LdiffMeta {
    let url = try #require(
      Bundle.module.url(forResource: "meta", withExtension: "json", subdirectory: "Fixtures/ldiff"))
    return try JSONDecoder().decode(LdiffMeta.self, from: Data(contentsOf: url))
  }

  func entry(_ name: String) -> Entry { files.first { $0.name == name }! }
}

private func ldiffFixture(_ name: String) throws -> Data {
  let url = try #require(
    Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures/ldiff"))
  return try Data(contentsOf: url)
}

// MARK: - World: a game directory, a CDN and the manifests that describe them

private struct World {
  static let installed = "7.0.0"
  static let target = "7.1.0"
  static let ldiffID = "0123456789abcdef_0123456789abcdef0123456789abcdef01234567"

  let meta: LdiffMeta
  let ldiff: Data
  /// New content by manifest path.
  var contents: [String: Data] = [:]
  var chunkFiles: [SophonFile] = []
  var diffFiles: [SophonDiffFile] = []
  var chunkBlobs: [String: Data] = [:]
  var deletions: [SophonDeletedFile] = []

  /// `a.bin`, `b.bin`, `c.bin` are patched; `d.bin` has no patch for the installed version; `e.bin` is new.
  init() throws {
    meta = try LdiffMeta.load()
    ldiff = try ldiffFixture("fixture.ldiff")
    for name in ["a", "b", "c"] {
      let entry = meta.entry(name)
      let new = try ldiffFixture("\(name).new")
      addFile("data/\(name).bin", new: new)
      diffFiles.append(
        SophonDiffFile(
          path: "data/\(name).bin", size: entry.newSize, md5: entry.newMD5,
          patches: [
            Self.installed: SophonPatch(
              patchID: Self.ldiffID, patchSize: meta.ldiffSize, offset: entry.offset, length: entry.length,
              originalPath: "data/\(name).bin", originalSize: entry.oldSize, originalMD5: entry.oldMD5,
              buildID: "build")
          ]))
    }
    let d = bytes(seed: 40, count: 3000)
    addFile("data/d.bin", new: d)
    diffFiles.append(
      SophonDiffFile(
        path: "data/d.bin", size: Int64(d.count), md5: md5Hex(d),
        patches: [
          "6.0.0": SophonPatch(
            patchID: Self.ldiffID, patchSize: meta.ldiffSize, offset: 0, length: 10, originalPath: "data/d.bin",
            originalSize: 1, originalMD5: "00", buildID: "build")
        ]))
    let e = bytes(seed: 50, count: 70_000)
    addFile("new/e.bin", new: e)
    diffFiles.append(SophonDiffFile(path: "new/e.bin", size: Int64(e.count), md5: md5Hex(e), patches: [:]))
    let gone = bytes(seed: 60, count: 500)
    deletions = [SophonDeletedFile(path: "old/gone.bin", size: Int64(gone.count), md5: md5Hex(gone))]
  }

  private mutating func addFile(_ path: String, new: Data) {
    // Two chunks, so that a half-cached file can be told from a missing one.
    let half = max(1, new.count / 2)
    let pieces = [new.prefix(half), new.dropFirst(half)].filter { !$0.isEmpty }.map { Data($0) }
    var offset: UInt64 = 0
    var chunks: [SophonChunk] = []
    for (index, piece) in pieces.enumerated() {
      let id = "chunk-\(path.replacingOccurrences(of: "/", with: "_"))-\(index)"
      let frame = zstdRawFrame(piece)
      chunkBlobs[id] = frame
      chunks.append(
        SophonChunk(
          id: id, md5: md5Hex(piece), offset: offset, compressedSize: UInt32(frame.count),
          uncompressedSize: UInt32(piece.count), xxhash: 0, compressedMD5: md5Hex(frame)))
      offset += UInt64(piece.count)
    }
    contents[path] = new
    chunkFiles.append(
      SophonFile(path: path, isDirectory: false, size: Int64(new.count), md5: md5Hex(new), chunks: chunks))
  }

  var diff: SophonDiffManifest { SophonDiffManifest(files: diffFiles, deletions: [Self.installed: deletions]) }
  var manifest: SophonManifest { SophonManifest(files: chunkFiles) }

  var chunkRef: SophonManifestRef {
    SophonManifestRef(
      categoryID: "1", matchingField: "game", manifestID: "m", manifestURLPrefix: "https://cdn.test/manifests",
      chunkURLPrefix: "https://cdn.test/chunks")
  }
  var diffRef: SophonManifestRef {
    SophonManifestRef(
      categoryID: "1", matchingField: "game", manifestID: "m", manifestURLPrefix: "https://cdn.test/manifests",
      diffURLPrefix: "https://cdn.test/diffs")
  }
}

private final class FakeCDN: @unchecked Sendable {
  private let lock = NSLock()
  private var ldiff: Data
  private let chunks: [String: Data]
  private var gate: StubGate?
  private var ldiffGate: StubGate?
  private var failing: Set<String> = []

  init(ldiff: Data, chunks: [String: Data]) {
    self.ldiff = ldiff
    self.chunks = chunks
  }

  func replaceLdiff(_ data: Data) { lock.withLock { ldiff = data } }
  func holdLdiff(_ gate: StubGate?) { lock.withLock { ldiffGate = gate } }
  func fail(chunk id: String) { lock.withLock { _ = failing.insert(id) } }

  func reply(to request: URLRequest) -> StubReply {
    let name = request.url?.lastPathComponent ?? ""
    let (blob, held, isFailing): (Data?, StubGate?, Bool) = lock.withLock {
      if request.url?.path.hasPrefix("/diffs/") == true { return (name == World.ldiffID ? ldiff : nil, ldiffGate, false) }
      return (chunks[name], nil, failing.contains(name))
    }
    guard let blob, !isFailing else { return .response(status: 404, body: Data()) }
    var answer: StubReply = .response(status: 200, body: blob)
    if let header = request.value(forHTTPHeaderField: "Range"), header.hasPrefix("bytes="), header.hasSuffix("-"),
      let start = Int(header.dropFirst(6).dropLast()), start < blob.count
    {
      answer = .response(
        status: 206, body: Data(blob[start...]),
        headers: ["Content-Range": "bytes \(start)-\(blob.count - 1)/\(blob.count)"])
    }
    if let held { return .held(held, then: answer) }
    return answer
  }
}

private struct Rig {
  let world: World
  let root: URL
  let game: URL
  let temp: URL
  let cdn: FakeCDN
  let session: URLSession
  let id: String

  init() throws {
    world = try World()
    root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "sophon-updater-\(UUID().uuidString)", isDirectory: true
    ).resolvingSymlinksInPath()
    game = root.appendingPathComponent("game", isDirectory: true)
    temp = root.appendingPathComponent("tmp", isDirectory: true)
    try FileManager.default.createDirectory(at: game, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
    cdn = FakeCDN(ldiff: world.ldiff, chunks: world.chunkBlobs)
    let cdn = self.cdn
    (session, id) = StubURLProtocol.session(reply: { cdn.reply(to: $0) })
  }

  func remove() { try? FileManager.default.removeItem(at: root) }

  /// The installed 7.0.0: old a/b/c, the unchanged d, and a file that 7.1.0 drops.
  func installOldVersion() throws {
    for name in ["a", "b", "c"] { try write("data/\(name).bin", ldiffFixture("\(name).old")) }
    try write("data/d.bin", world.contents["data/d.bin"]!)
    try write("old/gone.bin", bytes(seed: 60, count: 500))
  }

  func write(_ path: String, _ data: Data) throws {
    let url = game.appendingPathComponent(path)
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try data.write(to: url)
  }

  func read(_ path: String) -> Data? { try? Data(contentsOf: game.appendingPathComponent(path)) }
  func exists(_ path: String) -> Bool { FileManager.default.fileExists(atPath: game.appendingPathComponent(path).path) }

  var updater: SophonUpdater {
    SophonUpdater(
      session: session,
      configuration: SophonDownloadConfiguration(
        concurrency: 4, maxAttempts: 2, retryDelay: .zero, progressInterval: .zero))
  }

  func plan(from version: String = World.installed) async throws -> SophonUpdatePlan {
    try await updater.plan(
      from: version, diff: world.diff, manifest: world.manifest, gameDirectory: game)
  }

  func update(_ plan: SophonUpdatePlan) async throws {
    try await updater.update(
      plan, diff: world.diffRef, chunks: world.chunkRef, gameDirectory: game, tempDirectory: temp,
      progress: { _ in })
  }

  func predownload(_ plan: SophonUpdatePlan, target: String = World.target) async throws {
    try await updater.predownload(
      plan, targetVersion: target, diff: world.diffRef, chunks: world.chunkRef, gameDirectory: game,
      tempDirectory: temp, progress: { _ in })
  }

  var requests: [URLRequest] { StubURLProtocol.seen(id) }
  var ldiffRequests: [URLRequest] { requests.filter { $0.url?.path.hasPrefix("/diffs/") == true } }
  var chunkRequests: [URLRequest] { requests.filter { $0.url?.path.hasPrefix("/chunks/") == true } }

  /// Regular files below `directory` with their sizes.
  func files(in directory: URL) -> [String: Int] {
    var result: [String: Int] = [:]
    let base = directory.standardizedFileURL.path
    guard let walker = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey])
    else { return result }
    for case let url as URL in walker {
      let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
      if values?.isRegularFile == true {
        result[String(url.standardizedFileURL.path.dropFirst(base.count + 1))] = values?.fileSize ?? 0
      }
    }
    return result
  }
}

private func withRig(_ body: (Rig) async throws -> Void) async throws {
  let rig = try Rig()
  defer { rig.remove() }
  try await body(rig)
}

private func waitUntil(timeout: Duration = .seconds(5), _ condition: () -> Bool) async -> Bool {
  let deadline = ContinuousClock.now + timeout
  while ContinuousClock.now < deadline {
    if condition() { return true }
    try? await Task.sleep(for: .milliseconds(5))
  }
  return condition()
}

// MARK: - HDiffPatch

@Suite(.timeLimit(.minutes(1))) struct HDiffPatcherTests {
  private func scratch() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("hdiff-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }

  private func fixtureURL(_ name: String) throws -> URL {
    try #require(Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures/ldiff"))
  }

  @Test(arguments: ["a", "b", "c"])
  func UPG_009_appliesTheSliceOfAnLdiffFileAtItsOffset(name: String) throws {
    let meta = try LdiffMeta.load()
    let entry = meta.entry(name)
    let directory = try scratch()
    defer { try? FileManager.default.removeItem(at: directory) }
    let output = directory.appendingPathComponent("out")
    try HDiffPatcher.apply(
      old: fixtureURL("\(name).old"), ldiff: fixtureURL("fixture.ldiff"), offset: entry.offset,
      length: entry.length, to: output, expectedSize: entry.newSize, name: name, cancelled: CancelFlag())
    let result = try Data(contentsOf: output)
    #expect(result.count == Int(entry.newSize))
    #expect(md5Hex(result) == entry.newMD5)
    #expect(try Data(contentsOf: fixtureURL("\(name).new")) == result)
  }

  @Test func UPG_009_theRealLdiffHeaderIsTheDefaultHdiffzFormat() throws {
    // Real CN ldiff segments start with "HDIFF13&" and an empty compressor name (checked live).
    let meta = try LdiffMeta.load()
    let ldiff = try ldiffFixture("fixture.ldiff")
    for name in ["a", "b"] {
      let entry = meta.entry(name)
      #expect(ldiff[Int(entry.offset)..<Int(entry.offset) + 9] == Data("HDIFF13&\0".utf8))
    }
  }

  @Test func UPG_009_aSliceThatIsNotADiffFails() throws {
    let meta = try LdiffMeta.load()
    let entry = meta.entry("a")
    let directory = try scratch()
    defer { try? FileManager.default.removeItem(at: directory) }
    // Starts one byte late: the header is gone.
    #expect(throws: SophonError.patchFailed(path: "a")) {
      try HDiffPatcher.apply(
        old: fixtureURL("a.old"), ldiff: fixtureURL("fixture.ldiff"), offset: entry.offset + 1,
        length: entry.length - 1, to: directory.appendingPathComponent("out"), expectedSize: entry.newSize,
        name: "a", cancelled: CancelFlag())
    }
  }

  @Test func UPG_009_aWrongOldFileFails() throws {
    let meta = try LdiffMeta.load()
    let entry = meta.entry("a")
    let directory = try scratch()
    defer { try? FileManager.default.removeItem(at: directory) }
    // b.old has another size than the diff of a was made for.
    #expect(throws: SophonError.patchFailed(path: "a")) {
      try HDiffPatcher.apply(
        old: fixtureURL("b.old"), ldiff: fixtureURL("fixture.ldiff"), offset: entry.offset, length: entry.length,
        to: directory.appendingPathComponent("out"), expectedSize: entry.newSize, name: "a", cancelled: CancelFlag())
    }
  }

  @Test func UPG_009_aWrongExpectedSizeFails() throws {
    let meta = try LdiffMeta.load()
    let entry = meta.entry("a")
    let directory = try scratch()
    defer { try? FileManager.default.removeItem(at: directory) }
    #expect(throws: SophonError.patchFailed(path: "a")) {
      try HDiffPatcher.apply(
        old: fixtureURL("a.old"), ldiff: fixtureURL("fixture.ldiff"), offset: entry.offset, length: entry.length,
        to: directory.appendingPathComponent("out"), expectedSize: entry.newSize + 1, name: "a",
        cancelled: CancelFlag())
    }
  }

  @Test func UPG_009_aCancelledPatchStopsWithCancellationError() throws {
    let meta = try LdiffMeta.load()
    let entry = meta.entry("a")
    let directory = try scratch()
    defer { try? FileManager.default.removeItem(at: directory) }
    let flag = CancelFlag()
    flag.set()
    #expect(throws: CancellationError.self) {
      try HDiffPatcher.apply(
        old: fixtureURL("a.old"), ldiff: fixtureURL("fixture.ldiff"), offset: entry.offset, length: entry.length,
        to: directory.appendingPathComponent("out"), expectedSize: entry.newSize, name: "a", cancelled: flag)
    }
  }

  @Test func UPG_009_theCNLdiffManifestFixtureYieldsOffsetsInsideTheirLdiffFiles() throws {
    // Real metadata: every patch of the trimmed real ldiff manifest lies inside its ldiff file.
    let diff = try SophonDiffManifest(zstdCompressed: Fixture.data("manifest-ldiff", "zst"))
    var patches = 0
    for file in diff.files {
      for patch in file.patches.values {
        patches += 1
        #expect(patch.offset >= 0 && patch.length > 0 && patch.offset + patch.length <= patch.patchSize)
        #expect(SophonDownloaderLayout.isSafeName(patch.patchID))
      }
    }
    #expect(patches > 0)
  }
}

// MARK: - Plan

@Suite(.timeLimit(.minutes(1))) struct SophonUpdatePlanTests {
  @Test func UPG_008_aFileWithAnOldMD5IsPatchedAndPatchlessEntriesAreDownloaded() async throws {
    try await withRig { rig in
      try rig.installOldVersion()
      let plan = try await rig.plan()
      #expect(plan.patches.map(\.file.path).sorted() == ["data/a.bin", "data/b.bin", "data/c.bin"])
      #expect(plan.downloads.map(\.path) == ["new/e.bin"])
      #expect(plan.deletions.map(\.path) == ["old/gone.bin"])
      // One ldiff file serves all three patches.
      #expect(plan.ldiffs == [SophonLdiffFile(id: World.ldiffID, size: rig.world.meta.ldiffSize)])
      #expect(plan.ldiffSize == rig.world.meta.ldiffSize)
      #expect(plan.chunkSize > 0)
    }
  }

  @Test func UPG_008_noPatchForTheInstalledVersionLeavesTheFileAlone() async throws {
    try await withRig { rig in
      try rig.installOldVersion()
      try FileManager.default.removeItem(at: rig.game.appendingPathComponent("data/d.bin"))
      let plan = try await rig.plan()
      // d.bin only has a patch from 6.0.0: it is neither patched nor downloaded, even when missing.
      #expect(!plan.patches.map(\.file.path).contains("data/d.bin"))
      #expect(!plan.downloads.map(\.path).contains("data/d.bin"))
    }
  }

  @Test func UPG_008_aFileThatIsAlreadyTheNewVersionIsSkipped() async throws {
    try await withRig { rig in
      try rig.installOldVersion()
      try rig.write("data/a.bin", rig.world.contents["data/a.bin"]!)
      try rig.write("new/e.bin", rig.world.contents["new/e.bin"]!)
      let plan = try await rig.plan()
      #expect(plan.patches.map(\.file.path).sorted() == ["data/b.bin", "data/c.bin"])
      #expect(plan.downloads.isEmpty)
    }
  }

  @Test func UPG_008_aMissingFileIsDownloaded() async throws {
    try await withRig { rig in
      try rig.installOldVersion()
      try FileManager.default.removeItem(at: rig.game.appendingPathComponent("data/b.bin"))
      let plan = try await rig.plan()
      #expect(plan.downloads.map(\.path).sorted() == ["data/b.bin", "new/e.bin"])
      #expect(!plan.patches.map(\.file.path).contains("data/b.bin"))
    }
  }

  @Test func UPG_008_rightSizeWrongMD5BeforePatchingIsDownloadedNotPatched() async throws {
    try await withRig { rig in
      try rig.installOldVersion()
      // Same size as the old a.bin, different content: the patch would give garbage.
      try rig.write("data/a.bin", bytes(seed: 999, count: Int(rig.world.meta.entry("a").oldSize)))
      let plan = try await rig.plan()
      #expect(!plan.patches.map(\.file.path).contains("data/a.bin"))
      #expect(plan.downloads.map(\.path).contains("data/a.bin"))
    }
  }

  @Test func UPG_008_aRepeatedManifestPathDoesNotCrashAndIsDownloadedOnce() async throws {
    try await withRig { rig in
      try rig.installOldVersion()
      var world = rig.world
      world.diffFiles.append(world.diffFiles.last!)
      let plan = try await rig.updater.plan(
        from: World.installed, diff: world.diff, manifest: world.manifest, gameDirectory: rig.game)
      #expect(plan.downloads.map(\.path) == ["new/e.bin"])
    }
  }

  @Test func UPG_008_aVersionTheServerHasNoPatchesForIsRefused() async throws {
    try await withRig { rig in
      try rig.installOldVersion()
      // Without this check every file would read as "not modified" and the update would do nothing.
      await #expect(throws: SophonError.versionNotPatchable("5.0.0")) {
        _ = try await rig.plan(from: "5.0.0")
      }
    }
  }

  @Test func UPG_008_aPatchPathOutsideTheGameDirectoryIsRefusedBeforeAnyRequest() async throws {
    try await withRig { rig in
      var world = rig.world
      let file = world.diffFiles[0]
      let bad = SophonPatch(
        patchID: World.ldiffID, patchSize: world.meta.ldiffSize, offset: 0, length: 10,
        originalPath: "../outside.bin", originalSize: 1, originalMD5: "00", buildID: "b")
      world.diffFiles[0] = SophonDiffFile(path: file.path, size: file.size, md5: file.md5, patches: [World.installed: bad])
      await #expect(throws: SophonError.unsafePath("../outside.bin")) {
        _ = try await rig.updater.plan(
          from: World.installed, diff: world.diff, manifest: world.manifest, gameDirectory: rig.game)
      }
      #expect(rig.requests.isEmpty)
    }
  }

  @Test func UPG_008_aHostilePatchRangeOrIdIsRefusedBeforeAnyRequest() async throws {
    try await withRig { rig in
      try rig.installOldVersion()
      let planned = try await rig.plan()
      func patched(_ edit: (SophonPatch) -> SophonPatch) -> SophonUpdatePlan {
        let first = planned.patches[0]
        let replaced = SophonPlannedPatch(file: first.file, patch: edit(first.patch), fallback: first.fallback)
        return SophonUpdatePlan(
          fromVersion: planned.fromVersion, patches: [replaced] + planned.patches.dropFirst(),
          downloads: planned.downloads, deletions: planned.deletions, expectedFiles: planned.expectedFiles)
      }
      func with(id: String? = nil, size: Int64? = nil, offset: Int64? = nil, length: Int64? = nil)
        -> (SophonPatch) -> SophonPatch
      {
        { p in
          SophonPatch(
            patchID: id ?? p.patchID, patchSize: size ?? p.patchSize, offset: offset ?? p.offset,
            length: length ?? p.length, originalPath: p.originalPath, originalSize: p.originalSize,
            originalMD5: p.originalMD5, buildID: p.buildID)
        }
      }
      let hostile = [
        patched(with(id: "../x")), patched(with(offset: Int64.max, length: 10)),
        patched(with(offset: 0, length: 0)), patched(with(offset: -1)),
        patched(with(size: 5)),
      ]
      for plan in hostile {
        await #expect(throws: SophonError.self) { try await rig.update(plan) }
        await #expect(throws: SophonError.self) { try await rig.predownload(plan) }
      }
      #expect(rig.requests.isEmpty)
    }
  }
}

// MARK: - Update

@Suite(.timeLimit(.minutes(1))) struct SophonUpdateTests {
  @Test func UPG_009_updatePatchesDownloadsDeletesAndCleansUp() async throws {
    try await withRig { rig in
      try rig.installOldVersion()
      try await rig.update(rig.plan())
      for path in ["data/a.bin", "data/b.bin", "data/c.bin", "data/d.bin", "new/e.bin"] {
        #expect(rig.read(path) == rig.world.contents[path], "\(path)")
      }
      // UPG-007
      #expect(!rig.exists("old/gone.bin"))
      // The ldiff file serves three patches and is fetched once.
      #expect(rig.ldiffRequests.count == 1)
      // The new file came as chunks; the patched ones did not.
      #expect(rig.chunkRequests.map { $0.url!.lastPathComponent }.allSatisfy { $0.contains("new_e.bin") })
      // UPG-012
      let leftovers = rig.files(in: rig.temp)
      #expect(leftovers.keys.allSatisfy { !$0.contains(World.ldiffID) }, "\(leftovers.keys)")
      #expect(!leftovers.keys.contains { $0.hasSuffix(".patched") })
    }
  }

  @Test func UPG_012_theLdiffDirectoryStaysButTheUsedFilesGo() async throws {
    try await withRig { rig in
      try rig.installOldVersion()
      try rig.write("data/zzz.bin", Data()) // unrelated file must stay untouched
      try await rig.update(rig.plan())
      var isDirectory: ObjCBool = false
      #expect(FileManager.default.fileExists(atPath: rig.temp.appendingPathComponent("ldiff").path, isDirectory: &isDirectory))
      #expect(isDirectory.boolValue)
      #expect(!FileManager.default.fileExists(atPath: rig.temp.appendingPathComponent("ldiff/\(World.ldiffID)").path))
      #expect(rig.exists("data/zzz.bin"))
    }
  }

  @Test func UPG_007_oldFilesAreDeletedAfterPatchingAndMissingOnesAreSkipped() async throws {
    try await withRig { rig in
      try rig.installOldVersion()
      try FileManager.default.removeItem(at: rig.game.appendingPathComponent("old/gone.bin"))
      try await rig.update(rig.plan())  // nothing to delete, and no error
      #expect(!rig.exists("old/gone.bin"))
    }
  }

  @Test func UPG_007_aFileTheNewVersionStillListsIsNeverDeleted() async throws {
    try await withRig { rig in
      try rig.installOldVersion()
      var world = rig.world
      world.deletions.append(SophonDeletedFile(path: "data/d.bin", size: 3000, md5: "x"))
      let plan = try await rig.updater.plan(
        from: World.installed, diff: world.diff, manifest: world.manifest, gameDirectory: rig.game)
      try await rig.update(plan)
      #expect(rig.read("data/d.bin") == world.contents["data/d.bin"])
    }
  }

  @Test func UPG_007_aDeletionThatIsAFolderOfNewFilesIsRefusedBeforeAnyRequest() async throws {
    try await withRig { rig in
      try rig.installOldVersion()
      for folder in ["data", "DATA/", "new"] {
        var world = rig.world
        world.deletions = [SophonDeletedFile(path: folder, size: 0, md5: "")]
        await #expect(throws: SophonError.self) {
          _ = try await rig.updater.plan(
            from: World.installed, diff: world.diff, manifest: world.manifest, gameDirectory: rig.game)
        }
      }
      #expect(rig.requests.isEmpty)
      #expect(rig.exists("data/a.bin"))
    }
  }

  @Test func UPG_007_aDeletionThatIsAFolderOnDiskIsNeverRemoved() async throws {
    try await withRig { rig in
      try rig.installOldVersion()
      try rig.write("other/keep.bin", Data([1, 2, 3]))
      var world = rig.world
      world.deletions = [SophonDeletedFile(path: "other", size: 0, md5: "")]
      let plan = try await rig.updater.plan(
        from: World.installed, diff: world.diff, manifest: world.manifest, gameDirectory: rig.game)
      await #expect(throws: SophonError.self) {
        try await rig.updater.update(
          plan, diff: world.diffRef, chunks: world.chunkRef, gameDirectory: rig.game, tempDirectory: rig.temp,
          progress: { _ in })
      }
      #expect(rig.exists("other/keep.bin"))
    }
  }

  @Test func UPG_007_aSymlinkIsRemovedWithoutTouchingItsTarget() async throws {
    try await withRig { rig in
      try rig.installOldVersion()
      try rig.write("target/keep.bin", Data([9]))
      try FileManager.default.removeItem(at: rig.game.appendingPathComponent("old/gone.bin"))
      try FileManager.default.createSymbolicLink(
        at: rig.game.appendingPathComponent("old/gone.bin"), withDestinationURL: rig.game.appendingPathComponent("target"))
      try await rig.update(rig.plan())
      #expect(FileManager.default.fileExists(atPath: rig.game.appendingPathComponent("old/gone.bin").path) == false)
      #expect(rig.exists("target/keep.bin"))
    }
  }

  @Test func UPG_007_aDeletionOutsideTheGameDirectoryIsRefused() async throws {
    try await withRig { rig in
      try rig.installOldVersion()
      var world = rig.world
      world.deletions = [SophonDeletedFile(path: "../victim.bin", size: 1, md5: "x")]
      await #expect(throws: SophonError.unsafePath("../victim.bin")) {
        _ = try await rig.updater.plan(
          from: World.installed, diff: world.diff, manifest: world.manifest, gameDirectory: rig.game)
      }
    }
  }

  @Test func UPG_009_aBadPatchFallsBackToTheChunkDownload() async throws {
    try await withRig { rig in
      try rig.installOldVersion()
      // The server's ldiff is damaged: a's diff no longer decodes.
      var broken = rig.world.ldiff
      let entry = rig.world.meta.entry("a")
      for i in 0..<16 { broken[Int(entry.offset) + i] = 0x55 }
      rig.cdn.replaceLdiff(broken)
      try await rig.update(rig.plan())
      #expect(rig.read("data/a.bin") == rig.world.contents["data/a.bin"])
      #expect(rig.chunkRequests.contains { $0.url!.lastPathComponent.contains("data_a.bin") })
      // The others were still patched.
      #expect(!rig.chunkRequests.contains { $0.url!.lastPathComponent.contains("data_b.bin") })
    }
  }

  @Test func UPG_009_aPatchedFileWithTheWrongMD5NeverReplacesTheOriginal() async throws {
    try await withRig { rig in
      try rig.installOldVersion()
      // The manifest promises another MD5 than the diff produces, and the chunk fallback is unavailable.
      var world = rig.world
      let file = world.diffFiles[0]
      world.diffFiles[0] = SophonDiffFile(path: file.path, size: file.size, md5: String(repeating: "0", count: 32), patches: file.patches)
      let chunkFile = world.chunkFiles.first { $0.path == file.path }!
      for chunk in chunkFile.chunks { rig.cdn.fail(chunk: chunk.id) }
      let plan = try await rig.updater.plan(
        from: World.installed, diff: world.diff, manifest: world.manifest, gameDirectory: rig.game)
      await #expect(throws: (any Error).self) {
        try await rig.updater.update(
          plan, diff: world.diffRef, chunks: world.chunkRef, gameDirectory: rig.game, tempDirectory: rig.temp,
          progress: { _ in })
      }
      #expect(rig.read("data/a.bin") == (try ldiffFixture("a.old")), "the original must survive")
      #expect(!rig.files(in: rig.temp).keys.contains { $0.hasSuffix(".patched") })
    }
  }

  @Test func UPG_009_theOldFileIsCheckedAgainAtPatchTime() async throws {
    try await withRig { rig in
      try rig.installOldVersion()
      let plan = try await rig.plan()
      // Between planning and patching the file changes (same size): it must not be patched.
      try rig.write("data/b.bin", bytes(seed: 77, count: Int(rig.world.meta.entry("b").oldSize)))
      try await rig.update(plan)
      #expect(rig.read("data/b.bin") == rig.world.contents["data/b.bin"])
      #expect(rig.chunkRequests.contains { $0.url!.lastPathComponent.contains("data_b.bin") })
    }
  }

  @Test func UPG_009_aRenamedFileIsPatchedFromItsOldPath() async throws {
    try await withRig { rig in
      try rig.installOldVersion()
      var world = rig.world
      // a.old now lives at data/a-renamed.bin and the new file has the name data/a.bin.
      try FileManager.default.moveItem(
        at: rig.game.appendingPathComponent("data/a.bin"), to: rig.game.appendingPathComponent("data/a-renamed.bin"))
      let file = world.diffFiles[0]
      let old = file.patches[World.installed]!
      world.diffFiles[0] = SophonDiffFile(
        path: file.path, size: file.size, md5: file.md5,
        patches: [
          World.installed: SophonPatch(
            patchID: old.patchID, patchSize: old.patchSize, offset: old.offset, length: old.length,
            originalPath: "data/a-renamed.bin", originalSize: old.originalSize, originalMD5: old.originalMD5,
            buildID: old.buildID)
        ])
      world.deletions.append(SophonDeletedFile(path: "data/a-renamed.bin", size: old.originalSize, md5: old.originalMD5))
      let plan = try await rig.updater.plan(
        from: World.installed, diff: world.diff, manifest: world.manifest, gameDirectory: rig.game)
      #expect(plan.patches.map(\.file.path).contains("data/a.bin"))
      try await rig.updater.update(
        plan, diff: world.diffRef, chunks: world.chunkRef, gameDirectory: rig.game, tempDirectory: rig.temp,
        progress: { _ in })
      #expect(rig.read("data/a.bin") == world.contents["data/a.bin"])
      #expect(!rig.exists("data/a-renamed.bin"))
    }
  }

  @Test func UPG_011_aMissingFileOfTheNewVersionFailsTheFinalCheck() async throws {
    try await withRig { rig in
      try rig.installOldVersion()
      let plan = try await rig.plan()
      // d.bin is "not modified" for this version; if it disappears the check must notice.
      try FileManager.default.removeItem(at: rig.game.appendingPathComponent("data/d.bin"))
      await #expect(throws: SophonError.verificationFailed(path: "data/d.bin")) { try await rig.update(plan) }
    }
  }

  @Test func UPG_007_anOldFileThatCannotBeRemovedFailsTheUpdate() async throws {
    try await withRig { rig in
      try rig.installOldVersion()
      let plan = try await rig.plan()
      // Immutable flag: removeItem fails, so the update stops with an error.
      let url = rig.game.appendingPathComponent("old/gone.bin")
      try FileManager.default.setAttributes([.immutable: true], ofItemAtPath: url.path)
      defer { try? FileManager.default.setAttributes([.immutable: false], ofItemAtPath: url.path) }
      await #expect(throws: (any Error).self) { try await rig.update(plan) }
    }
  }

  @Test func UPG_009_rerunningAfterACompleteUpdateDoesNothing() async throws {
    try await withRig { rig in
      try rig.installOldVersion()
      try await rig.update(rig.plan())
      let before = rig.requests.count
      let again = try await rig.plan()
      #expect(again.isUpToDate)
      try await rig.update(again)
      #expect(rig.requests.count == before)
      #expect(rig.read("data/a.bin") == rig.world.contents["data/a.bin"])
    }
  }

  @Test func UPG_009_theSamePlanRunTwiceIsHarmless() async throws {
    try await withRig { rig in
      try rig.installOldVersion()
      let plan = try await rig.plan()
      try await rig.update(plan)
      // A stale plan after a crash between the last step and bookkeeping: files already match.
      try await rig.update(plan)
      for path in ["data/a.bin", "data/b.bin", "data/c.bin"] {
        #expect(rig.read(path) == rig.world.contents[path])
      }
    }
  }

  @Test func UPG_009_pausingDuringTheLdiffDownloadStopsCleanlyAndTheRerunFinishes() async throws {
    try await withRig { rig in
      try rig.installOldVersion()
      let plan = try await rig.plan()
      let before = try snapshot(rig)
      let gate = StubGate()
      rig.cdn.holdLdiff(gate)
      let task = Task { try await rig.update(plan) }
      #expect(await waitUntil { rig.ldiffRequests.count >= 1 })
      task.cancel()  // pause = cancel and wait until everything has stopped
      await #expect(throws: CancellationError.self) { try await task.value }
      #expect(try snapshot(rig).filter { $0.key.hasPrefix("game/") } == before.filter { $0.key.hasPrefix("game/") })
      rig.cdn.holdLdiff(nil)
      try await rig.update(rig.plan())
      #expect(rig.read("data/a.bin") == rig.world.contents["data/a.bin"])
      #expect(!rig.exists("old/gone.bin"))
    }
  }

  @Test func UPG_009_aHalfDownloadedLdiffFileIsResumedWithRange() async throws {
    try await withRig { rig in
      try rig.installOldVersion()
      let plan = try await rig.plan()
      let half = Int(rig.world.meta.ldiffSize) / 2
      let directory = rig.temp.appendingPathComponent("ldiff")
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      try rig.world.ldiff.prefix(half).write(to: directory.appendingPathComponent(World.ldiffID))
      try await rig.update(plan)
      #expect(rig.ldiffRequests.first?.value(forHTTPHeaderField: "Range") == "bytes=\(half)-")
      #expect(rig.read("data/c.bin") == rig.world.contents["data/c.bin"])
    }
  }

  @Test func UPG_010_nothingIsDownloadedForFilesThatAreAlreadyInPlace() async throws {
    try await withRig { rig in
      try rig.installOldVersion()
      try rig.write("new/e.bin", rig.world.contents["new/e.bin"]!)
      try await rig.update(rig.plan())
      #expect(rig.chunkRequests.isEmpty)
    }
  }

  private func snapshot(_ rig: Rig) throws -> [String: Int] {
    var result: [String: Int] = [:]
    for (path, size) in rig.files(in: rig.game) { result["game/" + path] = size }
    for (path, size) in rig.files(in: rig.temp) { result["tmp/" + path] = size }
    return result
  }
}

// MARK: - Pre-download

@Suite(.timeLimit(.minutes(1))) struct SophonPredownloadTests {
  private func snapshotGame(_ rig: Rig) -> [String: Data] {
    var result: [String: Data] = [:]
    for path in rig.files(in: rig.game).keys { result[path] = rig.read(path) }
    return result
  }

  @Test func PRE_002_predownloadFetchesLdiffsAndNewChunksAndLeavesTheGameAlone() async throws {
    try await withRig { rig in
      try rig.installOldVersion()
      let before = snapshotGame(rig)
      let plan = try await rig.plan()
      try await rig.predownload(plan)
      #expect(snapshotGame(rig) == before, "the game directory must not change")
      let cached = rig.files(in: rig.temp)
      #expect(cached["ldiff/\(World.ldiffID)"] == Int(rig.world.meta.ldiffSize))
      let newChunks = rig.world.chunkFiles.first { $0.path == "new/e.bin" }!.chunks
      for chunk in newChunks {
        #expect(cached.keys.contains { $0.hasSuffix("/" + chunk.id) }, "chunk \(chunk.id) cached")
      }
      // Only the new file's chunks are prefetched, not the files that will be patched.
      #expect(rig.chunkRequests.allSatisfy { $0.url!.lastPathComponent.contains("new_e.bin") })
      #expect(rig.ldiffRequests.count == 1)
    }
  }

  @Test func PRE_002_theUpdateAfterAPredownloadOnlyDoesLocalWork() async throws {
    try await withRig { rig in
      try rig.installOldVersion()
      try await rig.predownload(rig.plan())
      let requestsBefore = rig.requests.count
      try await rig.update(rig.plan())
      #expect(rig.requests.count == requestsBefore, "no network access during the real update")
      for path in ["data/a.bin", "data/b.bin", "data/c.bin", "new/e.bin"] {
        #expect(rig.read(path) == rig.world.contents[path], "\(path)")
      }
      #expect(!rig.exists("old/gone.bin"))
    }
  }

  @Test func PRE_002_predownloadDoesNotDeleteApplyOrWriteVersionFiles() async throws {
    try await withRig { rig in
      try rig.installOldVersion()
      try await rig.predownload(rig.plan())
      #expect(rig.exists("old/gone.bin"))
      #expect(rig.read("data/a.bin") == (try ldiffFixture("a.old")))
      #expect(!rig.exists("new/e.bin"))
      #expect(!rig.exists("config.ini"))
    }
  }

  @Test func PRE_001_theRecordIsPerTargetVersion() async throws {
    try await withRig { rig in
      try rig.installOldVersion()
      #expect(!SophonUpdater.isPredownloaded("7.1.0", in: rig.temp))
      try await rig.predownload(rig.plan(), target: "7.1.0")
      #expect(SophonUpdater.isPredownloaded("7.1.0", in: rig.temp))
      // A newer pre-download (7.2.0) is not covered by the one for 7.1.0.
      #expect(!SophonUpdater.isPredownloaded("7.2.0", in: rig.temp))
    }
  }

  @Test func PRE_001_aPredownloadOfANewerTargetReplacesTheOldRecord() async throws {
    try await withRig { rig in
      try rig.installOldVersion()
      let plan = try await rig.plan()
      try await rig.predownload(plan, target: "7.1.0")
      try await rig.predownload(plan, target: "7.2.0")
      #expect(SophonUpdater.isPredownloaded("7.2.0", in: rig.temp))
      #expect(!SophonUpdater.isPredownloaded("7.1.0", in: rig.temp))
    }
  }

  @Test func PRE_001_anInterruptedPredownloadIsNotMarkedAndResumes() async throws {
    try await withRig { rig in
      try rig.installOldVersion()
      let plan = try await rig.plan()
      let gate = StubGate()
      rig.cdn.holdLdiff(gate)
      let task = Task { try await rig.predownload(plan) }
      #expect(await waitUntil { rig.ldiffRequests.count >= 1 })
      task.cancel()
      await #expect(throws: CancellationError.self) { try await task.value }
      #expect(!SophonUpdater.isPredownloaded(World.target, in: rig.temp))
      rig.cdn.holdLdiff(nil)
      try await rig.predownload(plan)
      #expect(SophonUpdater.isPredownloaded(World.target, in: rig.temp))
    }
  }

  @Test func PRE_002_anInstallIntoTheSameTempDirectoryKeepsThePrefetchedChunks() async throws {
    try await withRig { rig in
      try rig.installOldVersion()
      try await rig.predownload(rig.plan())
      // A repair of an unrelated file runs between the pre-download and the update.
      let other = rig.world.chunkFiles.first { $0.path == "data/d.bin" }!
      try FileManager.default.removeItem(at: rig.game.appendingPathComponent("data/d.bin"))
      try await SophonDownloader(session: rig.session).install(
        [other], using: rig.world.chunkRef, into: rig.game, tempDirectory: rig.temp, progress: { _ in })
      let before = rig.chunkRequests.count
      try await rig.update(rig.plan())
      #expect(rig.chunkRequests.count == before, "prefetched chunks of new/e.bin must still be cached")
      #expect(rig.read("new/e.bin") == rig.world.contents["new/e.bin"])
    }
  }

  @Test func PRE_001_theRecordIsGoneAfterTheUpdate() async throws {
    try await withRig { rig in
      try rig.installOldVersion()
      try await rig.predownload(rig.plan())
      try await rig.update(rig.plan())
      #expect(!SophonUpdater.isPredownloaded(World.target, in: rig.temp))
    }
  }

  @Test func PRE_002_predownloadIsIdempotent() async throws {
    try await withRig { rig in
      try rig.installOldVersion()
      let plan = try await rig.plan()
      try await rig.predownload(plan)
      let requests = rig.requests.count
      try await rig.predownload(plan)
      #expect(rig.requests.count == requests, "cached ldiff and chunks are not downloaded again")
    }
  }
}
