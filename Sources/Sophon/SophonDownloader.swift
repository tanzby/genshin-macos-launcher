import CryptoKit
import Foundation

public struct SophonDownloadConfiguration: Sendable, Equatable {
  /// Files downloaded at the same time (INS-007).
  public var concurrency: Int
  /// Attempts per file before the whole job fails (INS-010).
  public var maxAttempts: Int
  /// Wait before the second attempt; doubles each time.
  public var retryDelay: Duration
  /// Minimum gap between progress reports (ADR 0002: at most 4 per second).
  public var progressInterval: Duration

  public init(
    concurrency: Int = 8, maxAttempts: Int = 5, retryDelay: Duration = .seconds(1),
    progressInterval: Duration = .milliseconds(250)
  ) {
    self.concurrency = concurrency
    self.maxAttempts = maxAttempts
    self.retryDelay = retryDelay
    self.progressInterval = progressInterval
  }
}

/// Downloads, verifies and assembles the files of a chunk manifest. Every call is idempotent:
/// cancelling it (pause) and calling again with the same arguments continues from what is on disk.
public struct SophonDownloader: Sendable {
  let session: URLSession
  let configuration: SophonDownloadConfiguration

  public init(session: URLSession = .shared, configuration: SophonDownloadConfiguration = .init()) {
    self.session = session
    self.configuration = configuration
  }

  /// Brings `files` in `gameDirectory` in line with the manifest. A file is skipped only when its
  /// size and MD5 both match, so "right size, wrong MD5" files are downloaded again (REP-004).
  /// Chunks are cached in `tempDirectory` until their file is complete. Returns after every
  /// worker has stopped, also when cancelled (throws `CancellationError`).
  public func install(
    _ files: [SophonFile],
    using ref: SophonManifestRef,
    into gameDirectory: URL,
    tempDirectory: URL,
    progress: @escaping @Sendable (SophonProgress) -> Void
  ) async throws {
    // Validate everything first: a hostile manifest must fail before the first request.
    let (chunkBase, targets) = try Self.validate(files, using: ref, into: gameDirectory)
    for file in files where file.isDirectory {
      let directory = try SophonPathPolicy.resolve(file.path, in: gameDirectory)
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    let total = targets.reduce(Int64(0)) { $0 + Self.compressedSize(of: $1.file) }
    let reporter = ProgressReporter(total: total, interval: configuration.progressInterval, report: progress)
    progress(.preparing)

    // INS-007: manifest files first so an interrupted install is still recognisable.
    let ordered = targets.enumerated().sorted { lhs, rhs in
      let l = Self.priority(lhs.element.file.path)
      let r = Self.priority(rhs.element.file.path)
      return l != r ? l < r : lhs.offset < rhs.offset
    }.map(\.element)

    let worker = FileWorker(
      session: session, chunkBase: chunkBase, chunkSuffix: ref.chunkURLSuffix,
      gameDirectory: gameDirectory, tempDirectory: tempDirectory)
    let limit = max(1, configuration.concurrency)
    let config = configuration

    try await withThrowingTaskGroup(of: Void.self) { group in
      var iterator = ordered.makeIterator()
      func submit() -> Bool {
        guard let item = iterator.next() else { return false }
        group.addTask {
          try await Self.process(item.file, to: item.destination, worker: worker, reporter: reporter, config: config)
        }
        return true
      }
      for _ in 0..<limit { if !submit() { break } }
      while try await group.next() != nil { _ = submit() }
    }
    reporter.finish(.downloading(done: total, total: total))
    // Only the empty cache folder goes: chunks of other files may be a pre-download waiting for its update.
    rmdir(worker.chunkRoot.path)
    try? FileManager.default.removeItem(at: worker.assemblyRoot)
  }

  /// Checks every entry (paths, chunk ids and sizes, aliases) and returns the files to download.
  static func validate(_ files: [SophonFile], using ref: SophonManifestRef, into gameDirectory: URL) throws
    -> (chunkBase: String, targets: [(file: SophonFile, destination: URL)])
  {
    let chunkBase = try Self.chunkBase(of: ref)
    var targets: [(file: SophonFile, destination: URL)] = []
    var seen: [String: String] = [:]  // standardised destination -> file MD5
    for file in files {
      let destination = try SophonPathPolicy.resolve(file.path, in: gameDirectory)
      if file.isDirectory { continue }
      // Every entry is checked, also a repeated path: only the first one is downloaded.
      for chunk in file.chunks {
        // A chunk id becomes a file name; it must not be able to leave the cache directory.
        guard SophonDownloaderLayout.isSafeName(chunk.id) else {
          throw SophonError.invalidManifest("unsafe chunk id for \(file.path)")
        }
        // Chunks are read and decoded whole; real ones are about 1 MiB, so anything big is hostile.
        guard chunk.compressedSize <= SophonDownloaderLayout.maxChunkSize,
          chunk.uncompressedSize <= SophonDownloaderLayout.maxChunkSize
        else { throw SophonError.invalidManifest("chunk \(chunk.id) is too large") }
        let (end, overflow) = chunk.offset.addingReportingOverflow(UInt64(chunk.uncompressedSize))
        guard !overflow, end <= UInt64(file.size) else {
          throw SophonError.invalidManifest("chunk \(chunk.id) exceeds the size of \(file.path)")
        }
      }
      // `a/b`, `a/./b` and `a//b` are one file. Equal entries collapse; conflicting ones are refused.
      // macOS volumes are case-insensitive by default, so `A.bin` and `a.bin` are one file too.
      let key = destination.standardizedFileURL.path.lowercased()
      if let existing = seen[key] {
        guard existing.caseInsensitiveCompare(file.md5) == .orderedSame else {
          throw SophonError.invalidManifest("conflicting entries for \(file.path)")
        }
      } else {
        seen[key] = file.md5
        targets.append((file, destination))
      }
    }
    // A file cannot also be a folder: `a` together with `a/b` can never both land on disk.
    let taken = Set(seen.keys)
    for key in taken {
      var ancestor = (key as NSString).deletingLastPathComponent
      while ancestor.count > 1 {
        if taken.contains(ancestor) { throw SophonError.invalidManifest("\(ancestor) is both a file and a folder") }
        ancestor = (ancestor as NSString).deletingLastPathComponent
      }
    }
    return (chunkBase, targets)
  }

  /// The files that are missing, have the wrong size or the wrong MD5 (REP-003).
  public func findDamagedFiles(
    in files: [SophonFile],
    gameDirectory: URL,
    progress: @escaping @Sendable (SophonProgress) -> Void
  ) async throws -> [SophonFile] {
    let candidates = files.filter { !$0.isDirectory }
    let total = candidates.reduce(Int64(0)) { $0 + $1.size }
    let destinations = try candidates.map { try SophonPathPolicy.resolve($0.path, in: gameDirectory) }
    let counter = VerifyCounter(total: total, interval: configuration.progressInterval, report: progress)
    progress(.verifying(done: 0, total: total))
    // REP-003: checking is disk and CPU bound, so it uses about as many workers as there are cores.
    let limit = max(2, ProcessInfo.processInfo.activeProcessorCount - 4)

    let flags = try await withThrowingTaskGroup(of: (Int, Bool).self) { group in
      var next = 0
      var results = [Bool](repeating: false, count: candidates.count)
      func submit() {
        guard next < candidates.count, !Task.isCancelled else { return }
        let index = next
        next += 1
        group.addTask {
          let intact = try await Offload.run { try Self.isIntact(candidates[index], at: destinations[index], cancelled: $0) }
          counter.add(candidates[index].size)
          return (index, intact)
        }
      }
      for _ in 0..<limit { submit() }
      while let (index, intact) = try await group.next() {
        results[index] = intact
        submit()
      }
      return results
    }
    try Task.checkCancellation()
    progress(.verifying(done: total, total: total))
    return zip(candidates, flags).filter { !$1 }.map(\.0)
  }

  // MARK: - Internals

  static func chunkBase(of ref: SophonManifestRef) throws -> String {
    guard var prefix = ref.chunkURLPrefix else { throw SophonError.malformedResponse }
    while prefix.hasSuffix("/") { prefix.removeLast() }
    guard URL(string: prefix)?.scheme == "https" else { throw SophonError.malformedResponse }
    return prefix
  }

  static func compressedSize(of file: SophonFile) -> Int64 {
    file.chunks.reduce(Int64(0)) { $0 + Int64($1.compressedSize) }
  }

  private static func priority(_ path: String) -> Int {
    var key = 0
    if path.contains("globalgamemanagers") || path.contains("pkg_version") { key -= 1 }
    if path.contains("/") { key += 1 }
    return key
  }

  /// Size and MD5 both match. A size-only check lets corrupted files of the right size survive.
  static func isIntact(_ file: SophonFile, at url: URL, cancelled: CancelFlag) throws -> Bool {
    guard let size = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber,
      size.int64Value == file.size
    else { return false }
    return try MD5Hasher.hex(ofFileAt: url, cancelled: cancelled).caseInsensitiveCompare(file.md5) == .orderedSame
  }

  private static func process(
    _ file: SophonFile, to destination: URL, worker: FileWorker, reporter: ProgressReporter,
    config: SophonDownloadConfiguration
  ) async throws {
    if try await Offload.run({ try isIntact(file, at: destination, cancelled: $0) }) {
      reporter.add(compressedSize(of: file))
      // Chunks a pre-download left for this file are not needed any more.
      try? FileManager.default.removeItem(
        at: worker.chunkRoot.appending(path: SophonDownloaderLayout.fileKey(for: file.path), directoryHint: .isDirectory))
      return
    }
    let chunkProgress = reporter.progress(forFile: file)
    try await retrying(config) {
      try await worker.fetch(file, to: destination, reporter: chunkProgress)
    }
  }

  /// Runs `operation` up to `maxAttempts` times with exponential backoff (INS-010). Cancellation and
  /// errors that asking again cannot fix end it at once.
  static func retrying(_ config: SophonDownloadConfiguration, _ operation: () async throws -> Void) async throws {
    var delay = config.retryDelay
    var attempt = 1
    while true {
      try Task.checkCancellation()
      do {
        try await operation()
        return
      } catch {
        if error is CancellationError || (error as? URLError)?.code == .cancelled {
          throw CancellationError()
        }
        guard attempt < config.maxAttempts, isRetryable(error) else { throw error }
        attempt += 1
        try await Task.sleep(for: delay)
        delay *= 2
      }
    }
  }

  /// 4xx other than "slow down" will not change by asking again; path and manifest errors neither.
  static func isRetryable(_ error: any Error) -> Bool {
    switch error {
    case SophonError.http(let status): return status >= 500 || status == 408 || status == 416 || status == 429
    case SophonError.unsafePath, SophonError.invalidManifest, SophonError.noMatchingCategory,
      SophonError.ambiguousCategory:
      return false
    default: return true
    }
  }
}

/// Downloads the chunks of one file into the cache, decompresses them into an assembly file and
/// moves the verified result into place. Paths in the temp directory come from a digest of the
/// relative path, so equal basenames in different folders never collide.
struct FileWorker: Sendable {
  let session: URLSession
  let chunkBase: String
  let chunkSuffix: String
  let gameDirectory: URL
  let tempDirectory: URL

  var chunkRoot: URL { tempDirectory.appending(path: "chunks", directoryHint: .isDirectory) }
  var assemblyRoot: URL { tempDirectory.appending(path: "assembling", directoryHint: .isDirectory) }

  func fetch(_ file: SophonFile, to destination: URL, reporter: ChunkProgress) async throws {
    let key = SophonDownloaderLayout.fileKey(for: file.path)
    let chunkDirectory = chunkRoot.appending(path: key, directoryHint: .isDirectory)
    let assembly = assemblyRoot.appending(path: key + ".part")
    let fileManager = FileManager.default
    try fileManager.createDirectory(at: chunkDirectory, withIntermediateDirectories: true)
    try fileManager.createDirectory(at: assemblyRoot, withIntermediateDirectories: true)
    try? fileManager.removeItem(at: assembly)
    guard fileManager.createFile(atPath: assembly.path, contents: nil) else {
      throw CocoaError(.fileWriteUnknown)
    }
    let handle = try FileHandle(forWritingTo: assembly)
    defer { try? handle.close() }
    try handle.truncate(atOffset: UInt64(file.size))

    for chunk in file.chunks {
      try Task.checkCancellation()
      let cached = chunkDirectory.appending(path: chunk.id)
      let compressed = try await downloadChunk(chunk, to: cached, reporter: reporter)
      // zstd and MD5 are blocking C-speed work: keep them off the cooperative pool (ADR 0002).
      let decoded = await Offload.run { _ in
        (try? Zstd.decompress(compressed, maxOutputSize: Int(SophonDownloaderLayout.maxChunkSize))).map { ($0, MD5Hasher.hex(of: $0)) }
      }
      guard let (plain, plainMD5) = decoded else {
        try? fileManager.removeItem(at: cached)
        reporter.set(chunk.id, 0)
        throw SophonError.checksumMismatch(path: file.path)
      }
      guard plain.count == Int(chunk.uncompressedSize) else {
        try? fileManager.removeItem(at: cached)
        reporter.set(chunk.id, 0)
        throw SophonError.invalidManifest("chunk \(chunk.id) does not hold \(chunk.uncompressedSize) bytes")
      }
      guard plainMD5.caseInsensitiveCompare(chunk.md5) == .orderedSame else {
        try? fileManager.removeItem(at: cached)
        reporter.set(chunk.id, 0)
        throw SophonError.checksumMismatch(path: file.path)
      }
      try handle.seek(toOffset: chunk.offset)
      try handle.write(contentsOf: plain)
    }
    try handle.synchronize()
    try handle.close()

    let assembledMD5 = try await Offload.run { try MD5Hasher.hex(ofFileAt: assembly, cancelled: $0) }
    guard assembledMD5.caseInsensitiveCompare(file.md5) == .orderedSame else {
      try? fileManager.removeItem(at: assembly)
      throw SophonError.checksumMismatch(path: file.path)
    }
    // Re-check right before the move: a symlink may have appeared since validation.
    let safe = try SophonPathPolicy.resolve(file.path, in: gameDirectory)
    try fileManager.createDirectory(at: safe.deletingLastPathComponent(), withIntermediateDirectories: true)
    _ = try SophonPathPolicy.resolve(file.path, in: gameDirectory)
    if fileManager.fileExists(atPath: safe.path) {
      _ = try fileManager.replaceItemAt(safe, withItemAt: assembly)
    } else {
      try fileManager.moveItem(at: assembly, to: safe)
    }
    try? fileManager.removeItem(at: chunkDirectory)
  }

  /// Makes `cached` hold the complete compressed chunk, resuming with `Range` when part of it is there.
  private func downloadChunk(_ chunk: SophonChunk, to cached: URL, reporter: ChunkProgress) async throws -> Data {
    try await ResourceFetcher(session: session).fetch(
      name: chunk.id, url: try SophonDownloaderLayout.resourceURL(base: chunkBase, name: chunk.id, suffix: chunkSuffix),
      expected: Int64(chunk.compressedSize), to: cached, reporter: reporter)
    return try Data(contentsOf: cached)
  }

}

/// Downloads one resource (a chunk or an ldiff file) into `cached`, resuming with `Range` when part of
/// it is already there. On return the file holds exactly `expected` bytes.
struct ResourceFetcher: Sendable {
  let session: URLSession

  func fetch(name: String, url: URL, expected: Int64, to cached: URL, reporter: ChunkProgress) async throws {
    let fileManager = FileManager.default
    var have = Self.size(of: cached)
    if have > expected {
      try? fileManager.removeItem(at: cached)
      have = 0
    }
    if have == expected {
      reporter.set(name, expected)
      return
    }

    var request = URLRequest(url: url)
    request.timeoutInterval = 30
    if have > 0 { request.setValue("bytes=\(have)-", forHTTPHeaderField: "Range") }

    // Cached bytes count as done from the start, so the corrections below stay consistent.
    reporter.set(name, have)
    let stream = ChunkStream(session: session, request: request, expected: expected, have: have, name: name)
    defer { stream.cancel() }
    var handle: FileHandle?
    var written: Int64 = 0
    defer { try? handle?.close() }
    do {
      for try await event in stream.events {
        switch event {
        case .response(let http):
          switch http.statusCode {
          case 206 where have > 0: break
          case 200:
            // The server ignored Range (or we asked for everything): start over.
            reporter.set(name, 0)
            have = 0
          case 416:
            try? fileManager.removeItem(at: cached)
            reporter.set(name, 0)
            throw SophonError.http(status: 416)
          default:
            throw SophonError.http(status: http.statusCode)
          }
          if have == 0 { fileManager.createFile(atPath: cached.path, contents: nil) }
          written = have
          let opened = try FileHandle(forWritingTo: cached)
          try opened.seek(toOffset: UInt64(have))
          handle = opened
        case .data(let block):
          try Task.checkCancellation()
          // A body longer than the manifest says is not this chunk: stop before it fills the disk.
          written += Int64(block.count)
          guard written <= expected else {
            try? handle?.close()
            handle = nil
            try? fileManager.removeItem(at: cached)
            reporter.set(name, 0)
            throw SophonError.checksumMismatch(path: name)
          }
          // Written as it arrives: after a broken connection the next attempt resumes from here.
          try handle?.write(contentsOf: block)
          reporter.set(name, written)
        }
      }
    } catch let error as URLError {
      if error.code == .cancelled { throw CancellationError() }
      throw SophonError.transport(code: error.code.rawValue)
    } catch SophonError.checksumMismatch(let name) {
      // The body outgrew the chunk: what is on disk is not a prefix worth resuming.
      try? handle?.close()
      handle = nil
      try? fileManager.removeItem(at: cached)
      throw SophonError.checksumMismatch(path: name)
    }
    try handle?.close()
    handle = nil

    guard Self.size(of: cached) == expected else {
      // Short or long body: drop it so the next attempt starts clean.
      try? fileManager.removeItem(at: cached)
      reporter.set(name, 0)
      throw SophonError.checksumMismatch(path: name)
    }
  }

  private static func size(of url: URL) -> Int64 {
    ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber)?.int64Value ?? 0
  }
}

/// One streaming GET. A delegate hands over each network block; `bytes(for:)` would cost an async
/// hop per byte. Cancelling the consuming task cancels the request.
final class ChunkStream: NSObject, URLSessionDataDelegate, @unchecked Sendable {
  enum Event: Sendable {
    case response(HTTPURLResponse)
    case data(Data)
  }

  let events: AsyncThrowingStream<Event, any Error>
  private let continuation: AsyncThrowingStream<Event, any Error>.Continuation

  private let task: URLSessionDataTask

  private let expected: Int64
  private let have: Int64
  private var byteLimit: Int64
  private let name: String
  private var received: Int64 = 0

  init(session: URLSession, request: URLRequest, expected: Int64, have: Int64, name: String) {
    self.expected = expected
    self.have = have
    byteLimit = expected - have
    self.name = name
    (events, continuation) = AsyncThrowingStream.makeStream()
    task = session.dataTask(with: request)
    super.init()
    task.delegate = self
    continuation.onTermination = { [task] _ in task.cancel() }
    task.resume()
  }

  /// Stops the request and releases the delegate; safe to call after it has finished.
  func cancel() {
    task.cancel()
    continuation.finish()
  }

  func urlSession(
    _ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
  ) {
    guard let http = response as? HTTPURLResponse else {
      continuation.finish(throwing: SophonError.malformedResponse)
      completionHandler(.cancel)
      return
    }
    // A 200 carries the whole chunk even when we asked to resume.
    if http.statusCode == 200 { byteLimit = expected }
    continuation.yield(.response(http))
    completionHandler(.allow)
  }

  func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
    // Delegate callbacks are serial. Stop a body that outgrows the chunk before it piles up in the stream.
    received += Int64(data.count)
    if received > byteLimit && byteLimit >= 0 {
      continuation.finish(throwing: SophonError.checksumMismatch(path: name))
      dataTask.cancel()
      return
    }
    continuation.yield(.data(data))
  }

  func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
    continuation.finish(throwing: error)
  }
}

/// What each chunk of one file has contributed to the overall count. It outlives a failed attempt:
/// the retry sets the same chunk's value again, so cached bytes are never counted twice and the
/// total only goes down when data is really thrown away.
final class ChunkProgress: @unchecked Sendable {
  private let reporter: ProgressReporter
  private var counted: [String: Int64] = [:]

  init(reporter: ProgressReporter) { self.reporter = reporter }

  func set(_ chunkID: String, _ bytes: Int64) {
    let old = counted[chunkID] ?? 0
    counted[chunkID] = bytes
    reporter.add(bytes - old)
  }
}

/// Counts compressed bytes and forwards `.downloading` at most once per interval.
final class ProgressReporter: @unchecked Sendable {
  private let total: Int64
  private let interval: Duration
  private let report: @Sendable (SophonProgress) -> Void
  private let lock = NSLock()
  private var done: Int64 = 0
  private var last: ContinuousClock.Instant?

  init(total: Int64, interval: Duration, report: @escaping @Sendable (SophonProgress) -> Void) {
    self.total = total
    self.interval = interval
    self.report = report
  }

  func add(_ bytes: Int64) {
    // The callback runs under the lock so reports reach the caller in the order they were made.
    lock.withLock {
      done = max(0, min(total, done + bytes))
      let now = ContinuousClock.now
      if let last, now - last < interval { return }
      last = now
      report(.downloading(done: done, total: total))
    }
  }

  /// The closing report is never throttled.
  func finish(_ event: SophonProgress) { lock.withLock { report(event) } }

  func progress(forFile file: SophonFile) -> ChunkProgress { ChunkProgress(reporter: self) }
}

/// Thread-safe, throttled `.verifying` reporter.
final class VerifyCounter: @unchecked Sendable {
  private let total: Int64
  private let interval: Duration
  private let report: @Sendable (SophonProgress) -> Void
  private let lock = NSLock()
  private var done: Int64 = 0
  private var last = ContinuousClock.now

  init(total: Int64, interval: Duration, report: @escaping @Sendable (SophonProgress) -> Void) {
    self.total = total
    self.interval = interval
    self.report = report
  }

  func add(_ bytes: Int64) {
    lock.withLock {
      done += bytes
      let now = ContinuousClock.now
      guard now - last >= interval else { return }
      last = now
      report(.verifying(done: done, total: total))
    }
  }
}

enum SophonDownloaderLayout {
  /// Temp-directory name of one file: a digest of the whole relative path, never the basename.
  static func fileKey(for path: String) -> String { MD5Hasher.hex(of: Data(path.utf8)) }

  static let maxChunkSize: UInt32 = 64 << 20

  /// `<base>/<name><suffix>` with the name percent-encoded; `base` has no trailing slash.
  static func resourceURL(base: String, name: String, suffix: String) throws -> URL {
    guard let id = name.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
      let url = URL(string: "\(base)/\(id)\(suffix)")
    else { throw SophonError.malformedResponse }
    return url
  }

  static func isSafeName(_ name: String) -> Bool {
    !name.isEmpty && !name.contains("/") && !name.contains("\\") && !name.contains("..")
      && !name.contains("\0")
  }
}

/// Set when the awaiting task is cancelled, so blocking work on `Offload.queue` can stop early.
final class CancelFlag: @unchecked Sendable {
  private let lock = NSLock()
  private var value = false
  var isSet: Bool { lock.withLock { value } }
  func set() { lock.withLock { value = true } }
}

/// Runs blocking work on a dedicated concurrent queue and resumes when it has finished. Callers are
/// already bounded by their task groups, so the queue never holds more than that many items.
enum Offload {
  static let queue = DispatchQueue(label: "yaagl.sophon.blocking", qos: .utility, attributes: .concurrent)

  static func run<T: Sendable>(_ work: @escaping @Sendable (CancelFlag) throws -> T) async throws -> T {
    try Task.checkCancellation()
    let flag = CancelFlag()
    let result = try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuation in
        queue.async { continuation.resume(with: Result { try work(flag) }) }
      }
    } onCancel: {
      flag.set()
    }
    // Work that finished without looking at the flag (a missing file) must not hide a pause.
    try Task.checkCancellation()
    return result
  }

  static func run<T: Sendable>(_ work: @escaping @Sendable (CancelFlag) -> T) async -> T {
    await withCheckedContinuation { continuation in
      queue.async { continuation.resume(returning: work(CancelFlag())) }
    }
  }
}

enum MD5Hasher {
  static func hex(of data: Data) -> String {
    Insecure.MD5.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }

  /// Streams the file in 1 MiB steps, checking for cancellation between steps.
  static func hex(ofFileAt url: URL, cancelled: CancelFlag) throws -> String {
    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }
    var hasher = Insecure.MD5()
    while let block = try handle.read(upToCount: 1 << 20), !block.isEmpty {
      if cancelled.isSet { throw CancellationError() }
      hasher.update(data: block)
    }
    return hasher.finalize().map { String(format: "%02x", $0) }.joined()
  }
}

/// INS-011: manifest paths must stay inside the game directory.
enum SophonPathPolicy {
  /// The absolute destination of `path` under `root`, or `SophonError.unsafePath`.
  static func resolve(_ path: String, in root: URL) throws -> URL {
    // Same rule as the TS launcher (no `..`, no leading `/`) plus the ways to say the same thing.
    guard !path.isEmpty, !path.hasPrefix("/"), !path.contains(".."), !path.contains("\\"),
      !path.contains("\0")
    else { throw SophonError.unsafePath(path) }
    let destination = root.appending(path: path)
    let realRoot = root.resolvingSymlinksInPath().standardizedFileURL.path
    let realParent = destination.deletingLastPathComponent().resolvingSymlinksInPath().standardizedFileURL.path
    guard realParent == realRoot || realParent.hasPrefix(realRoot + "/") else {
      throw SophonError.unsafePath(path)
    }
    return destination
  }
}
