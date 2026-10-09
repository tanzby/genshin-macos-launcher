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
  private let session: URLSession
  private let configuration: SophonDownloadConfiguration

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
    let chunkBase = try Self.chunkBase(of: ref)
    var targets: [(file: SophonFile, destination: URL)] = []
    var seen = Set<String>()
    for file in files {
      let destination = try SophonPathPolicy.resolve(file.path, in: gameDirectory)
      if file.isDirectory || !seen.insert(file.path).inserted { continue }
      for chunk in file.chunks {
        guard chunk.offset + UInt64(chunk.uncompressedSize) <= UInt64(file.size) else {
          throw SophonError.invalidManifest("chunk \(chunk.id) exceeds the size of \(file.path)")
        }
      }
      targets.append((file, destination))
    }
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
    try? FileManager.default.removeItem(at: worker.chunkRoot)
    try? FileManager.default.removeItem(at: worker.assemblyRoot)
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
        guard next < candidates.count else { return }
        let index = next
        next += 1
        group.addTask {
          let intact = try Self.isIntact(candidates[index], at: destinations[index])
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
    progress(.verifying(done: total, total: total))
    return zip(candidates, flags).filter { !$1 }.map(\.0)
  }

  // MARK: - Internals

  private static func chunkBase(of ref: SophonManifestRef) throws -> String {
    guard var prefix = ref.chunkURLPrefix else { throw SophonError.malformedResponse }
    while prefix.hasSuffix("/") { prefix.removeLast() }
    guard URL(string: prefix)?.scheme == "https" else { throw SophonError.malformedResponse }
    return prefix
  }

  private static func compressedSize(of file: SophonFile) -> Int64 {
    file.chunks.reduce(Int64(0)) { $0 + Int64($1.compressedSize) }
  }

  private static func priority(_ path: String) -> Int {
    var key = 0
    if path.contains("globalgamemanagers") || path.contains("pkg_version") { key -= 1 }
    if path.contains("/") { key += 1 }
    return key
  }

  /// Size and MD5 both match. A size-only check lets corrupted files of the right size survive.
  static func isIntact(_ file: SophonFile, at url: URL) throws -> Bool {
    guard let size = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber,
      size.int64Value == file.size
    else { return false }
    return try MD5Hasher.hex(ofFileAt: url).caseInsensitiveCompare(file.md5) == .orderedSame
  }

  private static func process(
    _ file: SophonFile, to destination: URL, worker: FileWorker, reporter: ProgressReporter,
    config: SophonDownloadConfiguration
  ) async throws {
    if try isIntact(file, at: destination) {
      reporter.add(compressedSize(of: file))
      return
    }
    var delay = config.retryDelay
    var attempt = 1
    while true {
      try Task.checkCancellation()
      do {
        try await worker.fetch(file, to: destination, reporter: reporter)
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
  private static func isRetryable(_ error: any Error) -> Bool {
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
private struct FileWorker: Sendable {
  let session: URLSession
  let chunkBase: String
  let chunkSuffix: String
  let gameDirectory: URL
  let tempDirectory: URL

  var chunkRoot: URL { tempDirectory.appending(path: "chunks", directoryHint: .isDirectory) }
  var assemblyRoot: URL { tempDirectory.appending(path: "assembling", directoryHint: .isDirectory) }

  func fetch(_ file: SophonFile, to destination: URL, reporter: ProgressReporter) async throws {
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
      // A chunk id becomes a file name; it must not be able to leave the cache directory.
      guard !chunk.id.isEmpty, !chunk.id.contains("/"), !chunk.id.contains("\\"), !chunk.id.contains(".."),
        !chunk.id.contains("\0")
      else { throw SophonError.invalidManifest("unsafe chunk id for \(file.path)") }
      let cached = chunkDirectory.appending(path: chunk.id)
      let compressed = try await downloadChunk(chunk, to: cached, reporter: reporter)
      let plain: Data
      do {
        plain = try Zstd.decompress(compressed, maxOutputSize: 64 << 20)
      } catch {
        try? fileManager.removeItem(at: cached)
        reporter.add(-Int64(chunk.compressedSize))
        throw SophonError.checksumMismatch(path: file.path)
      }
      guard plain.count == Int(chunk.uncompressedSize) else {
        try? fileManager.removeItem(at: cached)
        reporter.add(-Int64(chunk.compressedSize))
        throw SophonError.invalidManifest("chunk \(chunk.id) does not hold \(chunk.uncompressedSize) bytes")
      }
      guard MD5Hasher.hex(of: plain).caseInsensitiveCompare(chunk.md5) == .orderedSame else {
        try? fileManager.removeItem(at: cached)
        reporter.add(-Int64(chunk.compressedSize))
        throw SophonError.checksumMismatch(path: file.path)
      }
      try handle.seek(toOffset: chunk.offset)
      try handle.write(contentsOf: plain)
    }
    try handle.synchronize()
    try handle.close()

    guard try MD5Hasher.hex(ofFileAt: assembly).caseInsensitiveCompare(file.md5) == .orderedSame else {
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
  private func downloadChunk(_ chunk: SophonChunk, to cached: URL, reporter: ProgressReporter) async throws -> Data {
    let fileManager = FileManager.default
    let expected = Int64(chunk.compressedSize)
    var have = Self.size(of: cached)
    if have > expected {
      try? fileManager.removeItem(at: cached)
      have = 0
    }
    if have == expected {
      reporter.add(expected)
      return try Data(contentsOf: cached)
    }

    guard let id = chunk.id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
      let url = URL(string: "\(chunkBase)/\(id)\(chunkSuffix)")
    else { throw SophonError.malformedResponse }
    var request = URLRequest(url: url)
    request.timeoutInterval = 30
    if have > 0 { request.setValue("bytes=\(have)-", forHTTPHeaderField: "Range") }

    // Cached bytes count as done from the start, so the corrections below stay consistent.
    reporter.add(have)
    let stream = ChunkStream(session: session, request: request)
    var handle: FileHandle?
    defer { try? handle?.close() }
    do {
      for try await event in stream.events {
        switch event {
        case .response(let http):
          switch http.statusCode {
          case 206 where have > 0: break
          case 200:
            // The server ignored Range (or we asked for everything): start over.
            reporter.add(-have)
            have = 0
          case 416:
            try? fileManager.removeItem(at: cached)
            reporter.add(-have)
            throw SophonError.http(status: 416)
          default:
            throw SophonError.http(status: http.statusCode)
          }
          if have == 0 { fileManager.createFile(atPath: cached.path, contents: nil) }
          let opened = try FileHandle(forWritingTo: cached)
          try opened.seek(toOffset: UInt64(have))
          handle = opened
        case .data(let block):
          try Task.checkCancellation()
          // Written as it arrives: after a broken connection the next attempt resumes from here.
          try handle?.write(contentsOf: block)
          reporter.add(Int64(block.count))
        }
      }
    } catch let error as URLError {
      if error.code == .cancelled { throw CancellationError() }
      throw SophonError.transport(code: error.code.rawValue)
    }
    try handle?.close()
    handle = nil

    let data = try Data(contentsOf: cached)
    guard Int64(data.count) == expected else {
      // Short or long body: drop it so the next attempt starts clean.
      try? fileManager.removeItem(at: cached)
      reporter.add(-Int64(data.count))
      throw SophonError.checksumMismatch(path: chunk.id)
    }
    return data
  }

  private static func size(of url: URL) -> Int64 {
    ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber)?.int64Value ?? 0
  }
}

/// One streaming GET. A delegate hands over each network block; `bytes(for:)` would cost an async
/// hop per byte. Cancelling the consuming task cancels the request.
private final class ChunkStream: NSObject, URLSessionDataDelegate, @unchecked Sendable {
  enum Event: Sendable {
    case response(HTTPURLResponse)
    case data(Data)
  }

  let events: AsyncThrowingStream<Event, any Error>
  private let continuation: AsyncThrowingStream<Event, any Error>.Continuation

  init(session: URLSession, request: URLRequest) {
    (events, continuation) = AsyncThrowingStream.makeStream()
    super.init()
    let task = session.dataTask(with: request)
    task.delegate = self
    continuation.onTermination = { _ in task.cancel() }
    task.resume()
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
    continuation.yield(.response(http))
    completionHandler(.allow)
  }

  func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
    continuation.yield(.data(data))
  }

  func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
    continuation.finish(throwing: error)
  }
}

/// Counts compressed bytes and forwards `.downloading` at most once per interval.
private final class ProgressReporter: @unchecked Sendable {
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
    let event: SophonProgress? = lock.withLock {
      done = max(0, min(total, done + bytes))
      let now = ContinuousClock.now
      if let last, now - last < interval { return nil }
      last = now
      return .downloading(done: done, total: total)
    }
    if let event { report(event) }
  }

  /// The closing report is never throttled.
  func finish(_ event: SophonProgress) { report(event) }
}

/// Thread-safe, throttled `.verifying` reporter.
private final class VerifyCounter: @unchecked Sendable {
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
    let event: SophonProgress? = lock.withLock {
      done += bytes
      let now = ContinuousClock.now
      guard now - last >= interval else { return nil }
      last = now
      return .verifying(done: done, total: total)
    }
    if let event { report(event) }
  }
}

enum SophonDownloaderLayout {
  /// Temp-directory name of one file: a digest of the whole relative path, never the basename.
  static func fileKey(for path: String) -> String { MD5Hasher.hex(of: Data(path.utf8)) }
}

enum MD5Hasher {
  static func hex(of data: Data) -> String {
    Insecure.MD5.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }

  /// Streams the file in 1 MiB steps, checking for cancellation between steps.
  static func hex(ofFileAt url: URL) throws -> String {
    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }
    var hasher = Insecure.MD5()
    while let block = try handle.read(upToCount: 1 << 20), !block.isEmpty {
      try Task.checkCancellation()
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
