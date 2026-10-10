import Foundation
import Observation

/// Speed and time remaining for the capsule, fed from `LauncherModel.progress`.
@MainActor @Observable
public final class ProgressMeter {
  public private(set) var bytesPerSecond: Double?
  public private(set) var remaining: TimeInterval?

  @ObservationIgnored private var estimator = TransferEstimator()
  @ObservationIgnored private let clock: @Sendable () -> TimeInterval

  public init(clock: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
    self.clock = clock
  }

  /// Call whenever the progress changes; `nil` (no job) clears the readings.
  public func update(_ progress: JobProgress?) {
    guard case .running(let done, let total)? = progress else {
      estimator = TransferEstimator()
      bytesPerSecond = nil
      remaining = nil
      return
    }
    estimator.record(done: done, at: clock())
    bytesPerSecond = estimator.bytesPerSecond
    remaining = estimator.remaining(done: done, total: total)
  }
}
