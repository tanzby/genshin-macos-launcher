import Foundation

package struct SophonDownloadConfiguration: Sendable, Equatable {
  /// Files downloaded at the same time (INS-007).
  package var concurrency: Int
  /// Attempts per file before the whole job fails (INS-010).
  package var maxAttempts: Int
  /// Wait before the second attempt; doubles each time.
  package var retryDelay: Duration
  /// Minimum gap between progress reports (ADR 0002: at most 4 per second).
  package var progressInterval: Duration

  package init(
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
package struct SophonDownloader: Sendable {
  let session: URLSession
  let configuration: SophonDownloadConfiguration

  package init(session: URLSession = .shared, configuration: SophonDownloadConfiguration = .init()) {
    self.session = session
    self.configuration = configuration
  }

  /// Brings `files` in `gameDirectory` in line with the manifest. A file is skipped only when its
  /// size and MD5 both match, so "right size, wrong MD5" files are downloaded again (REP-004).
  /// Chunks are cached in `tempDirectory` until their file is complete. Returns after every
  /// worker has stopped, also when cancelled (throws `CancellationError`).
  package func install(
    _ files: [SophonFile],
    using ref: SophonManifestRef,
    into gameDirectory: URL,
    tempDirectory: URL,
    progress: @escaping @Sendable (SophonProgress) -> Void
  ) async throws {
    // Validate everything first: a hostile manifest must fail before the first request.
    let (chunkBase, targets) = try SophonManifestValidator.validate(files, using: ref, into: gameDirectory)
    let paths = SophonPathPolicy(root: gameDirectory)
    for file in files where file.isDirectory {
      let directory = try paths.resolve(file.path)
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    let total = targets.reduce(Int64(0)) { $0 + $1.file.compressedSize }
    let reporter = ProgressReporter(.downloading, total: total, interval: configuration.progressInterval, report: progress)
    progress(.preparing)

    // INS-007: manifest files first so an interrupted install is still recognisable.
    let ordered = targets.enumerated().sorted { lhs, rhs in
      let l = Self.priority(lhs.element.file.path)
      let r = Self.priority(rhs.element.file.path)
      return l != r ? l < r : lhs.offset < rhs.offset
    }.map(\.element)

    let worker = FileWorker(
      session: session, chunkBase: chunkBase, chunkSuffix: ref.chunkURLSuffix,
      paths: paths, tempDirectory: tempDirectory)
    let config = configuration

    try await runBounded(ordered, limit: configuration.concurrency) { item in
      try await Self.process(item.file, to: item.destination, worker: worker, reporter: reporter, config: config)
    }
    reporter.finish(.downloading(done: total, total: total))
    // Only the empty cache folder goes: chunks of other files may be a pre-download waiting for its update.
    rmdir(worker.chunkRoot.path)
    try? FileManager.default.removeItem(at: worker.assemblyRoot)
  }

  /// The files that are missing, have the wrong size or the wrong MD5 (REP-003).
  package func findDamagedFiles(
    in files: [SophonFile],
    gameDirectory: URL,
    progress: @escaping @Sendable (SophonProgress) -> Void
  ) async throws -> [SophonFile] {
    let candidates = files.filter { !$0.isDirectory }
    let total = candidates.reduce(Int64(0)) { $0 + $1.size }
    let paths = SophonPathPolicy(root: gameDirectory)
    let destinations = try candidates.map { try paths.resolve($0.path) }
    let counter = ProgressReporter(.verifying, total: total, interval: configuration.progressInterval, report: progress)
    progress(.verifying(done: 0, total: total))
    let pairs = Array(zip(candidates, destinations))
    let flags = try await mapBounded(pairs, limit: SophonDownloaderLayout.verifyWorkers) { file, destination in
      let intact = try await Offload.run { try MD5Hasher.matches(destination, size: file.size, md5: file.md5, cancelled: $0) }
      counter.add(file.size)
      return intact
    }
    progress(.verifying(done: total, total: total))
    return zip(candidates, flags).filter { !$1 }.map(\.0)
  }

  // MARK: - Internals

  private static func priority(_ path: String) -> Int {
    var key = 0
    if path.contains("globalgamemanagers") || path.contains("pkg_version") { key -= 1 }
    if path.contains("/") { key += 1 }
    return key
  }

  private static func process(
    _ file: SophonFile, to destination: URL, worker: FileWorker, reporter: ProgressReporter,
    config: SophonDownloadConfiguration
  ) async throws {
    if try await Offload.run({ try MD5Hasher.matches(destination, size: file.size, md5: file.md5, cancelled: $0) }) {
      reporter.add(file.compressedSize)
      // Chunks a pre-download left for this file are not needed any more.
      try? FileManager.default.removeItem(
        at: SophonDownloaderLayout.chunkDirectory(for: file.path, in: worker.tempDirectory))
      return
    }
    let chunkProgress = reporter.chunkProgress()
    try await SophonRetry.run(config) {
      try await worker.fetch(file, to: destination, reporter: chunkProgress)
    }
  }
}
