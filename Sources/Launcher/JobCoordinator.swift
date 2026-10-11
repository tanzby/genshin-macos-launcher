import Foundation
import Observation

/// The two job slots of ADR 0002: the exclusive one (Wine preparation, install, update, repair, launch) and
/// the pre-download one, which only writes the temporary directory and may overlap with launching and running.
/// It owns the slots and their Tasks; what runs in them stays with `LauncherModel`.
@MainActor @Observable
final class JobCoordinator {
  private(set) var exclusive: LauncherPhase = .idle
  private(set) var isPreDownloading = false
  @ObservationIgnored var exclusiveTask: Task<Void, Never>?
  @ObservationIgnored var preDownloadTask: Task<Void, Never>?

  var phase: LauncherPhase {
    if exclusive != .idle { return exclusive }
    return isPreDownloading ? .preDownloading : .idle
  }

  /// A pre-download may start when nothing exclusive but launching or running is going on.
  var allowsPreDownload: Bool {
    exclusive == .idle || exclusive == .launching || exclusive == .running
  }

  /// Claim before any await so nothing else can slip in.
  func claim(_ phase: LauncherPhase) { exclusive = phase }
  func claimPreDownload() { isPreDownloading = true }

  /// `launching` becomes `running` once the game reports it started.
  func markRunning() {
    if exclusive == .launching { exclusive = .running }
  }

  /// Frees the pre-download slot, or the exclusive one that install/update/repair, Wine and launch share.
  func release(preDownload: Bool) {
    if preDownload {
      isPreDownloading = false
      preDownloadTask = nil
    } else {
      exclusive = .idle
      exclusiveTask = nil
    }
  }

  /// Cancels the chosen slots' Tasks and returns once all of them have stopped.
  func cancelAndWait(exclusive cancelExclusive: Bool, preDownload: Bool) async {
    let tasks = [cancelExclusive ? exclusiveTask : nil, preDownload ? preDownloadTask : nil].compactMap { $0 }
    for task in tasks { task.cancel() }
    for task in tasks { await task.value }
  }

  /// Test hook: returns once no job or launch Task is outstanding.
  func waitUntilIdle() async {
    while let task = exclusiveTask ?? preDownloadTask {
      await task.value
    }
  }
}
