import Foundation
import Testing

@testable import Launcher

@MainActor
@Suite struct JobCoordinatorTests {
  @Test func claimingAndReleasingTheExclusiveSlot() {
    let jobs = JobCoordinator()
    #expect(jobs.phase == .idle)
    jobs.claim(.installing)
    #expect(jobs.phase == .installing)
    #expect(!jobs.allowsPreDownload)
    jobs.release(preDownload: false)
    #expect(jobs.phase == .idle)
  }

  @Test func preDownloadMayOverlapLaunchingAndRunning() {
    let jobs = JobCoordinator()
    jobs.claim(.launching)
    #expect(jobs.allowsPreDownload)
    jobs.markRunning()
    #expect(jobs.phase == .running)
    jobs.claimPreDownload()
    #expect(jobs.phase == .running)  // the exclusive phase outranks the pre-download flag
    jobs.release(preDownload: false)
    #expect(jobs.phase == .preDownloading)
    jobs.release(preDownload: true)
    #expect(jobs.phase == .idle)
  }

  @Test func markRunningOnlyAppliesToLaunching() {
    let jobs = JobCoordinator()
    jobs.claim(.installing)
    jobs.markRunning()
    #expect(jobs.phase == .installing)
  }

  @Test func cancelAndWaitReturnsAfterTheTaskStopped() async {
    let jobs = JobCoordinator()
    jobs.claim(.installing)
    let stopped = Flag()
    jobs.exclusiveTask = Task {
      while !Task.isCancelled { await Task.yield() }
      stopped.set()
      jobs.release(preDownload: false)
    }
    await jobs.cancelAndWait(exclusive: true, preDownload: false)
    #expect(stopped.value)
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
