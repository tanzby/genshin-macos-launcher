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

  func chunkProgress() -> ChunkProgress { ChunkProgress(reporter: self) }
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
