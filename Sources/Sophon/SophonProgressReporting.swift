import Foundation

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

/// Counts bytes from many workers and forwards them at most once per interval: compressed bytes as `.downloading`,
/// checked bytes as `.verifying`.
final class ProgressReporter: @unchecked Sendable {
  enum Kind: Sendable {
    /// The first bytes are reported at once.
    case downloading
    /// The caller has just reported `.verifying(done: 0, …)` itself, so the first report waits an interval.
    case verifying
  }

  private let kind: Kind
  private let total: Int64
  private let interval: Duration
  private let report: @Sendable (SophonProgress) -> Void
  private let lock = NSLock()
  private var done: Int64 = 0
  private var last: ContinuousClock.Instant?

  init(_ kind: Kind, total: Int64, interval: Duration, report: @escaping @Sendable (SophonProgress) -> Void) {
    self.kind = kind
    self.total = total
    self.interval = interval
    self.report = report
    if kind == .verifying { last = .now }
  }

  /// `bytes` may be negative (a chunk thrown away); the count stays within 0...total.
  func add(_ bytes: Int64) {
    // The callback runs under the lock so reports reach the caller in the order they were made.
    lock.withLock {
      done = max(0, min(total, done + bytes))
      let now = ContinuousClock.now
      if let last, now - last < interval { return }
      last = now
      switch kind {
      case .downloading: report(.downloading(done: done, total: total))
      case .verifying: report(.verifying(done: done, total: total))
      }
    }
  }

  /// The closing report is never throttled.
  func finish(_ event: SophonProgress) { lock.withLock { report(event) } }

  func chunkProgress() -> ChunkProgress { ChunkProgress(reporter: self) }
}
