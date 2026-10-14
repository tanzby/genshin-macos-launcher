import Foundation
import Testing

@testable import Launcher

@MainActor
@Suite struct JobCoordinatorTests {
  /// A job body that runs until cancelled.
  private func untilCancelled() -> @MainActor () async -> Void {
    { while !Task.isCancelled { await Task.yield() } }
  }

  @Test func startingClaimsBeforeAnyAwaitAndTheSlotFreesWhenTheBodyEnds() async {
    let jobs = JobCoordinator()
    #expect(jobs.phase == .idle)
    jobs.startExclusive(.installing) {}
    #expect(jobs.phase == .installing)  // claimed synchronously, the body has not run yet
    #expect(!jobs.allowsPreDownload)
    #expect(jobs.isHolding(exclusive: true))
    await jobs.waitUntilIdle()
    #expect(jobs.phase == .idle)
    #expect(!jobs.isHolding(exclusive: true))
  }

  @Test func preDownloadMayOverlapLaunchingAndRunning() async {
    let jobs = JobCoordinator()
    jobs.startExclusive(.launching, body: untilCancelled())
    #expect(jobs.allowsPreDownload)
    jobs.markRunning()
    #expect(jobs.phase == .running)
    #expect(jobs.allowsPreDownload)
    jobs.startPreDownload(body: untilCancelled())
    #expect(jobs.phase == .running)  // the exclusive phase outranks the pre-download flag
    await jobs.cancelAndWait(exclusive: true, preDownload: false)
    #expect(jobs.phase == .preDownloading)
    await jobs.cancelAndWait(exclusive: false, preDownload: true)
    #expect(jobs.phase == .idle)
  }

  @Test func installUpdateRepairAndWineBlockPreDownload() async {
    for phase in [LauncherPhase.installing, .updating, .repairing, .preparingWine] {
      let jobs = JobCoordinator()
      jobs.startExclusive(phase, body: untilCancelled())
      #expect(!jobs.allowsPreDownload)
      await jobs.cancelAndWait(exclusive: true, preDownload: false)
    }
  }

  @Test func markRunningOnlyAppliesToLaunching() async {
    let jobs = JobCoordinator()
    jobs.startExclusive(.installing, body: untilCancelled())
    jobs.markRunning()
    #expect(jobs.phase == .installing)
    await jobs.cancelAndWait(exclusive: true, preDownload: false)
  }

  @Test func cancelAndWaitReturnsAfterTheTaskStoppedAndFreedTheSlot() async {
    let jobs = JobCoordinator()
    let stopped = Flag()
    jobs.startExclusive(.installing) {
      while !Task.isCancelled { await Task.yield() }
      stopped.set()
    }
    await jobs.cancelAndWait(exclusive: true, preDownload: false)
    #expect(stopped.value)
    #expect(jobs.phase == .idle)
  }

  @Test func cancelAndWaitCanStopBothSlots() async {
    let jobs = JobCoordinator()
    jobs.startExclusive(.launching, body: untilCancelled())
    jobs.startPreDownload(body: untilCancelled())
    await jobs.cancelAndWait(exclusive: true, preDownload: true)
    #expect(jobs.phase == .idle)
    #expect(!jobs.isHolding(exclusive: true))
    #expect(!jobs.isHolding(exclusive: false))
  }

  @Test func theSlotIsFreedWhenTheBodyEndsEarlyAfterAnAwait() async {
    let jobs = JobCoordinator()
    jobs.startPreDownload {
      await Task.yield()
      return  // e.g. a failed preflight
    }
    #expect(jobs.isPreDownloading)
    await jobs.waitUntilIdle()
    #expect(jobs.phase == .idle)
  }

  @Test func theSlotIsFreedWhenCancelledBeforeTheBodyStarted() async {
    let jobs = JobCoordinator()
    jobs.startExclusive(.updating, body: untilCancelled())
    await jobs.cancelAndWait(exclusive: true, preDownload: false)  // cancelled on the very same turn
    #expect(jobs.phase == .idle)
  }

  @Test func waitForExclusiveReturnsAfterTheBodyAndWithoutOneAtOnce() async {
    let jobs = JobCoordinator()
    await jobs.waitForExclusive()
    let done = Flag()
    jobs.startExclusive(.preparingWine) {
      await Task.yield()
      done.set()
    }
    await jobs.waitForExclusive()
    #expect(done.value)
    #expect(jobs.phase == .idle)
  }

  @Test func waitUntilIdleCoversBothSlots() async {
    let jobs = JobCoordinator()
    let done = Flag()
    jobs.startExclusive(.launching) {}
    jobs.startPreDownload {
      await Task.yield()
      done.set()
    }
    await jobs.waitUntilIdle()
    #expect(done.value)
    #expect(jobs.phase == .idle)
  }
}

@Suite struct DiskSpaceCheckTests {
  private let dir = URL(filePath: "/tmp/x")

  @Test func needsTheRequiredBytesPlusMargin() throws {
    let check = DiskSpaceCheck(margin: 100, availableSpace: { _ in 1_000 })
    try check.verify(required: 900, in: dir)
    #expect(throws: LauncherError.insufficientDiskSpace(required: 1_001, available: 1_000)) {
      try check.verify(required: 901, in: dir)
    }
  }

  @Test func zeroRequiredAndUnknownCapacityPass() throws {
    try DiskSpaceCheck(margin: 100, availableSpace: { _ in 0 }).verify(required: 0, in: dir)
    try DiskSpaceCheck(margin: 100, availableSpace: { _ in nil }).verify(required: 5, in: dir)
  }
}

private final class Flag: @unchecked Sendable {
  private let lock = NSLock()
  private var flag = false
  var value: Bool { lock.withLock { flag } }
  func set() { lock.withLock { flag = true } }
}
