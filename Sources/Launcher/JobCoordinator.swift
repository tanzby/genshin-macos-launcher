import Foundation
import Observation

/// The two job slots of ADR 0002: the exclusive one (Wine preparation, install, update, repair, launch) and
/// the pre-download one, which only writes the temporary directory and may overlap with launching and running.
/// A job's whole lifecycle lives here: `startExclusive`/`startPreDownload` claim the slot, hold the Task and free
/// the slot when the Task body ends, whether it returns, throws away its work or is cancelled. Callers never release.
/// What runs in the slots stays with `LauncherModel`.
@MainActor @Observable
final class JobCoordinator {
  private(set) var exclusive: LauncherPhase = .idle
  private(set) var isPreDownloading = false
  @ObservationIgnored private var exclusiveTask: Task<Void, Never>?
  @ObservationIgnored private var preDownloadTask: Task<Void, Never>?

  var phase: LauncherPhase {
    if exclusive != .idle { return exclusive }
    return isPreDownloading ? .preDownloading : .idle
  }

  /// A pre-download may start when nothing exclusive but launching or running is going on.
  var allowsPreDownload: Bool {
    exclusive == .idle || exclusive == .launching || exclusive == .running
  }

  /// Whether the chosen slot currently holds a Task.
  func isHolding(exclusive isExclusive: Bool) -> Bool {
    (isExclusive ? exclusiveTask : preDownloadTask) != nil
  }

  /// Claims the exclusive slot for `phase` and runs `body` in it. The claim happens before any await, so nothing
  /// else can slip in; the slot is freed when `body` ends.
  func startExclusive(_ phase: LauncherPhase, body: @escaping @MainActor () async -> Void) {
    exclusive = phase
    exclusiveTask = Task {
      defer { self.releaseExclusive() }
      await body()
    }
  }

  /// Claims the pre-download slot and runs `body` in it; the slot is freed when `body` ends.
  func startPreDownload(body: @escaping @MainActor () async -> Void) {
    isPreDownloading = true
    preDownloadTask = Task {
      defer { self.releasePreDownload() }
      await body()
    }
  }

  /// `launching` becomes `running` once the game reports it started.
  func markRunning() {
    if exclusive == .launching { exclusive = .running }
  }

  /// Cancels the chosen slots' Tasks and returns once all of them have stopped (and so released their slots).
  func cancelAndWait(exclusive cancelExclusive: Bool, preDownload: Bool) async {
    let tasks = [cancelExclusive ? exclusiveTask : nil, preDownload ? preDownloadTask : nil].compactMap { $0 }
    for task in tasks { task.cancel() }
    for task in tasks { await task.value }
  }

  /// Returns once the exclusive Task, if there is one, has ended.
  func waitForExclusive() async {
    await exclusiveTask?.value
  }

  /// Test hook: returns once no job or launch Task is outstanding.
  func waitUntilIdle() async {
    while let task = exclusiveTask ?? preDownloadTask {
      await task.value
    }
  }

  private func releaseExclusive() {
    exclusive = .idle
    exclusiveTask = nil
  }

  private func releasePreDownload() {
    isPreDownloading = false
    preDownloadTask = nil
  }
}
