import Foundation
import Synchronization
import Testing

@testable import Launcher

// Conventions assumed by these tests (see README.md):
// - `start(_:)`, `resume()` and `launch()` validate, then return once the Task is running (phase already
//   changed). They do not wait for the job or the game to finish. `waitUntilIdle()` does.
// - A2/busy: the phase check comes before status-based checks, so a busy launcher answers `.busy`.

// MARK: - Fixtures

private enum Status {
  static let notInstalled = GameStatus(localVersion: nil, remoteVersion: "5.0.0")
  static let installed = GameStatus(localVersion: "5.0.0", remoteVersion: "5.0.0")
  static let needsUpdate = GameStatus(localVersion: "4.9.0", remoteVersion: "5.0.0", canUpdate: true)
  static let preDownloadable = GameStatus(localVersion: "5.0.0", remoteVersion: "5.0.0", canPreDownload: true)
  static let updatableAndPreDownloadable = GameStatus(
    localVersion: "4.9.0", remoteVersion: "5.0.0", canUpdate: true, canPreDownload: true)
}

private struct JobScenario: Sendable, CustomTestStringConvertible {
  var job: GameJob
  var status: GameStatus
  var testDescription: String { job.rawValue }

  static let all = [
    JobScenario(job: .install, status: Status.notInstalled),
    JobScenario(job: .update, status: Status.needsUpdate),
    JobScenario(job: .repair, status: Status.installed),
    JobScenario(job: .preDownload, status: Status.preDownloadable),
  ]
}

private let allJobs: [GameJob] = [.install, .update, .repair, .preDownload]

@MainActor
private final class Harness {
  let fake: FakeGameClient
  let model: LauncherModel
  let sleeper = ManualSleeper()
  let log: EventLog
  let directory: URL?

  var jobFileURL: URL { directory!.appending(path: ".yaagl-tmp").appending(path: "job.json") }
  var jobFileExists: Bool { FileManager.default.fileExists(atPath: jobFileURL.path) }
  var jobFile: PendingJob? {
    guard let data = try? Data(contentsOf: jobFileURL) else { return nil }
    return try? JSONDecoder().decode(PendingJob.self, from: data)
  }

  /// `status == nil` makes the fake's `status()` throw. The model is refreshed once before returning.
  init(
    status: GameStatus?,
    hasGameDirectory: Bool = true,
    launchTimeout: Duration = LauncherModel.defaultLaunchTimeout,
    chunkTempMargin: Int64 = 0,
    availableDiskSpace: @escaping @Sendable (URL) -> Int64? = { _ in nil },
    preexistingJobFile: String? = nil
  ) async {
    let fake = FakeGameClient(status: status ?? GameStatus())
    if status == nil { fake.setStatusFailure(GameClientError.network) }
    var directory: URL?
    if hasGameDirectory {
      let url = FileManager.default.temporaryDirectory.appending(path: "LauncherJobTests-\(UUID().uuidString)")
      try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
      directory = url
    }
    self.fake = fake
    self.directory = directory
    let sleeper = self.sleeper
    model = LauncherModel(
      client: fake,
      gameDirectory: directory,
      launchTimeout: launchTimeout,
      chunkTempMargin: chunkTempMargin,
      availableDiskSpace: availableDiskSpace,
      sleep: { try await sleeper.sleep($0) }
    )
    log = EventLog(model.events)
    if let preexistingJobFile { writeJobFile(preexistingJobFile) }
    await model.refresh()
  }

  deinit {
    if let directory { try? FileManager.default.removeItem(at: directory) }
  }

  func writeJobFile(_ text: String) {
    try! FileManager.default.createDirectory(
      at: jobFileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    try! Data(text.utf8).write(to: jobFileURL)
  }

  /// Starts `job` and returns the index of the fake run it created.
  @discardableResult
  func begin(_ job: GameJob) async throws -> Int {
    try await model.start(job)
    return try await fake.nextRun()
  }

  /// Starts a launch and waits until the fake is suspended inside `launch`.
  func beginLaunch() async throws {
    try await model.launch()
    try await fake.nextLaunch()
  }

  /// Suspends (no polling) until `predicate` holds, via `Observations`; false on failsafe expiry.
  func waitUntil(_ predicate: @escaping @MainActor @Sendable () -> Bool) async -> Bool {
    let outcome = AsyncQueue<Bool>()
    let watcher = Task { @MainActor in outcome.push(await observeUntilTrue(predicate)) }
    let timer = Task {
      try? await Task.sleep(for: AsyncQueue<Int>.failsafe)
      outcome.push(false)
    }
    let result = await outcome.pop() ?? false
    watcher.cancel()
    timer.cancel()
    return result
  }

  func waitForPhase(_ phase: LauncherPhase) async -> Bool {
    let model = model
    return await waitUntil { model.phase == phase }
  }

  /// Proves no stray event was emitted earlier: drives a fresh failing install and expects its
  /// `.failed` to be the very next event.
  func expectNextEventIsSentinelFailure() async throws {
    let index = try await begin(.install)
    fake.finish(run: index, throwing: GameClientError.network)
    #expect(try await log.next() == .failed(.install, .client(.network)))
  }
}

@MainActor
private func observeUntilTrue(_ predicate: @escaping @MainActor @Sendable () -> Bool) async -> Bool {
  let values = Observations { predicate() }
  for await value in values where value { return true }
  return false
}

private func jobJSON(kind: String, target: String? = nil, extra: String = "") -> String {
  let targetField = target.map { #","targetVersion":"\#($0)""# } ?? ""
  return #"{"schemaVersion":1,"kind":"\#(kind)"\#(targetField)\#(extra)}"#
}

// MARK: - APP-010

@MainActor @Suite struct APP_010_OfflineTests {
  @Test func APP_010_launchRejectedWithOfflineWhenRemoteVersionIsNil() async throws {
    let h = await Harness(status: GameStatus(localVersion: "5.0.0", remoteVersion: nil))
    #expect(h.model.isOnline == false)
    await #expect(throws: LauncherError.offline) { try await h.model.launch() }
    #expect(h.model.phase == .idle)
    #expect(h.fake.events.isEmpty)
  }

  @Test func APP_010_launchRejectedWithOfflineWhenRemoteVersionIsEmpty() async throws {
    let h = await Harness(status: GameStatus(localVersion: "5.0.0", remoteVersion: ""))
    #expect(h.model.isOnline == false)
    await #expect(throws: LauncherError.offline) { try await h.model.launch() }
    #expect(h.model.phase == .idle)
  }

  @Test func APP_010_isOnlineWhenRemoteVersionIsPresent() async {
    let h = await Harness(status: Status.installed)
    #expect(h.model.isOnline == true)
  }

  @Test func APP_010_refreshFailureKeepsPreviousStatusInsteadOfFlippingToInstall() async {
    let h = await Harness(status: Status.installed)
    #expect(h.model.primaryAction == .launch)
    h.fake.setStatusFailure(GameClientError.network)
    await h.model.refresh()
    #expect(h.model.status == Status.installed)
    #expect(h.model.primaryAction == .launch)
  }

  @Test func APP_010_refreshFailureOnFirstLoadLeavesStatusNil() async {
    let h = await Harness(status: nil)
    #expect(h.model.status == nil)
    #expect(h.model.isOnline == false)
  }

  @Test func APP_010_refreshAfterFailureRecoversToNewStatus() async {
    let h = await Harness(status: Status.installed)
    h.fake.setStatusFailure(GameClientError.network)
    await h.model.refresh()
    h.fake.setStatus(Status.needsUpdate)
    await h.model.refresh()
    #expect(h.model.status == Status.needsUpdate)
    #expect(h.model.primaryAction == .update)
  }
}

// MARK: - APP-013

@MainActor @Suite struct APP_013_ErrorTests {
  @Test func APP_013_errorReturnsToIdleAndRetryWorks() async throws {
    let h = await Harness(status: Status.notInstalled)
    let first = try await h.begin(.install)
    #expect(h.model.phase == .installing)
    h.fake.finish(run: first, throwing: GameClientError.network)
    await h.model.waitUntilIdle()

    #expect(h.model.phase == .idle)
    #expect(h.model.lastError == .client(.network))
    #expect(try await h.log.next() == .failed(.install, .client(.network)))

    let second = try await h.begin(.install)
    #expect(second == 1)
    #expect(h.fake.runs == [.install, .install])
    #expect(h.model.phase == .installing)
    h.fake.finish(run: second)
    await h.model.waitUntilIdle()
  }

  @Test func APP_013_nonClientErrorIsReportedAsUnexpected() async throws {
    struct Boom: Error {}
    let h = await Harness(status: Status.notInstalled)
    let index = try await h.begin(.install)
    h.fake.finish(run: index, throwing: Boom())
    await h.model.waitUntilIdle()

    #expect(h.model.phase == .idle)
    guard case .unexpected = h.model.lastError else {
      Issue.record("expected .unexpected, got \(String(describing: h.model.lastError))")
      return
    }
    guard case .failed(.install, .unexpected) = try await h.log.next() else {
      Issue.record("expected .failed(.install, .unexpected)")
      return
    }
  }

  @Test func APP_013_clientCancelledErrorCountsAsPauseNotError() async throws {
    let h = await Harness(status: Status.notInstalled)
    let index = try await h.begin(.install)
    h.fake.finish(run: index, throwing: GameClientError.cancelled)
    await h.model.waitUntilIdle()

    #expect(h.model.phase == .idle)
    #expect(h.model.lastError == nil)
    #expect(h.jobFile == PendingJob(kind: .install, targetVersion: "5.0.0"))
    try await h.expectNextEventIsSentinelFailure()
  }

  @Test func APP_013_downloadJobResumesAfterError() async throws {
    let h = await Harness(status: Status.notInstalled)
    let first = try await h.begin(.install)
    h.fake.finish(run: first, throwing: GameClientError.network)
    await h.model.waitUntilIdle()
    #expect(h.jobFile?.kind == .install)

    await h.model.refresh()
    #expect(h.model.pendingJob == PendingJob(kind: .install, targetVersion: "5.0.0"))
    try await h.model.resume()
    #expect(try await h.fake.nextRun() == 1)
    #expect(h.fake.runs == [.install, .install])
  }

  @Test func APP_013_launchOutcomeErrorsDoNotLeaveJobState() async throws {
    // A failed job must not leave the launcher in a state that blocks the next launch.
    let h = await Harness(status: Status.installed)
    try await h.beginLaunch()
    h.fake.finishLaunch(.failedToLaunch)
    await h.model.waitUntilIdle()
    #expect(h.model.phase == .idle)
    try await h.beginLaunch()
    #expect(h.model.phase == .launching)
    h.fake.finishLaunch(.exited)
    await h.model.waitUntilIdle()
  }
}

// MARK: - APP-015

@MainActor @Suite struct APP_015_ExclusionTests {
  @Test(arguments: JobScenario.all)
  fileprivate func APP_015_everyOtherJobIsBusyWhileOneRuns(_ scenario: JobScenario) async throws {
    let h = await Harness(status: scenario.status)
    try await h.begin(scenario.job)
    // install/update/repair preempt a running pre-download instead (see the preemption test below)
    for other in allJobs where scenario.job != .preDownload || other == .preDownload {
      await #expect(throws: LauncherError.busy, "\(other) while \(scenario.job) runs") {
        try await h.model.start(other)
      }
    }
    #expect(h.fake.runs == [scenario.job])
  }

  @Test func APP_015_launchAllowsPreDownloadWhileLaunching() async throws {
    let h = await Harness(status: Status.preDownloadable)
    try await h.beginLaunch()
    #expect(h.model.phase == .launching)

    try await h.begin(.preDownload)
    #expect(h.model.isPreDownloading)
    #expect(h.model.phase == .launching)
    #expect(h.fake.runs == [.preDownload])
  }

  @Test func APP_015_preDownloadAllowedWhileGameIsRunning() async throws {
    let h = await Harness(status: Status.preDownloadable)
    try await h.beginLaunch()
    h.fake.fireStarted()
    #expect(await h.waitForPhase(.running))

    let run = try await h.begin(.preDownload)
    #expect(h.model.isPreDownloading)
    #expect(h.model.phase == .running)

    h.fake.finish(run: run)
    #expect(await h.waitUntil { !h.model.isPreDownloading })
    #expect(h.model.phase == .running)
    h.fake.finishLaunch(.exited)
    await h.model.waitUntilIdle()
  }

  @Test(arguments: [GameJob.install, .update, .repair])
  func APP_015_installUpdateRepairRejectedWhileLaunching(_ job: GameJob) async throws {
    let h = await Harness(status: Status.preDownloadable)
    try await h.beginLaunch()
    await #expect(throws: LauncherError.busy) { try await h.model.start(job) }
    #expect(h.fake.runs.isEmpty)
    #expect(h.model.phase == .launching)
  }

  @Test(arguments: [GameJob.install, .update, .repair])
  func APP_015_installUpdateRepairRejectedWhileGameIsRunning(_ job: GameJob) async throws {
    let h = await Harness(status: Status.preDownloadable)
    try await h.beginLaunch()
    h.fake.fireStarted()
    #expect(await h.waitForPhase(.running))
    await #expect(throws: LauncherError.busy) { try await h.model.start(job) }
    #expect(h.fake.runs.isEmpty)
    #expect(h.model.phase == .running)
  }

  @Test func APP_015_secondLaunchWhileLaunchingIsBusy() async throws {
    let h = await Harness(status: Status.installed)
    try await h.beginLaunch()
    await #expect(throws: LauncherError.busy) { try await h.model.launch() }
    #expect(h.fake.launchOptions.count == 1)
  }

  @Test func APP_015_launchAllowedWhilePreDownloading() async throws {
    let h = await Harness(status: Status.preDownloadable)
    try await h.begin(.preDownload)
    try await h.beginLaunch()
    #expect(h.model.phase == .launching)
    #expect(h.model.isPreDownloading)
  }

  @Test(arguments: [
    JobScenario(job: .update, status: Status.updatableAndPreDownloadable),
    JobScenario(job: .repair, status: Status.preDownloadable),
  ])
  fileprivate func APP_015_startingExclusiveJobCancelsPreDownloadAndWaitsForTermination(
    _ scenario: JobScenario
  ) async throws {
    let h = await Harness(status: scenario.status)
    let pre = try await h.begin(.preDownload)
    #expect(h.model.isPreDownloading)
    #expect(pre == 0)

    try await h.model.start(scenario.job)
    // The new run only begins after the fake observed the old stream terminate.
    #expect(
      h.fake.events == [
        "run:preDownload", "terminated:preDownload", "run:\(scenario.job.rawValue)",
      ])
    #expect(try await h.fake.nextRun() == 1)
    #expect(h.fake.isTerminated(run: 0))
    #expect(h.model.isPreDownloading == false)
    #expect(h.model.phase == (scenario.job == .update ? .updating : .repairing))
    #expect(h.jobFile?.kind == scenario.job)
    // Cancelling the pre-download is a pause, not an error.
    #expect(h.model.lastError == nil)
  }
}

// MARK: - INS-004

@MainActor @Suite struct INS_004_DiskSpaceTests {
  @Test func INS_004_shortageThrowsAndLeavesNoTrace() async throws {
    let h = await Harness(
      status: Status.notInstalled, chunkTempMargin: 1_000, availableDiskSpace: { _ in 5_000 })
    h.fake.setRequiredDiskSpace(10_000, for: .install)
    await #expect(throws: LauncherError.insufficientDiskSpace(required: 11_000, available: 5_000)) {
      try await h.model.start(.install)
    }
    #expect(h.model.phase == .idle)
    #expect(h.jobFileExists == false)
    #expect(h.fake.runs.isEmpty)
    #expect(h.model.pendingJob == nil)
  }

  @Test func INS_004_requiredIncludesChunkTempMargin() async throws {
    // 10_000 + 1_000 margin: 10_999 is one byte short.
    let h = await Harness(
      status: Status.notInstalled, chunkTempMargin: 1_000, availableDiskSpace: { _ in 10_999 })
    h.fake.setRequiredDiskSpace(10_000, for: .install)
    await #expect(throws: LauncherError.insufficientDiskSpace(required: 11_000, available: 10_999)) {
      try await h.model.start(.install)
    }
  }

  @Test func INS_004_exactlyEnoughSpaceIsAccepted() async throws {
    let h = await Harness(
      status: Status.notInstalled, chunkTempMargin: 1_000, availableDiskSpace: { _ in 11_000 })
    h.fake.setRequiredDiskSpace(10_000, for: .install)
    try await h.begin(.install)
    #expect(h.model.phase == .installing)
  }

  @Test func INS_004_unknownAvailableSpaceDoesNotBlock() async throws {
    let h = await Harness(status: Status.notInstalled, chunkTempMargin: 1_000, availableDiskSpace: { _ in nil })
    h.fake.setRequiredDiskSpace(10_000, for: .install)
    try await h.begin(.install)
    #expect(h.model.phase == .installing)
  }

  @Test func INS_004_zeroRequiredSkipsTheCheckEvenWithMargin() async throws {
    let h = await Harness(
      status: Status.notInstalled, chunkTempMargin: 1_000, availableDiskSpace: { _ in 0 })
    h.fake.setRequiredDiskSpace(0, for: .install)
    try await h.begin(.install)
    #expect(h.model.phase == .installing)
  }

  @Test(arguments: JobScenario.all)
  fileprivate func INS_004_everyDownloadJobChecksDiskSpace(_ scenario: JobScenario) async throws {
    let h = await Harness(
      status: scenario.status, chunkTempMargin: 100, availableDiskSpace: { _ in 999 })
    h.fake.setRequiredDiskSpace(1_000, for: scenario.job)
    await #expect(throws: LauncherError.insufficientDiskSpace(required: 1_100, available: 999)) {
      try await h.model.start(scenario.job)
    }
    #expect(h.model.phase == .idle)
    #expect(h.jobFileExists == false)
  }

  @Test func INS_004_availableSpaceIsQueriedForTheGameDirectory() async throws {
    let queried = Queried()
    let h = await Harness(
      status: Status.notInstalled, chunkTempMargin: 0,
      availableDiskSpace: { url in
        queried.record(url)
        return 1
      })
    h.fake.setRequiredDiskSpace(10, for: .install)
    _ = try? await h.model.start(.install)
    let urls = queried.urls
    #expect(urls.isEmpty == false)
    // The directory itself, or an existing ancestor of it.
    let directory = h.directory!.standardizedFileURL.path
    #expect(urls.allSatisfy { directory.hasPrefix($0.standardizedFileURL.path) })
  }

  @Test func INS_004_shortfallIsRequiredMinusAvailable() {
    let error = LauncherError.insufficientDiskSpace(required: 100, available: 30)
    #expect(error.shortfall == 70)
    #expect(LauncherError.insufficientDiskSpace(required: 30, available: 100).shortfall == 0)
    #expect(LauncherError.busy.shortfall == nil)
  }
}

private final class Queried: Sendable {
  private let storage = Mutex<[URL]>([])
  func record(_ url: URL) { storage.withLock { $0.append(url) } }
  var urls: [URL] { storage.withLock { $0 } }
}

// MARK: - INS-015

@MainActor @Suite struct INS_015_JobFileTests {
  @Test func INS_015_jobFileIsWrittenAtStartWithKindAndTargetVersion() async throws {
    let h = await Harness(status: Status.needsUpdate)
    #expect(h.jobFileExists == false)
    try await h.begin(.update)
    #expect(h.jobFile == PendingJob(kind: .update, targetVersion: "5.0.0"))
  }

  @Test func INS_015_jobFileKeptAfterPause() async throws {
    let h = await Harness(status: Status.notInstalled)
    try await h.begin(.install)
    await h.model.pause()
    #expect(h.jobFile == PendingJob(kind: .install, targetVersion: "5.0.0"))
  }

  @Test func INS_015_jobFileKeptAfterError() async throws {
    let h = await Harness(status: Status.notInstalled)
    let run = try await h.begin(.install)
    h.fake.finish(run: run, throwing: GameClientError.network)
    await h.model.waitUntilIdle()
    #expect(h.jobFile == PendingJob(kind: .install, targetVersion: "5.0.0"))
  }

  @Test func INS_015_jobFileKeptAfterShutdown() async throws {
    let h = await Harness(status: Status.notInstalled)
    try await h.begin(.install)
    await h.model.shutdown()
    #expect(h.jobFile == PendingJob(kind: .install, targetVersion: "5.0.0"))
  }

  @Test func INS_015_jobFileRemovedOnSuccess() async throws {
    let h = await Harness(status: Status.notInstalled)
    let run = try await h.begin(.install)
    #expect(h.jobFileExists)
    h.fake.setStatus(Status.installed)
    h.fake.finish(run: run)
    await h.model.waitUntilIdle()
    #expect(h.jobFileExists == false)
    #expect(h.model.pendingJob == nil)
  }

  @Test func INS_015_failureToRemoveJobFileIsReportedNotHidden() async throws {
    let h = await Harness(status: Status.notInstalled)
    let run = try await h.begin(.install)
    let tmp = h.jobFileURL.deletingLastPathComponent()
    try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: tmp.path)
    defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tmp.path) }
    h.fake.setStatus(Status.installed)
    h.fake.finish(run: run)
    await h.model.waitUntilIdle()
    #expect(h.model.lastError == .unexpected("job.json could not be removed"))
    #expect(h.model.phase == .idle)
  }

  @Test(arguments: ["not json at all {{", "", #"{"schemaVersion":1}"#, #"{"schemaVersion":1,"kind":"bogus"}"#])
  func INS_015_corruptJobFileIsIgnoredWithoutCrash(_ contents: String) async throws {
    let h = await Harness(status: Status.installed, preexistingJobFile: contents)
    #expect(h.model.pendingJob == nil)
    // A corrupt file must not block launching.
    try await h.beginLaunch()
    #expect(h.model.phase == .launching)
    h.fake.finishLaunch(.exited)
    await h.model.waitUntilIdle()
  }

  @Test func INS_015_corruptJobFileIsOverwrittenByNextJob() async throws {
    let h = await Harness(status: Status.notInstalled, preexistingJobFile: "garbage")
    try await h.begin(.install)
    #expect(h.jobFile == PendingJob(kind: .install, targetVersion: "5.0.0"))
  }

  @Test func INS_015_unknownJsonFieldsAreTolerated() async {
    let extra = #","futureField":{"nested":[1,2,3]},"anotherOne":"x""#
    let h = await Harness(
      status: Status.needsUpdate, preexistingJobFile: jobJSON(kind: "update", target: "5.1.0", extra: extra))
    #expect(h.model.pendingJob == PendingJob(kind: .update, targetVersion: "5.1.0"))
  }

  @Test func INS_015_refreshLoadsPendingJobIntoModel() async {
    let h = await Harness(
      status: Status.notInstalled, preexistingJobFile: jobJSON(kind: "install", target: "5.0.0"))
    #expect(h.model.pendingJob == PendingJob(kind: .install, targetVersion: "5.0.0"))
  }

  @Test func INS_015_refreshWithoutJobFileLeavesPendingJobNil() async {
    let h = await Harness(status: Status.installed)
    #expect(h.model.pendingJob == nil)
  }

  @Test func INS_015_refreshPicksUpJobFileAppearingLater() async {
    let h = await Harness(status: Status.installed)
    #expect(h.model.pendingJob == nil)
    h.writeJobFile(jobJSON(kind: "repair", target: "5.0.0"))
    await h.model.refresh()
    #expect(h.model.pendingJob == PendingJob(kind: .repair, targetVersion: "5.0.0"))
  }

  @Test(arguments: JobScenario.all)
  fileprivate func INS_015_resumeRerunsTheSameKind(_ scenario: JobScenario) async throws {
    let h = await Harness(
      status: scenario.status,
      preexistingJobFile: jobJSON(kind: scenario.job.rawValue, target: "5.0.0"))
    #expect(h.model.pendingJob?.kind == scenario.job)
    try await h.model.resume()
    #expect(try await h.fake.nextRun() == 0)
    #expect(h.fake.runs == [scenario.job])
  }
}

// MARK: - PRG-006

@MainActor @Suite struct PRG_006_PauseTests {
  @Test func PRG_006_pauseCancelsAndWaitsForTermination() async throws {
    let h = await Harness(status: Status.notInstalled)
    let run = try await h.begin(.install)
    let statusCallsBefore = h.fake.statusCalls

    await h.model.pause()

    #expect(h.model.phase == .idle)
    #expect(h.fake.isTerminated(run: run))
    #expect(h.model.isPausing == false)
    #expect(h.model.lastError == nil)
    #expect(h.fake.statusCalls == statusCallsBefore, "a paused job must not be treated as success")
    #expect(h.jobFile == PendingJob(kind: .install, targetVersion: "5.0.0"))
    // The stream ends normally on cancel; that must not be classified as success.
    try await h.expectNextEventIsSentinelFailure()
  }

  @Test func PRG_006_pauseThenResumeRunsTheSameJobAgain() async throws {
    let h = await Harness(status: Status.needsUpdate)
    try await h.begin(.update)
    await h.model.pause()
    await h.model.refresh()
    #expect(h.model.pendingJob?.kind == .update)

    try await h.model.resume()
    #expect(try await h.fake.nextRun() == 1)
    #expect(h.fake.runs == [.update, .update])
    #expect(h.model.phase == .updating)
  }

  @Test func PRG_006_pauseWhileIdleIsANoOp() async {
    let h = await Harness(status: Status.installed)
    await h.model.pause()
    #expect(h.model.phase == .idle)
    #expect(h.model.isPausing == false)
    #expect(h.fake.events.isEmpty)
  }

  @Test func PRG_006_pauseDoesNotBlockOnARunningGame() async throws {
    let h = await Harness(status: Status.installed)
    try await h.beginLaunch()
    await h.model.pause()  // must return at once; the game keeps running
    #expect(h.model.phase == .launching)
    h.fake.finishLaunch(.exited)
    await h.model.waitUntilIdle()
  }

  @Test func PRG_006_pauseDuringDiskPreflightStopsTheStartBeforeAnyRun() async throws {
    let h = await Harness(status: Status.installed)
    h.fake.stallsDiskQuery.withLock { $0 = true }
    let starting = Task { try await h.model.start(.repair) }
    try await h.fake.diskQueries.pop("the disk query")
    #expect(h.model.phase == .repairing)
    await h.model.pause()
    try await starting.value
    #expect(h.model.phase == .idle)
    #expect(h.model.isPausing == false)
    #expect(h.fake.runs.isEmpty)
    #expect(!h.jobFileExists)
  }

  @Test func PRG_006_shutdownDuringDiskPreflightStopsTheStartBeforeAnyRun() async throws {
    let h = await Harness(status: Status.installed)
    h.fake.stallsDiskQuery.withLock { $0 = true }
    let starting = Task { try await h.model.start(.repair) }
    try await h.fake.diskQueries.pop("the disk query")
    await h.model.shutdown()
    try await starting.value
    #expect(h.model.phase == .idle)
    #expect(h.fake.runs.isEmpty)
  }

  @Test func PRG_006_pauseCancelsPreDownload() async throws {
    let h = await Harness(status: Status.preDownloadable)
    let run = try await h.begin(.preDownload)
    await h.model.pause()
    #expect(h.fake.isTerminated(run: run))
    #expect(h.model.isPreDownloading == false)
    #expect(h.jobFile?.kind == .preDownload)
  }

  @Test func PRG_006_shutdownCancelsJobAndWaitsKeepingJobFile() async throws {
    let h = await Harness(status: Status.notInstalled)
    let run = try await h.begin(.install)
    await h.model.shutdown()
    #expect(h.fake.isTerminated(run: run))
    #expect(h.model.phase == .idle)
    #expect(h.jobFileExists)
  }

  @Test func PRG_006_shutdownCancelsLaunchAndWaitsForItToReturn() async throws {
    let h = await Harness(status: Status.installed)
    try await h.beginLaunch()
    await h.model.shutdown()
    #expect(h.fake.events == ["launch", "launch:cancelled", "launch:ended"])
    #expect(h.model.phase == .idle)
  }

  @Test func PRG_006_shutdownCancelsEverythingAtOnce() async throws {
    let h = await Harness(status: Status.preDownloadable)
    try await h.beginLaunch()
    let run = try await h.begin(.preDownload)
    await h.model.shutdown()
    #expect(h.fake.isTerminated(run: run))
    #expect(h.fake.events.contains("launch:ended"))
    #expect(h.model.phase == .idle)
    #expect(h.model.isPreDownloading == false)
    #expect(h.jobFile?.kind == .preDownload)
  }
}

// MARK: - UPG-013

@MainActor @Suite struct UPG_013_SuccessTests {
  @Test func UPG_013_successEmitsFinishedRemovesJobFileAndRefreshesStatus() async throws {
    let h = await Harness(status: Status.needsUpdate)
    #expect(h.model.primaryAction == .update)
    let run = try await h.begin(.update)
    h.fake.yield(.running(done: 1, total: 2), run: run)
    let statusCallsBefore = h.fake.statusCalls
    h.fake.setStatus(Status.installed)
    h.fake.finish(run: run)
    await h.model.waitUntilIdle()

    #expect(try await h.log.next() == .finished(.update))
    #expect(h.jobFileExists == false)
    #expect(h.fake.statusCalls > statusCallsBefore)
    #expect(h.model.status == Status.installed)
    #expect(h.model.primaryAction == .launch)
    #expect(h.model.phase == .idle)
    #expect(h.model.lastError == nil)
  }

  @Test func UPG_013_installSuccessSwitchesPrimaryActionToLaunch() async throws {
    let h = await Harness(status: Status.notInstalled)
    #expect(h.model.primaryAction == .install)
    let run = try await h.begin(.install)
    h.fake.setStatus(Status.installed)
    h.fake.finish(run: run)
    await h.model.waitUntilIdle()
    #expect(try await h.log.next() == .finished(.install))
    #expect(h.model.primaryAction == .launch)
  }

  @Test func UPG_013_preDownloadSuccessEmitsFinishedAndClearsFlag() async throws {
    let h = await Harness(status: Status.preDownloadable)
    let run = try await h.begin(.preDownload)
    h.fake.finish(run: run)
    await h.model.waitUntilIdle()
    #expect(try await h.log.next() == .finished(.preDownload))
    #expect(h.jobFileExists == false)
    #expect(h.model.isPreDownloading == false)
    #expect(h.model.phase == .idle)
  }

  @Test func UPG_013_repairSuccessEmitsFinished() async throws {
    let h = await Harness(status: Status.installed)
    let run = try await h.begin(.repair)
    #expect(h.model.phase == .repairing)
    h.fake.finish(run: run)
    await h.model.waitUntilIdle()
    #expect(try await h.log.next() == .finished(.repair))
    #expect(h.model.phase == .idle)
  }
}

// MARK: - REP-002

@MainActor @Suite struct REP_002_PreconditionTests {
  @Test func REP_002_repairRejectedWithUpdateRequiredWhenUpdateAvailable() async {
    let h = await Harness(status: Status.needsUpdate)
    await #expect(throws: LauncherError.updateRequired) { try await h.model.start(.repair) }
    #expect(h.fake.runs.isEmpty)
    #expect(h.jobFileExists == false)
    #expect(h.model.phase == .idle)
  }

  @Test(arguments: [GameJob.update, .repair])
  func REP_002_updateAndRepairRejectedWithNotInstalledWhenNotInstalled(_ job: GameJob) async {
    let h = await Harness(status: Status.notInstalled)
    await #expect(throws: LauncherError.notInstalled) { try await h.model.start(job) }
    #expect(h.fake.runs.isEmpty)
    #expect(h.jobFileExists == false)
    #expect(h.model.phase == .idle)
  }

  @Test func REP_002_preDownloadRejectedWhenUnavailable() async {
    let h = await Harness(status: Status.installed)
    await #expect(throws: LauncherError.preDownloadUnavailable) { try await h.model.start(.preDownload) }
    #expect(h.fake.runs.isEmpty)
    #expect(h.jobFileExists == false)
    #expect(h.model.phase == .idle)
    #expect(h.model.isPreDownloading == false)
  }

  @Test func REP_002_repairRunsWhenInstalledAndUpToDate() async throws {
    let h = await Harness(status: Status.installed)
    try await h.begin(.repair)
    #expect(h.fake.runs == [.repair])
    #expect(h.model.phase == .repairing)
  }

  @Test func REP_002_updateRunsWhenUpdateAvailable() async throws {
    let h = await Harness(status: Status.needsUpdate)
    try await h.begin(.update)
    #expect(h.fake.runs == [.update])
    #expect(h.model.phase == .updating)
  }

  @Test func REP_002_preDownloadRunsWhenAvailable() async throws {
    let h = await Harness(status: Status.preDownloadable)
    try await h.begin(.preDownload)
    #expect(h.fake.runs == [.preDownload])
    #expect(h.model.isPreDownloading)
  }
}

// MARK: - LCH-036 and launch preconditions

@MainActor @Suite struct LCH_036_LaunchTests {
  @Test func LCH_036_defaultLaunchTimeoutIs120Seconds() {
    #expect(LauncherModel.defaultLaunchTimeout == .seconds(120))
  }

  @Test func LCH_036_launchWithoutStartedSignalTimesOutCancelsAndAwaitsTheLaunch() async throws {
    let h = await Harness(status: Status.installed, launchTimeout: .seconds(7))
    try await h.beginLaunch()
    #expect(h.model.phase == .launching)
    #expect(try await h.sleeper.sleeping.pop("the timeout sleep") == .seconds(7))

    h.sleeper.fire()
    await h.model.waitUntilIdle()

    #expect(h.model.lastError == .launchTimeout)
    #expect(h.model.phase == .idle)
    // Cancelled and awaited: the fake's launch has already returned.
    #expect(h.fake.events == ["launch", "launch:cancelled", "launch:ended"])
  }

  @Test func LCH_036_launchCanBeRetriedAfterTimeout() async throws {
    let h = await Harness(status: Status.installed)
    try await h.beginLaunch()
    _ = try await h.sleeper.sleeping.pop("the timeout sleep")
    h.sleeper.fire()
    await h.model.waitUntilIdle()
    #expect(h.model.lastError == .launchTimeout)

    try await h.beginLaunch()
    #expect(h.model.phase == .launching)
    #expect(h.fake.launchOptions.count == 2)
  }

  @Test func LCH_036_startedInTimeMovesToRunningThenIdleAfterExit() async throws {
    let h = await Harness(status: Status.installed)
    try await h.beginLaunch()
    #expect(h.model.phase == .launching)
    #expect(h.fake.launchOptions.map(\.gameDirectory) == [h.directory!])

    h.fake.fireStarted()
    #expect(await h.waitForPhase(.running))

    h.fake.finishLaunch(.exited)
    await h.model.waitUntilIdle()
    #expect(h.model.phase == .idle)
    #expect(h.model.lastError == nil)
    #expect(h.fake.events == ["launch", "launch:ended"])
  }

  @Test func LCH_036_timeoutDoesNotFireOnceStartedHasBeenSignalled() async throws {
    let h = await Harness(status: Status.installed)
    try await h.beginLaunch()
    h.fake.fireStarted()
    #expect(await h.waitForPhase(.running))
    // A late timer must not kill a game that already started.
    h.sleeper.fire()
    h.fake.finishLaunch(.exited)
    await h.model.waitUntilIdle()
    #expect(h.model.lastError == nil)
    #expect(h.fake.events == ["launch", "launch:ended"])
  }

  @Test func LCH_036_failedExitReportsGameExitedAndEmitsLaunchFailed() async throws {
    let h = await Harness(status: Status.installed)
    let log = URL(filePath: "/tmp/fake-game-log.txt")
    try await h.beginLaunch()
    h.fake.fireStarted()
    h.fake.finishLaunch(.failedExit(code: 3, logPath: log))
    await h.model.waitUntilIdle()

    let expected = LauncherError.gameExited(code: 3, logPath: log)
    #expect(h.model.phase == .idle)
    #expect(h.model.lastError == expected)
    #expect(try await h.log.next() == .launchFailed(expected))
  }

  @Test func LCH_036_failedToLaunchReportsErrorAndEmitsLaunchFailed() async throws {
    let h = await Harness(status: Status.installed)
    try await h.beginLaunch()
    h.fake.finishLaunch(.failedToLaunch)
    await h.model.waitUntilIdle()

    #expect(h.model.phase == .idle)
    #expect(h.model.lastError == .failedToLaunch)
    #expect(try await h.log.next() == .launchFailed(.failedToLaunch))
  }

  @Test func LCH_036_cleanExitEmitsNoEvent() async throws {
    let h = await Harness(status: Status.installed)
    try await h.beginLaunch()
    h.fake.fireStarted()
    h.fake.finishLaunch(.exited)
    await h.model.waitUntilIdle()
    try await h.expectNextEventIsSentinelFailure()
  }

  // Launch preconditions

  @Test func LCH_036_launchRejectedWithNoGameDirectory() async {
    let h = await Harness(status: Status.installed, hasGameDirectory: false)
    await #expect(throws: LauncherError.noGameDirectory) { try await h.model.launch() }
    #expect(h.model.phase == .idle)
    #expect(h.fake.launchOptions.isEmpty)
  }

  @Test func LCH_036_launchRejectedWithNotInstalled() async {
    let h = await Harness(status: Status.notInstalled)
    await #expect(throws: LauncherError.notInstalled) { try await h.model.launch() }
    #expect(h.fake.launchOptions.isEmpty)
  }

  @Test func LCH_036_launchRejectedWithUpdateRequired() async {
    let h = await Harness(status: Status.needsUpdate)
    await #expect(throws: LauncherError.updateRequired) { try await h.model.launch() }
    #expect(h.fake.launchOptions.isEmpty)
  }

  @Test(arguments: [GameJob.install, .update, .repair])
  func LCH_036_launchRejectedWithPendingJobOfKind(_ kind: GameJob) async {
    let h = await Harness(status: Status.installed, preexistingJobFile: jobJSON(kind: kind.rawValue, target: "5.0.0"))
    await #expect(throws: LauncherError.pendingJob(kind)) { try await h.model.launch() }
    #expect(h.fake.launchOptions.isEmpty)
    #expect(h.model.phase == .idle)
  }

  @Test func LCH_036_pendingPreDownloadDoesNotBlockLaunch() async throws {
    let h = await Harness(
      status: Status.preDownloadable, preexistingJobFile: jobJSON(kind: "preDownload", target: "5.1.0"))
    try await h.beginLaunch()
    #expect(h.model.phase == .launching)
  }

  @Test func LCH_036_launchPassesGameDirectoryOption() async throws {
    let h = await Harness(status: Status.installed)
    try await h.beginLaunch()
    #expect(h.fake.launchOptions == [LaunchOptions(gameDirectory: h.directory!)])
  }
}
