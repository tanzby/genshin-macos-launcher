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
    for file in files where file.isDirectory {
      let directory = try SophonPathPolicy.resolve(file.path, in: gameDirectory)
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    let total = targets.reduce(Int64(0)) { $0 + SophonManifestValidator.compressedSize(of: $1.file) }
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
    let destinations = try candidates.map { try SophonPathPolicy.resolve($0.path, in: gameDirectory) }
    let counter = VerifyCounter(total: total, interval: configuration.progressInterval, report: progress)
    progress(.verifying(done: 0, total: total))
    let pairs = Array(zip(candidates, destinations))
    let flags = try await mapBounded(pairs, limit: SophonDownloaderLayout.verifyWorkers) { file, destination in
      let intact = try await Offload.run { try Self.isIntact(file, at: destination, cancelled: $0) }
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

  /// Size and MD5 both match. A size-only check lets corrupted files of the right size survive.
  static func isIntact(_ file: SophonFile, at url: URL, cancelled: CancelFlag) throws -> Bool {
    try SophonUpdater.matches(url, size: file.size, md5: file.md5, cancelled: cancelled)
  }

  private static func process(
    _ file: SophonFile, to destination: URL, worker: FileWorker, reporter: ProgressReporter,
    config: SophonDownloadConfiguration
  ) async throws {
    if try await Offload.run({ try isIntact(file, at: destination, cancelled: $0) }) {
      reporter.add(SophonManifestValidator.compressedSize(of: file))
      // Chunks a pre-download left for this file are not needed any more.
      try? FileManager.default.removeItem(
        at: worker.chunkRoot.appending(path: SophonDownloaderLayout.fileKey(for: file.path), directoryHint: .isDirectory))
      return
    }
    let chunkProgress = reporter.chunkProgress()
    try await SophonRetry.run(config) {
      try await worker.fetch(file, to: destination, reporter: chunkProgress)
    }
  }
}
