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
  public init(session: URLSession = .shared, configuration: SophonDownloadConfiguration = .init()) {}

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
    throw SophonError.malformedResponse
  }

  /// The files that are missing, have the wrong size or the wrong MD5 (REP-003).
  public func findDamagedFiles(
    in files: [SophonFile],
    gameDirectory: URL,
    progress: @escaping @Sendable (SophonProgress) -> Void
  ) async throws -> [SophonFile] {
    throw SophonError.malformedResponse
  }
}

/// INS-011: manifest paths must stay inside the game directory.
enum SophonPathPolicy {
  /// The absolute destination of `path` under `root`, or `SophonError.unsafePath`.
  static func resolve(_ path: String, in root: URL) throws -> URL {
    throw SophonError.unsafePath(path)
  }
}
