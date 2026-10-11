import Foundation

/// A whole ldiff file: many patches are concatenated in it.
package struct SophonLdiffFile: Sendable, Equatable {
  package let id: String
  package let size: Int64
}

extension SophonDownloader {
  /// Downloads the chunks of `files` into the chunk cache of `tempDirectory` and stops there: the game
  /// directory is not touched. A later `install` with the same `tempDirectory` finds them (PRE-002).
  /// Files that are already intact in the game directory are skipped.
  func prefetch(
    _ files: [SophonFile],
    using ref: SophonManifestRef,
    into gameDirectory: URL,
    tempDirectory: URL,
    reporter: ProgressReporter
  ) async throws {
    let (chunkBase, targets) = try Self.validate(files, using: ref, into: gameDirectory)
    let worker = FileWorker(
      session: session, chunkBase: chunkBase, chunkSuffix: ref.chunkURLSuffix,
      gameDirectory: gameDirectory, tempDirectory: tempDirectory)
    let fetcher = ResourceFetcher(session: session)
    let config = configuration
    try await runBounded(targets, limit: configuration.concurrency) { item in
      if try await Offload.run({ try Self.isIntact(item.file, at: item.destination, cancelled: $0) }) {
        reporter.add(Self.compressedSize(of: item.file))
        return
      }
      let key = SophonDownloaderLayout.fileKey(for: item.file.path)
      let directory = worker.chunkRoot.appending(path: key, directoryHint: .isDirectory)
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      let progress = reporter.chunkProgress()
      let file = item.file
      for chunk in item.file.chunks {
        let url = try SophonDownloaderLayout.resourceURL(
          base: chunkBase, name: chunk.id, suffix: ref.chunkURLSuffix)
        let cached = directory.appending(path: chunk.id)
        try await Self.retrying(config) {
          try await fetcher.fetch(
            name: chunk.id, url: url, expected: Int64(chunk.compressedSize), to: cached, reporter: progress)
          // The fetcher only checks the length. A pre-download is marked complete for good, so a chunk of
          // the right length but the wrong content must be caught here, not during the real update.
          guard !chunk.compressedMD5.isEmpty else { return }
          let intact = try await Offload.run {
            try MD5Hasher.hex(ofFileAt: cached, cancelled: $0).caseInsensitiveCompare(chunk.compressedMD5)
              == .orderedSame
          }
          if !intact {
            try? FileManager.default.removeItem(at: cached)
            progress.set(chunk.id, 0)
            throw SophonError.checksumMismatch(path: file.path)
          }
        }
      }
    }
  }

  /// Downloads ldiff files into `directory`, one request per id, resuming partial files. A file counts
  /// as complete only when it has exactly `size` bytes.
  func fetchLdiffs(
    _ ldiffs: [SophonLdiffFile],
    using ref: SophonManifestRef,
    into directory: URL,
    reporter: ProgressReporter
  ) async throws {
    let base = try SophonDownloaderLayout.httpsBase(ref.diffURLPrefix)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let fetcher = ResourceFetcher(session: session)
    let config = configuration
    let suffix = ref.diffURLSuffix
    try await runBounded(ldiffs, limit: configuration.concurrency) { ldiff in
      let url = try SophonDownloaderLayout.resourceURL(base: base, name: ldiff.id, suffix: suffix)
      let progress = ChunkProgress(reporter: reporter)  // one per ldiff: it is not thread-safe
      try await Self.retrying(config) {
        try await fetcher.fetch(
          name: ldiff.id, url: url, expected: ldiff.size, to: directory.appending(path: ldiff.id),
          reporter: progress)
      }
    }
  }
}

/// Like `runBounded`, but collects the result of `body` for every item, in the order of `items`. Stops
/// starting new items once the task is cancelled, and then throws `CancellationError`.
func mapBounded<Item: Sendable, Result: Sendable>(
  _ items: [Item], limit: Int, _ body: @escaping @Sendable (Item) async throws -> Result
) async throws -> [Result] {
  var results = [Result?](repeating: nil, count: items.count)
  try await withThrowingTaskGroup(of: (Int, Result).self) { group in
    var next = 0
    func submit() {
      guard next < items.count, !Task.isCancelled else { return }
      let index = next
      next += 1
      group.addTask { (index, try await body(items[index])) }
    }
    for _ in 0..<max(1, limit) { submit() }
    while let (index, result) = try await group.next() {
      results[index] = result
      submit()
    }
  }
  try Task.checkCancellation()
  return results.map { $0! }
}

/// Runs `body` for every item with at most `limit` in flight. Returns after all of them have stopped,
/// also when one throws or the task is cancelled.
func runBounded<Item: Sendable>(
  _ items: [Item], limit: Int, _ body: @escaping @Sendable (Item) async throws -> Void
) async throws {
  try await withThrowingTaskGroup(of: Void.self) { group in
    var iterator = items.makeIterator()
    func submit() -> Bool {
      guard let item = iterator.next() else { return false }
      group.addTask { try await body(item) }
      return true
    }
    for _ in 0..<max(1, limit) { if !submit() { break } }
    while try await group.next() != nil { _ = submit() }
  }
}
