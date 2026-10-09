import CryptoKit
import Foundation
import Testing

@testable import Sophon

// Characterization tests for `SophonDownloader` (INS-007..011, REP-003/004, ADR 0002 pause).
//
// Contracts these tests invent because the interface does not pin them down (see the hand-off notes):
//  * A chunk is cached, still zstd-compressed, as one file `<tempDirectory>/<chunk.id>`.
//    Only `Rig.seedChunkCache` depends on that; every other temp-directory check walks all files.
//  * A chunk is fetched from `<chunkURLPrefix>/<chunk.id><chunkURLSuffix>`.
//  * `SophonError.checksumMismatch(path:)` carries `file.path`; `unsafePath` carries the raw string.
//  * Fixture chunks use `xxhash: 0`, so the downloader must not verify it.
//
// Where the expectation is the native fix rather than the legacy behaviour (REP-004 forced re-download,
// 416 restarts the chunk, original error kept, cancel not retried, same basename in two directories)
// the test name says so.

// MARK: - Fixture: zstd raw-block frames and synthetic files

/// Deterministic pseudo-random bytes. Different seeds give different content.
private func syntheticBytes(seed: Int, count: Int) -> Data {
  var state = UInt64(truncatingIfNeeded: seed) &* 0x9E37_79B9_7F4A_7C15 | 1
  var bytes = [UInt8]()
  bytes.reserveCapacity(count)
  for _ in 0..<count {
    state ^= state << 13
    state ^= state >> 7
    state ^= state << 17
    bytes.append(UInt8(truncatingIfNeeded: state >> 24))
  }
  return Data(bytes)
}

private func seedValue(_ label: String) -> Int {
  label.unicodeScalars.reduce(17) { ($0 &* 31 &+ Int($1.value)) & 0xFF_FFFF }
}

private func md5Hex(_ data: Data) -> String {
  Insecure.MD5.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

/// A valid zstd frame made of stored (raw) blocks of at most 128 KB. The vendored zstd cannot compress.
private func zstdRawFrame(_ raw: Data) -> Data {
  var frame = Data([0x28, 0xB5, 0x2F, 0xFD])  // magic
  frame.append(0x00)  // descriptor: multi-segment, no checksum, no dictionary, no content size
  frame.append(0x58)  // window descriptor
  let maxBlock = 128 * 1024
  var offset = 0
  repeat {
    let size = min(maxBlock, raw.count - offset)
    let last = offset + size >= raw.count
    let header = UInt32(last ? 1 : 0) | (0 << 1) | UInt32(size << 3)  // type 0 = raw
    frame.append(contentsOf: [
      UInt8(header & 0xFF), UInt8((header >> 8) & 0xFF), UInt8((header >> 16) & 0xFF),
    ])
    frame.append(raw.subdata(in: offset..<(offset + size)))
    offset += size
  } while offset < raw.count
  return frame
}

/// One chunk as the CDN would serve it.
private struct ChunkPiece {
  let id: String
  let plain: Data
  let frame: Data

  init(_ label: String, size: Int) {
    id = "chunk-\(label)"
    plain = syntheticBytes(seed: seedValue(label), count: size)
    frame = zstdRawFrame(plain)
  }
}

/// A manifest file together with the plain content and CDN blobs behind it.
private struct SyntheticFile {
  var file: SophonFile
  let plain: Data
  let pieces: [ChunkPiece]

  init(_ path: String, pieces: [ChunkPiece]) {
    var offset: UInt64 = 0
    var chunks: [SophonChunk] = []
    var plain = Data()
    for piece in pieces {
      chunks.append(
        SophonChunk(
          id: piece.id, md5: md5Hex(piece.plain), offset: offset,
          compressedSize: UInt32(piece.frame.count), uncompressedSize: UInt32(piece.plain.count),
          xxhash: 0, compressedMD5: md5Hex(piece.frame)))
      offset += UInt64(piece.plain.count)
      plain.append(piece.plain)
    }
    self.pieces = pieces
    self.plain = plain
    file = SophonFile(
      path: path, isDirectory: false, size: Int64(plain.count), md5: md5Hex(plain), chunks: chunks)
  }

  /// A file named `path` made of one chunk per entry of `sizes`, with chunk ids unique to `path`.
  init(_ path: String, sizes: [Int]) {
    self.init(
      path,
      pieces: sizes.enumerated().map {
        ChunkPiece("\(path.replacingOccurrences(of: "/", with: "_"))-\($0.offset)", size: $0.element)
      })
  }

  var compressedSize: Int64 { file.chunks.reduce(0) { $0 + Int64($1.compressedSize) } }
}

extension SophonFile {
  fileprivate func replacing(md5: String? = nil, size: Int64? = nil, chunks: [SophonChunk]? = nil)
    -> SophonFile
  {
    SophonFile(
      path: path, isDirectory: isDirectory, size: size ?? self.size, md5: md5 ?? self.md5,
      chunks: chunks ?? self.chunks)
  }
}

extension SophonChunk {
  fileprivate func replacing(md5: String? = nil, uncompressedSize: UInt32? = nil) -> SophonChunk {
    SophonChunk(
      id: id, md5: md5 ?? self.md5, offset: offset, compressedSize: compressedSize,
      uncompressedSize: uncompressedSize ?? self.uncompressedSize, xxhash: xxhash,
      compressedMD5: compressedMD5)
  }
}

// MARK: - Fake CDN

/// What the CDN is about to answer, handed to a per-chunk script.
private struct CDNRequest: Sendable {
  let chunkID: String
  /// 0 for the first request of this chunk id, 1 for the second, ...
  let attempt: Int
  /// `N` of a `Range: bytes=N-` header.
  let rangeStart: Int?
  /// The whole compressed chunk.
  let blob: Data
  /// What a healthy server would answer to this request.
  let standard: StubReply
}

private final class FakeCDN: @unchecked Sendable {
  typealias Script = @Sendable (CDNRequest) -> StubReply?

  private let lock = NSLock()
  private var blobs: [String: Data] = [:]
  private var attempts: [String: Int] = [:]
  private var instants: [String: [ContinuousClock.Instant]] = [:]
  private var scripts: [String: Script] = [:]
  private var rangeIgnoring: Set<String> = []
  private var delay: Duration

  init(delay: Duration) { self.delay = delay }

  func serve(_ files: SyntheticFile...) { serve(files) }
  func serve(_ files: [SyntheticFile]) {
    lock.withLock { for file in files { for piece in file.pieces { blobs[piece.id] = piece.frame } } }
  }

  /// Overrides the answer for requests of `chunk`; return nil to fall back to the healthy answer.
  func script(chunk: String, _ script: @escaping Script) {
    lock.withLock { scripts[chunk] = script }
  }

  func ignoreRange(for chunk: String) { lock.withLock { _ = rangeIgnoring.insert(chunk) } }

  func requestInstants(for chunk: String) -> [ContinuousClock.Instant] {
    lock.withLock { instants[chunk] ?? [] }
  }

  func reply(to request: URLRequest) -> StubReply {
    let chunkID = request.url?.lastPathComponent ?? ""
    let rangeStart = Self.rangeStart(of: request)
    let (blob, attempt, script, ignoresRange, delay) = lock.withLock {
      let attempt = attempts[chunkID, default: 0]
      attempts[chunkID] = attempt + 1
      instants[chunkID, default: []].append(.now)
      return (blobs[chunkID], attempt, scripts[chunkID], rangeIgnoring.contains(chunkID), self.delay)
    }
    guard let blob else { return .response(status: 404, body: Data()) }
    let standard: StubReply
    if let start = rangeStart, !ignoresRange {
      if start >= blob.count {
        standard = .response(
          status: 416, body: Data(), headers: ["Content-Range": "bytes */\(blob.count)"])
      } else {
        standard = .response(
          status: 206, body: Data(blob[start...]),
          headers: ["Content-Range": "bytes \(start)-\(blob.count - 1)/\(blob.count)"], delay: delay)
      }
    } else {
      standard = .response(status: 200, body: blob, delay: delay)
    }
    let scripted = CDNRequest(
      chunkID: chunkID, attempt: attempt, rangeStart: rangeStart, blob: blob, standard: standard)
    return script?(scripted) ?? standard
  }

  static func rangeStart(of request: URLRequest) -> Int? {
    guard let header = request.value(forHTTPHeaderField: "Range"), header.hasPrefix("bytes="),
      header.hasSuffix("-"), !header.dropFirst(6).dropLast().contains(",")
    else { return nil }
    return Int(header.dropFirst(6).dropLast())
  }
}

// MARK: - Sandbox and rig

private struct Sandbox {
  let root: URL
  let game: URL
  let temp: URL

  init() throws {
    let base = FileManager.default.temporaryDirectory.appendingPathComponent(
      "sophon-downloader-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    root = base.resolvingSymlinksInPath()
    game = root.appendingPathComponent("game", isDirectory: true)
    temp = root.appendingPathComponent("tmp", isDirectory: true)
    try FileManager.default.createDirectory(at: game, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
  }

  func remove() { try? FileManager.default.removeItem(at: root) }

  func read(_ relativePath: String) -> Data? {
    try? Data(contentsOf: game.appendingPathComponent(relativePath))
  }

  func exists(_ relativePath: String) -> Bool {
    FileManager.default.fileExists(atPath: game.appendingPathComponent(relativePath).path)
  }

  func write(_ relativePath: String, _ data: Data) throws {
    let url = game.appendingPathComponent(relativePath)
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try data.write(to: url)
  }

  /// Relative paths (and sizes) of every regular file below `directory`.
  static func regularFiles(in directory: URL) -> [String: Int] {
    var result: [String: Int] = [:]
    let base = directory.standardizedFileURL.path
    guard
      let walker = FileManager.default.enumerator(
        at: directory, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey])
    else { return result }
    for case let url as URL in walker {
      let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
      guard values?.isRegularFile == true else { continue }
      result[String(url.standardizedFileURL.path.dropFirst(base.count + 1))] = values?.fileSize ?? 0
    }
    return result
  }

  /// Everything below the game and temp directories, for before/after comparisons.
  func snapshot() -> [String: Int] {
    var result: [String: Int] = [:]
    for (path, size) in Self.regularFiles(in: game) { result["game/" + path] = size }
    for (path, size) in Self.regularFiles(in: temp) { result["tmp/" + path] = size }
    return result
  }
}

private final class ProgressLog: @unchecked Sendable {
  private let lock = NSLock()
  private var events: [SophonProgress] = []

  func record(_ event: SophonProgress) { lock.withLock { events.append(event) } }
  var all: [SophonProgress] { lock.withLock { events } }

  var downloading: [(done: Int64, total: Int64)] {
    all.compactMap { if case .downloading(let done, let total) = $0 { (done, total) } else { nil } }
  }

  var verifying: [(done: Int64, total: Int64)] {
    all.compactMap { if case .verifying(let done, let total) = $0 { (done, total) } else { nil } }
  }
}

private final class Flag: @unchecked Sendable {
  private let lock = NSLock()
  private var value = false
  func set() { lock.withLock { value = true } }
  var isSet: Bool { lock.withLock { value } }
}

/// An install running in the background.
private struct RunningInstall {
  let task: Task<Void, any Error>
  let finished: Flag

  /// Waits until the CDN has seen `count` requests. Records an issue and returns false when the
  /// install ends first (for instance because the stub fails at once) or nothing arrives in time.
  func waitForRequests(_ count: Int, in rig: Rig) async -> Bool {
    let deadline = ContinuousClock.now + .seconds(10)
    while ContinuousClock.now < deadline {
      if rig.requests.count >= count { return true }
      if finished.isSet {
        let outcome = await task.result
        Issue.record("install ended before \(count) request(s) arrived: \(outcome)")
        return false
      }
      try? await Task.sleep(for: .milliseconds(5))
    }
    Issue.record("timed out waiting for \(count) request(s); saw \(rig.requests.count)")
    task.cancel()
    return false
  }

  /// Expects the task to end with `CancellationError`.
  func expectCancelled() async {
    do {
      try await task.value
      Issue.record("install finished although it was cancelled")
    } catch is CancellationError {
    } catch {
      Issue.record("expected CancellationError, got \(error)")
    }
  }
}

private func waitUntil(timeout: Duration = .seconds(5), _ condition: () -> Bool) async -> Bool {
  let deadline = ContinuousClock.now + timeout
  while ContinuousClock.now < deadline {
    if condition() { return true }
    try? await Task.sleep(for: .milliseconds(5))
  }
  return condition()
}

private final class Rig: @unchecked Sendable {
  let sandbox: Sandbox
  let cdn: FakeCDN
  let session: URLSession
  let id: String
  let ref = SophonManifestRef(
    categoryID: "1", matchingField: "game", manifestID: "manifest", manifestURLPrefix: "https://cdn.test/manifests",
    chunkURLPrefix: "https://cdn.test/chunks")

  /// `delay` slows every healthy chunk answer so that concurrent requests overlap.
  init(delay: Duration = .zero) throws {
    sandbox = try Sandbox()
    cdn = FakeCDN(delay: delay)
    let cdn = self.cdn
    (session, id) = StubURLProtocol.session(reply: { cdn.reply(to: $0) })
  }

  func remove() { sandbox.remove() }

  func downloader(
    concurrency: Int = 4, maxAttempts: Int = 5, retryDelay: Duration = .zero,
    progressInterval: Duration = .zero
  ) -> SophonDownloader {
    SophonDownloader(
      session: session,
      configuration: SophonDownloadConfiguration(
        concurrency: concurrency, maxAttempts: maxAttempts, retryDelay: retryDelay,
        progressInterval: progressInterval))
  }

  func install(
    _ files: [SophonFile], downloader: SophonDownloader? = nil, log: ProgressLog = ProgressLog()
  ) async throws {
    try await (downloader ?? self.downloader()).install(
      files, using: ref, into: sandbox.game, tempDirectory: sandbox.temp,
      progress: { log.record($0) })
  }

  func startInstall(_ files: [SophonFile], downloader: SophonDownloader? = nil) -> RunningInstall {
    let flag = Flag()
    let downloader = downloader ?? self.downloader()
    let ref = self.ref
    let game = sandbox.game
    let temp = sandbox.temp
    let task = Task<Void, any Error> {
      defer { flag.set() }
      try await downloader.install(
        files, using: ref, into: game, tempDirectory: temp, progress: { _ in })
    }
    return RunningInstall(task: task, finished: flag)
  }

  var requests: [URLRequest] { StubURLProtocol.seen(id) }
  var requestedChunkIDs: [String] { requests.compactMap { $0.url?.lastPathComponent } }
  func requestCount(for chunk: String) -> Int { requestedChunkIDs.filter { $0 == chunk }.count }

  /// Where this contract keeps a partially or fully downloaded, still compressed chunk.
  func seedChunkCache(_ chunk: SophonChunk, of path: String, with bytes: Data) throws {
    let directory = sandbox.temp.appendingPathComponent("chunks").appendingPathComponent(
      SophonDownloaderLayout.fileKey(for: path))
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try bytes.write(to: directory.appendingPathComponent(chunk.id))
  }

  /// Regular files anywhere in the temp directory whose name mentions `chunk`.
  func cachedFiles(mentioning chunk: SophonChunk) -> [String] {
    Sandbox.regularFiles(in: sandbox.temp).keys.filter { $0.contains(chunk.id) }
  }
}

// MARK: - Tests

@Suite(.timeLimit(.minutes(1))) struct SophonDownloaderTests {

  // MARK: harness guards (these pass before the downloader exists)

  @Test func HARNESS_rawBlockFramesRoundTripThroughTheVendoredDecompressor() throws {
    for count in [0, 1, 1000, 128 * 1024, 128 * 1024 + 1, 300_000] {
      let plain = syntheticBytes(seed: count, count: count)
      #expect(try Zstd.decompress(zstdRawFrame(plain)) == plain, "size \(count)")
    }
  }

  @Test func HARNESS_syntheticBytesAreDeterministicAndDistinctPerSeed() {
    #expect(syntheticBytes(seed: 1, count: 64) == syntheticBytes(seed: 1, count: 64))
    #expect(syntheticBytes(seed: 1, count: 64) != syntheticBytes(seed: 2, count: 64))
  }

  @Test func HARNESS_fakeCDNServesRangesPartialBodiesAndHeldRequests() async throws {
    let rig = try Rig()
    defer { rig.remove() }
    let file = SyntheticFile("h.bin", sizes: [5_000])
    rig.cdn.serve(file)
    let id = file.pieces[0].id
    let url = URL(string: "https://cdn.test/chunks/\(id)")!
    let blob = file.pieces[0].frame

    // Range -> 206 with the tail only.
    var ranged = URLRequest(url: url)
    ranged.setValue("bytes=100-", forHTTPHeaderField: "Range")
    let (tail, tailResponse) = try await rig.session.data(for: ranged)
    #expect((tailResponse as? HTTPURLResponse)?.statusCode == 206)
    #expect(tail == blob.dropFirst(100))
    // Range past the end -> 416.
    var past = URLRequest(url: url)
    past.setValue("bytes=\(blob.count)-", forHTTPHeaderField: "Range")
    #expect(((try await rig.session.data(for: past)).1 as? HTTPURLResponse)?.statusCode == 416)

    // A truncated answer delivers its first bytes, then fails.
    rig.cdn.script(chunk: id) { request in
      .truncated(status: 200, body: request.blob, sending: 1_000)
    }
    var received = 0
    do {
      for try await _ in try await rig.session.bytes(from: url).0 { received += 1 }
      Issue.record("truncated body ended without an error")
    } catch let error as URLError {
      #expect(error.code == .networkConnectionLost)
    }
    #expect(received == 1_000, "received \(received)")

    // A held request stays in flight until cancelled, and never answers afterwards.
    let gate = StubGate()
    rig.cdn.script(chunk: id) { request in .held(gate, then: request.standard) }
    let before = rig.requests.count
    let task = Task { try await rig.session.data(from: url) }
    #expect(await waitUntil { StubURLProtocol.inFlight(rig.id) == 1 && rig.requests.count == before + 1 })
    task.cancel()
    #expect(await waitUntil { StubURLProtocol.inFlight(rig.id) == 0 })
    gate.open()
    await #expect(throws: (any Error).self) { try await task.value }
  }

  // MARK: INS-008 assembling and verifying

  @Test func INS_008_multiChunkFileIsAssembledAtItsRelativePathWithCorrectContent() async throws {
    let rig = try Rig()
    defer { rig.remove() }
    // The 200 000 byte chunk is a multi-block zstd frame.
    let file = SyntheticFile("GenshinImpact_Data/Persistent/a.bin", sizes: [40_000, 200_000, 12_345])
    rig.cdn.serve(file)

    try await rig.install([file.file])

    let written = try #require(rig.sandbox.read(file.file.path))
    #expect(written.count == 252_345)
    #expect(written == file.plain)
    #expect(md5Hex(written) == file.file.md5)
    #expect(
      Set(rig.requests.compactMap(\.url?.absoluteString))
        == Set(file.pieces.map { "https://cdn.test/chunks/\($0.id)" }))
  }

  @Test func INS_008_directoryEntryOnlyCreatesTheDirectory() async throws {
    let rig = try Rig()
    defer { rig.remove() }
    let directory = SophonFile(
      path: "GenshinImpact_Data/Plugins", isDirectory: true, size: 0, md5: "", chunks: [])

    try await rig.install([directory])

    var isDirectory: ObjCBool = false
    let exists = FileManager.default.fileExists(
      atPath: rig.sandbox.game.appendingPathComponent(directory.path).path, isDirectory: &isDirectory)
    #expect(exists && isDirectory.boolValue)
    #expect(rig.requests.isEmpty)
  }

  @Test func INS_008_sameBasenameInDifferentDirectoriesDoesNotOverwriteEachOther() async throws {
    let rig = try Rig(delay: .milliseconds(40))
    defer { rig.remove() }
    let first = SyntheticFile("a/data.bin", sizes: [30_000, 30_000])
    let second = SyntheticFile("b/data.bin", sizes: [25_000, 35_000])
    rig.cdn.serve(first, second)

    try await rig.install([first.file, second.file], downloader: rig.downloader(concurrency: 2))

    #expect(rig.sandbox.read("a/data.bin") == first.plain)
    #expect(rig.sandbox.read("b/data.bin") == second.plain)
  }

  @Test func INS_008_filesSharingAChunkIdAreBothAssembledCorrectly() async throws {
    let rig = try Rig(delay: .milliseconds(40))
    defer { rig.remove() }
    let shared = ChunkPiece("shared", size: 20_000)
    let first = SyntheticFile(
      "one.bin", pieces: [shared, ChunkPiece("only-in-one", size: 10_000)])
    let second = SyntheticFile(
      "two.bin", pieces: [shared, ChunkPiece("only-in-two", size: 15_000)])
    rig.cdn.serve(first, second)

    try await rig.install([first.file, second.file], downloader: rig.downloader(concurrency: 2))

    #expect(rig.sandbox.read("one.bin") == first.plain)
    #expect(rig.sandbox.read("two.bin") == second.plain)
  }

  @Test func INS_008_chunkWithWrongMD5ThrowsChecksumMismatchAndCreatesNoTargetFile() async throws {
    let rig = try Rig()
    defer { rig.remove() }
    let clean = SyntheticFile("Data/bad.bin", sizes: [10_000, 10_000])
    let badChunk = clean.file.chunks[1].replacing(md5: md5Hex(Data("not this chunk".utf8)))
    let file = clean.file.replacing(chunks: [clean.file.chunks[0], badChunk])
    rig.cdn.serve(clean)

    await #expect(throws: SophonError.checksumMismatch(path: file.path)) {
      try await rig.install([file], downloader: rig.downloader(maxAttempts: 1))
    }

    #expect(!rig.sandbox.exists(file.path))
    #expect(rig.cachedFiles(mentioning: badChunk).isEmpty, "a corrupt chunk must not stay in the cache")
  }

  @Test func INS_008_wholeFileMD5MismatchThrowsAndCreatesNoTargetFile() async throws {
    let rig = try Rig()
    defer { rig.remove() }
    let clean = SyntheticFile("Data/whole.bin", sizes: [10_000, 5_000])
    let file = clean.file.replacing(md5: md5Hex(Data("some other file".utf8)))
    rig.cdn.serve(clean)

    await #expect(throws: SophonError.checksumMismatch(path: file.path)) {
      try await rig.install([file], downloader: rig.downloader(maxAttempts: 1))
    }

    #expect(!rig.sandbox.exists(file.path))
    #expect(rig.requestedChunkIDs.count == 2, "both chunks were fetched before the mismatch")
  }

  @Test func INS_008_wholeFileMD5MismatchLeavesAnExistingFileUntouched() async throws {
    let rig = try Rig()
    defer { rig.remove() }
    let clean = SyntheticFile("Data/whole.bin", sizes: [10_000, 5_000])
    let file = clean.file.replacing(md5: md5Hex(Data("some other file".utf8)))
    rig.cdn.serve(clean)
    let old = Data("old content, wrong size".utf8)
    try rig.sandbox.write(file.path, old)

    await #expect(throws: SophonError.checksumMismatch(path: file.path)) {
      try await rig.install([file], downloader: rig.downloader(maxAttempts: 1))
    }

    #expect(rig.sandbox.read(file.path) == old)
    #expect(rig.requestedChunkIDs.count == 2, "the wrong-size file was downloaded for")
  }

  @Test func INS_008_completedFileLeavesNoChunkCacheOrAssemblyFileInTempDirectory() async throws {
    let rig = try Rig()
    defer { rig.remove() }
    let first = SyntheticFile("Data/x/one.bin", sizes: [20_000, 20_000])
    let second = SyntheticFile("two.bin", sizes: [5_000])
    rig.cdn.serve(first, second)

    try await rig.install([first.file, second.file])

    #expect(rig.sandbox.read(first.file.path) == first.plain)
    #expect(rig.sandbox.read(second.file.path) == second.plain)
    #expect(Sandbox.regularFiles(in: rig.sandbox.temp).isEmpty)
  }

  // MARK: invalid manifests

  @Test func INS_008_chunkRangeBeyondFileSizeIsAnInvalidManifest() async throws {
    let rig = try Rig()
    defer { rig.remove() }
    let clean = SyntheticFile("Data/short.bin", sizes: [500, 500])
    let file = clean.file.replacing(size: 900)  // second chunk ends at 1000
    rig.cdn.serve(clean)

    await #expect {
      try await rig.install([file], downloader: rig.downloader(maxAttempts: 1))
    } throws: { error in
      if case SophonError.invalidManifest = error { return true } else { return false }
    }
    #expect(!rig.sandbox.exists(file.path))
  }

  @Test(arguments: [4_000, 6_000])
  func INS_008_decompressedLengthDifferentFromDeclaredIsAnInvalidManifest(actual: Int) async throws {
    let rig = try Rig()
    defer { rig.remove() }
    let clean = SyntheticFile("Data/len.bin", sizes: [actual])
    // The chunk MD5 is right for what the frame really holds; only the declared length is wrong.
    let chunk = clean.file.chunks[0].replacing(uncompressedSize: 5_000)
    let file = clean.file.replacing(size: 5_000, chunks: [chunk])
    rig.cdn.serve(clean)

    await #expect {
      try await rig.install([file], downloader: rig.downloader(maxAttempts: 1))
    } throws: { error in
      if case SophonError.invalidManifest = error { return true } else { return false }
    }
    #expect(!rig.sandbox.exists(file.path))
  }

  // MARK: REP-004 and REP-003

  enum Damage: String, CaseIterable, CustomTestStringConvertible {
    case missing, shorter, longer, sameSizeWrongMD5
    var testDescription: String { rawValue }
  }

  @Test(arguments: Damage.allCases)
  func REP_004_installFixesFilesThatAreMissingOrDamaged(damage: Damage) async throws {
    let rig = try Rig()
    defer { rig.remove() }
    let file = SyntheticFile("Data/fix.bin", sizes: [30_000, 30_000])
    rig.cdn.serve(file)
    switch damage {
    case .missing: break
    case .shorter: try rig.sandbox.write(file.file.path, file.plain.prefix(1_000))
    case .longer: try rig.sandbox.write(file.file.path, file.plain + Data([0, 1, 2]))
    case .sameSizeWrongMD5:
      // Native fix: legacy skipped this file because the size matched (REP-004).
      var tampered = file.plain
      tampered[tampered.count / 2] ^= 0xFF
      try rig.sandbox.write(file.file.path, tampered)
    }

    try await rig.install([file.file])

    #expect(rig.sandbox.read(file.file.path) == file.plain)
    #expect(rig.requestedChunkIDs.count >= 2)
  }

  @Test func REP_004_installSendsNoRequestWhenSizeAndMD5BothMatch() async throws {
    let rig = try Rig()
    defer { rig.remove() }
    let file = SyntheticFile("Data/ok.bin", sizes: [30_000, 30_000])
    rig.cdn.serve(file)
    try rig.sandbox.write(file.file.path, file.plain)

    try await rig.install([file.file])

    #expect(rig.requests.isEmpty)
    #expect(rig.sandbox.read(file.file.path) == file.plain)
  }

  @Test func REP_003_findDamagedFilesReturnsMissingWrongSizeAndWrongMD5Only() async throws {
    let rig = try Rig()
    defer { rig.remove() }
    let intact = SyntheticFile("intact.bin", sizes: [3_000])
    let missing = SyntheticFile("missing.bin", sizes: [3_000])
    let wrongSize = SyntheticFile("Data/wrong-size.bin", sizes: [3_000])
    let wrongMD5 = SyntheticFile("Data/wrong-md5.bin", sizes: [3_000])
    try rig.sandbox.write(intact.file.path, intact.plain)
    try rig.sandbox.write(wrongSize.file.path, wrongSize.plain.dropLast())
    var tampered = wrongMD5.plain
    tampered[10] ^= 0x01
    try rig.sandbox.write(wrongMD5.file.path, tampered)

    let damaged = try await rig.downloader().findDamagedFiles(
      in: [intact.file, missing.file, wrongSize.file, wrongMD5.file], gameDirectory: rig.sandbox.game,
      progress: { _ in })

    #expect(damaged.map(\.path).sorted() == [missing.file.path, wrongMD5.file.path, wrongSize.file.path].sorted())
    #expect(damaged.contains(wrongMD5.file), "returns the manifest entries unchanged")
  }

  @Test func REP_003_findDamagedFilesReturnsNothingWhenEveryFileIsIntact() async throws {
    let rig = try Rig()
    defer { rig.remove() }
    let files = (0..<3).map { SyntheticFile("Data/f\($0).bin", sizes: [2_000 + $0]) }
    for file in files { try rig.sandbox.write(file.file.path, file.plain) }
    let log = ProgressLog()

    let damaged = try await rig.downloader().findDamagedFiles(
      in: files.map(\.file), gameDirectory: rig.sandbox.game, progress: { log.record($0) })

    #expect(damaged.isEmpty)
    // The scan itself ran and reported: a stub that returns [] without looking would send no event.
    #expect(!log.verifying.isEmpty)
  }

  @Test func REP_003_findDamagedFilesReportsVerifyingProgressEndingComplete() async throws {
    let rig = try Rig()
    defer { rig.remove() }
    let files = (0..<12).map { SyntheticFile("Data/v\($0).bin", sizes: [4_000 + $0]) }
    for file in files.prefix(8) { try rig.sandbox.write(file.file.path, file.plain) }
    let log = ProgressLog()

    let damaged = try await rig.downloader(progressInterval: .zero).findDamagedFiles(
      in: files.map(\.file), gameDirectory: rig.sandbox.game, progress: { log.record($0) })

    #expect(damaged.count == 4)
    let verifying = log.verifying
    #expect(!verifying.isEmpty)
    // The unit of done/total (files or bytes) is not pinned down, only that it is consistent.
    #expect(verifying.allSatisfy { $0.total == verifying[0].total && $0.total > 0 })
    #expect(zip(verifying, verifying.dropFirst()).allSatisfy { $0.done <= $1.done })
    #expect(verifying.last.map { $0.done == $0.total } == true)
  }

  // MARK: INS-009 resuming chunks

  @Test func INS_009_partialChunkInCacheIsResumedWithARangeRequestAndAppended() async throws {
    let rig = try Rig()
    defer { rig.remove() }
    let file = SyntheticFile("Data/resume.bin", sizes: [30_000])
    rig.cdn.serve(file)
    let have = file.pieces[0].frame.count / 3
    try rig.seedChunkCache(file.file.chunks[0], of: file.file.path, with: file.pieces[0].frame.prefix(have))

    try await rig.install([file.file])

    #expect(rig.requests.count == 1)
    #expect(rig.requests.first?.value(forHTTPHeaderField: "Range") == "bytes=\(have)-")
    #expect(rig.sandbox.read(file.file.path) == file.plain)
  }

  @Test func INS_009_serverIgnoringRangeAnswers200AndTheChunkIsRewrittenNotDuplicated() async throws {
    let rig = try Rig()
    defer { rig.remove() }
    let file = SyntheticFile("Data/resume.bin", sizes: [30_000])
    rig.cdn.serve(file)
    rig.cdn.ignoreRange(for: file.pieces[0].id)
    let have = file.pieces[0].frame.count / 3
    try rig.seedChunkCache(file.file.chunks[0], of: file.file.path, with: file.pieces[0].frame.prefix(have))

    try await rig.install([file.file])

    #expect(rig.requests.count == 1)
    #expect(rig.requests.first?.value(forHTTPHeaderField: "Range") == "bytes=\(have)-")
    #expect(rig.sandbox.read(file.file.path) == file.plain)
  }

  @Test func INS_009_chunkAlreadyCompleteInCacheSendsNoRequest() async throws {
    let rig = try Rig()
    defer { rig.remove() }
    let file = SyntheticFile("Data/cached.bin", sizes: [30_000])
    rig.cdn.serve(file)
    try rig.seedChunkCache(file.file.chunks[0], of: file.file.path, with: file.pieces[0].frame)

    try await rig.install([file.file])

    #expect(rig.requests.isEmpty)
    #expect(rig.sandbox.read(file.file.path) == file.plain)
  }

  @Test func INS_009_cachedChunkLargerThanExpectedIsDeletedAndDownloadedAgain() async throws {
    let rig = try Rig()
    defer { rig.remove() }
    let file = SyntheticFile("Data/big.bin", sizes: [30_000])
    rig.cdn.serve(file)
    let oversized = file.pieces[0].frame + Data(repeating: 0xFF, count: 100)
    try rig.seedChunkCache(file.file.chunks[0], of: file.file.path, with: oversized)

    try await rig.install([file.file])

    #expect(rig.sandbox.read(file.file.path) == file.plain)
    #expect(!rig.requests.isEmpty)
    #expect(
      rig.requests.allSatisfy { $0.value(forHTTPHeaderField: "Range") == nil },
      "an oversized cache is thrown away, not resumed")
  }

  @Test func INS_009_http416RestartsTheChunkFromScratch() async throws {
    // Native fix: legacy treated 416 as "already complete" and kept whatever was on disk.
    let rig = try Rig()
    defer { rig.remove() }
    let file = SyntheticFile("Data/416.bin", sizes: [30_000])
    rig.cdn.serve(file)
    rig.cdn.script(chunk: file.pieces[0].id) { request in
      request.rangeStart == nil ? nil : .response(status: 416, body: Data())
    }
    let have = file.pieces[0].frame.count / 3
    try rig.seedChunkCache(file.file.chunks[0], of: file.file.path, with: file.pieces[0].frame.prefix(have))

    try await rig.install([file.file])

    #expect(rig.sandbox.read(file.file.path) == file.plain)
    #expect(rig.requests.first?.value(forHTTPHeaderField: "Range") == "bytes=\(have)-")
    #expect(rig.requests.count >= 2)
    #expect(rig.requests.last?.value(forHTTPHeaderField: "Range") == nil)
  }

  @Test func INS_009_afterAMidStreamDropTheNextInstallRequestsOnlyTheRemainingBytes() async throws {
    let rig = try Rig()
    defer { rig.remove() }
    let file = SyntheticFile("Data/drop.bin", sizes: [60_000])
    rig.cdn.serve(file)
    let frameSize = file.pieces[0].frame.count
    rig.cdn.script(chunk: file.pieces[0].id) { request in
      request.attempt == 0
        ? .truncated(status: 200, body: request.blob, sending: request.blob.count / 2) : nil
    }

    await #expect(
      throws: SophonError.transport(code: URLError.networkConnectionLost.rawValue)
    ) {
      try await rig.install([file.file], downloader: rig.downloader(maxAttempts: 1))
    }
    #expect(!rig.sandbox.exists(file.file.path))

    try await rig.install([file.file])

    #expect(rig.requests.count == 2)
    let range = rig.requests.last?.value(forHTTPHeaderField: "Range")
    let resumedAt = rig.requests.last.flatMap(FakeCDN.rangeStart(of:))
    #expect(range != nil, "second install must resume, got no Range header")
    let offset = try #require(resumedAt)
    #expect(offset > 0 && offset <= frameSize / 2, "resumed at \(offset) of \(frameSize)")
    #expect(rig.sandbox.read(file.file.path) == file.plain)
  }

  @Test func INS_009_midStreamDropIsRetriedInsideTheSameInstallWithARange() async throws {
    let rig = try Rig()
    defer { rig.remove() }
    let file = SyntheticFile("Data/drop.bin", sizes: [60_000])
    rig.cdn.serve(file)
    let frameSize = file.pieces[0].frame.count
    rig.cdn.script(chunk: file.pieces[0].id) { request in
      request.attempt == 0
        ? .truncated(status: 200, body: request.blob, sending: request.blob.count / 2) : nil
    }

    try await rig.install([file.file], downloader: rig.downloader(maxAttempts: 3))

    #expect(rig.requests.count == 2)
    let offset = try #require(rig.requests.last.flatMap(FakeCDN.rangeStart(of:)))
    #expect(offset > 0 && offset <= frameSize / 2)
    #expect(rig.sandbox.read(file.file.path) == file.plain)
  }

  // MARK: INS-010 retries

  @Test func INS_010_serverErrorsAreRetriedUntilTheFileSucceeds() async throws {
    let rig = try Rig()
    defer { rig.remove() }
    let file = SyntheticFile("Data/flaky.bin", sizes: [20_000])
    rig.cdn.serve(file)
    rig.cdn.script(chunk: file.pieces[0].id) { request in
      request.attempt < 2 ? .response(status: 500, body: Data("oops".utf8)) : nil
    }

    try await rig.install([file.file], downloader: rig.downloader(maxAttempts: 5, retryDelay: .zero))

    #expect(rig.requestCount(for: file.pieces[0].id) == 3)
    #expect(rig.sandbox.read(file.file.path) == file.plain, "the 500 bodies must not leak into the file")
  }

  @Test func INS_010_exceedingMaxAttemptsThrowsTheOriginalHTTPError() async throws {
    let rig = try Rig()
    defer { rig.remove() }
    let file = SyntheticFile("Data/down.bin", sizes: [20_000])
    rig.cdn.serve(file)
    rig.cdn.script(chunk: file.pieces[0].id) { _ in .response(status: 503, body: Data()) }

    await #expect(throws: SophonError.http(status: 503)) {
      try await rig.install([file.file], downloader: rig.downloader(maxAttempts: 3))
    }

    #expect(rig.requestCount(for: file.pieces[0].id) == 3)
    #expect(!rig.sandbox.exists(file.file.path))
  }

  @Test func INS_010_http404IsNotRetried() async throws {
    let rig = try Rig()
    defer { rig.remove() }
    let file = SyntheticFile("Data/gone.bin", sizes: [20_000])  // never served: the CDN answers 404

    await #expect(throws: SophonError.http(status: 404)) {
      try await rig.install([file.file], downloader: rig.downloader(maxAttempts: 5))
    }

    #expect(rig.requests.count == 1)
  }

  @Test func INS_010_retryDelayDoublesBetweenAttempts() async throws {
    let rig = try Rig()
    defer { rig.remove() }
    let file = SyntheticFile("Data/backoff.bin", sizes: [10_000])
    rig.cdn.serve(file)
    let id = file.pieces[0].id
    rig.cdn.script(chunk: id) { request in
      request.attempt < 2 ? .response(status: 500, body: Data()) : nil
    }

    try await rig.install(
      [file.file], downloader: rig.downloader(maxAttempts: 4, retryDelay: .milliseconds(50)))

    let times = rig.cdn.requestInstants(for: id)
    try #require(times.count == 3)
    // Lower bounds only: scheduling can stretch a wait but never shorten it.
    #expect(times[1] - times[0] >= .milliseconds(45))
    #expect(times[2] - times[1] >= .milliseconds(95))
  }

  @Test func INS_010_cancellationIsNotRetried() async throws {
    let rig = try Rig()
    defer { rig.remove() }
    let file = SyntheticFile("Data/held.bin", sizes: [20_000])
    rig.cdn.serve(file)
    let gate = StubGate()
    defer { gate.open() }
    rig.cdn.script(chunk: file.pieces[0].id) { request in
      request.attempt == 0 ? .held(gate, then: request.standard) : nil
    }

    let running = rig.startInstall([file.file], downloader: rig.downloader(maxAttempts: 5))
    guard await running.waitForRequests(1, in: rig) else { return }
    running.task.cancel()
    await running.expectCancelled()
    gate.open()
    try await Task.sleep(for: .milliseconds(200))

    #expect(rig.requests.count == 1)
    #expect(!rig.sandbox.exists(file.file.path))
  }

  // MARK: pause (ADR 0002): cancel, wait until stopped, run again

  @Test func INS_009_pausedInstallStopsCleanlyAndResumesWithoutRepeatingFinishedFiles() async throws {
    let rig = try Rig()
    defer { rig.remove() }
    let a = SyntheticFile("a.bin", sizes: [20_000])
    let b = SyntheticFile("b.bin", sizes: [20_000, 20_000])
    let c = SyntheticFile("c.bin", sizes: [20_000])
    rig.cdn.serve(a, b, c)
    let gate = StubGate()
    defer { gate.open() }
    rig.cdn.script(chunk: b.pieces[0].id) { request in
      request.attempt == 0 ? .held(gate, then: request.standard) : nil
    }
    let files = [a.file, b.file, c.file]

    // concurrency 1 and equal sort keys: a finishes, then b's first chunk hangs.
    let running = rig.startInstall(files, downloader: rig.downloader(concurrency: 1))
    guard await running.waitForRequests(2, in: rig) else { return }
    #expect(await waitUntil { rig.requestCount(for: b.pieces[0].id) >= 1 })
    running.task.cancel()
    await running.expectCancelled()
    // Taken the moment the install has returned: nothing may change after this point.
    let requestsAtStop = rig.requests.count
    let filesAtStop = rig.sandbox.snapshot()

    #expect(await waitUntil { StubURLProtocol.inFlight(rig.id) == 0 }, "a request is still running")
    #expect(rig.sandbox.read("a.bin") == a.plain)
    #expect(!rig.sandbox.exists("b.bin"))
    #expect(!rig.sandbox.exists("c.bin"))

    gate.open()
    try await Task.sleep(for: .milliseconds(300))
    #expect(rig.requests.count == requestsAtStop, "a stopped install issued a request")
    #expect(rig.sandbox.snapshot() == filesAtStop, "a stopped install kept writing")

    try await rig.install(files, downloader: rig.downloader(concurrency: 1))

    #expect(rig.sandbox.read("a.bin") == a.plain)
    #expect(rig.sandbox.read("b.bin") == b.plain)
    #expect(rig.sandbox.read("c.bin") == c.plain)
    #expect(rig.requestCount(for: a.pieces[0].id) == 1, "a finished file was fetched again")
    #expect(rig.requestCount(for: c.pieces[0].id) == 1)
  }

  // MARK: INS-007 concurrency and order

  @Test(arguments: [1, 2])
  func INS_007_neverMoreThanConcurrencyFilesAreInFlight(concurrency: Int) async throws {
    let rig = try Rig(delay: .milliseconds(60))
    defer { rig.remove() }
    let files = (0..<6).map { SyntheticFile("f\($0).bin", sizes: [5_000]) }
    rig.cdn.serve(files)

    try await rig.install(
      files.map(\.file), downloader: rig.downloader(concurrency: concurrency))

    for file in files { #expect(rig.sandbox.read(file.file.path) == file.plain) }
    #expect(StubURLProtocol.maxInFlight(rig.id) == concurrency)
  }

  @Test func INS_007_pkgVersionAndGlobalgamemanagersGoFirstAndSlashPathsGoLast() async throws {
    let rig = try Rig()
    defer { rig.remove() }
    let order = [
      "Data/a.bin", "root_a.bin", "pkg_version", "Data/b.bin", "root_b.bin",
      "Data/globalgamemanagers",
    ]
    let files = order.map { SyntheticFile($0, sizes: [3_000]) }
    rig.cdn.serve(files)
    let pathOfChunk = Dictionary(uniqueKeysWithValues: files.map { ($0.pieces[0].id, $0.file.path) })

    try await rig.install(files.map(\.file), downloader: rig.downloader(concurrency: 1))

    let downloaded = rig.requestedChunkIDs.compactMap { pathOfChunk[$0] }
    #expect(downloaded.count == order.count)
    func index(_ path: String) -> Int { downloaded.firstIndex(of: path) ?? -1 }
    // Only relations that hold however -1 and +1 combine for a path that has both.
    #expect(index("pkg_version") == 0)
    #expect(index("root_a.bin") < index("root_b.bin"), "the sort is stable")
    #expect(index("Data/a.bin") < index("Data/b.bin"), "the sort is stable")
    for early in ["pkg_version", "root_a.bin", "root_b.bin", "Data/globalgamemanagers"] {
      for late in ["Data/a.bin", "Data/b.bin"] {
        #expect(index(early) < index(late), "\(early) before \(late)")
      }
    }
  }

  // MARK: INS-011 path safety

  private static let unsafePaths = [
    "../x", "a/../../x", "/etc/passwd", "a/..", "..", "", "a\\b", "a\u{0}b",
  ]

  @Test(arguments: unsafePaths)
  func INS_011_resolveRejectsUnsafePath(path: String) throws {
    let sandbox = try Sandbox()
    defer { sandbox.remove() }
    #expect(throws: SophonError.unsafePath(path)) {
      _ = try SophonPathPolicy.resolve(path, in: sandbox.game)
    }
  }

  @Test func INS_011_resolveAcceptsARelativePathInsideTheRoot() throws {
    let sandbox = try Sandbox()
    defer { sandbox.remove() }
    let url = try SophonPathPolicy.resolve("GenshinImpact_Data/Persistent/a.bin", in: sandbox.game)
    #expect(
      url.standardizedFileURL.path
        == sandbox.game.appendingPathComponent("GenshinImpact_Data/Persistent/a.bin").path)
  }

  @Test func INS_011_resolveRejectsAPathWhoseParentIsASymlinkLeavingTheRoot() throws {
    let sandbox = try Sandbox()
    defer { sandbox.remove() }
    let outside = sandbox.root.appendingPathComponent("outside", isDirectory: true)
    try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(
      at: sandbox.game.appendingPathComponent("link"), withDestinationURL: outside)

    #expect(throws: SophonError.unsafePath("link/x.bin")) {
      _ = try SophonPathPolicy.resolve("link/x.bin", in: sandbox.game)
    }
  }

  @Test(arguments: ["../escape.bin", "sub/../../escape.bin"])
  func INS_011_installWithAnUnsafePathFailsBeforeAnyRequestAndWritesNothing(bad: String) async throws {
    let rig = try Rig()
    defer { rig.remove() }
    let good = SyntheticFile("good.bin", sizes: [3_000])
    let evil = SyntheticFile(bad, sizes: [3_000])
    rig.cdn.serve(good, evil)

    await #expect(throws: SophonError.unsafePath(bad)) {
      try await rig.install([good.file, evil.file])
    }

    #expect(rig.requests.isEmpty)
    #expect(!rig.sandbox.exists("good.bin"))
    #expect(!FileManager.default.fileExists(atPath: rig.sandbox.root.appendingPathComponent("escape.bin").path))
    #expect(Sandbox.regularFiles(in: rig.sandbox.root).isEmpty)
  }

  // MARK: progress

  @Test func INS_008_progressEndsAtTotalCompressedSizeIncludingFilesAlreadyInPlace() async throws {
    let rig = try Rig()
    defer { rig.remove() }
    let inPlace = SyntheticFile("done.bin", sizes: [10_000, 10_000])
    let first = SyntheticFile("Data/one.bin", sizes: [30_000, 20_000])
    let second = SyntheticFile("Data/two.bin", sizes: [15_000])
    rig.cdn.serve(inPlace, first, second)
    try rig.sandbox.write(inPlace.file.path, inPlace.plain)
    let total = inPlace.compressedSize + first.compressedSize + second.compressedSize
    let log = ProgressLog()

    try await rig.install(
      [inPlace.file, first.file, second.file], downloader: rig.downloader(progressInterval: .zero),
      log: log)

    let events = log.downloading
    #expect(!events.isEmpty)
    #expect(events.allSatisfy { $0.total == total && $0.done >= 0 && $0.done <= total })
    #expect(zip(events, events.dropFirst()).allSatisfy { $0.done <= $1.done }, "done never decreases")
    #expect(log.all.last == .downloading(done: total, total: total))
    #expect(rig.requestedChunkIDs.count == 3, "only the two missing files were fetched")
  }

  @Test func INS_008_progressReportsCompleteWhenEverythingIsAlreadyInPlace() async throws {
    let rig = try Rig()
    defer { rig.remove() }
    let files = (0..<3).map { SyntheticFile("p\($0).bin", sizes: [4_000, 4_000]) }
    for file in files { try rig.sandbox.write(file.file.path, file.plain) }
    let total = files.reduce(Int64(0)) { $0 + $1.compressedSize }
    let log = ProgressLog()

    try await rig.install(files.map(\.file), log: log)

    #expect(log.all.last == .downloading(done: total, total: total))
    #expect(rig.requests.isEmpty)
  }

  @Test func INS_008_largeProgressIntervalLimitsCallbacksButKeepsFirstAndLast() async throws {
    let rig = try Rig()
    defer { rig.remove() }
    let files = (0..<12).map { SyntheticFile("Data/q\($0).bin", sizes: [3_000]) }
    rig.cdn.serve(files)
    let total = files.reduce(Int64(0)) { $0 + $1.compressedSize }
    let throttled = ProgressLog()
    let unthrottled = ProgressLog()

    try await rig.install(
      files.map(\.file), downloader: rig.downloader(progressInterval: .seconds(60)), log: throttled)
    try FileManager.default.removeItem(at: rig.sandbox.game.appendingPathComponent("Data"))
    try await rig.install(
      files.map(\.file), downloader: rig.downloader(progressInterval: .zero), log: unthrottled)

    let few = throttled.downloading
    #expect((2...3).contains(few.count), "got \(few.count) callbacks with a 60 s interval")
    #expect(few.first.map { $0.done < total } == true, "the first callback arrives before the end")
    #expect(throttled.all.last == .downloading(done: total, total: total))
    #expect(unthrottled.downloading.count > 3, "the zero interval run must report much more often")
    #expect(unthrottled.all.last == .downloading(done: total, total: total))
  }
}
