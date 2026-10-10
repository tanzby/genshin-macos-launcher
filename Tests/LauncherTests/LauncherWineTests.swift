import Foundation
import Platform
import Testing
import Wine

@testable import Launcher

// Wine preparation is an exclusive job in the launcher state machine (ADR 0002, ticket #23). It has no
// `job.json`: the state is derived from the `<data>/wine/` version stamp, which the real `WineRuntime`
// reports through `WinePreparing.status()`. These tests use `FakeWinePreparer` and `FakeGameClient`.

private let installed = GameStatus(localVersion: "5.0.0", remoteVersion: "5.0.0")
private let notInstalled = GameStatus(localVersion: nil, remoteVersion: "5.0.0")
private let missing = WineStatus.needsInstall(.notInstalled)

@MainActor
private final class Harness {
  let wine: FakeWinePreparer
  let fake: FakeGameClient
  let model: LauncherModel
  let log: EventLog
  let directory: URL

  var jobFile: URL { directory.appending(path: ".yaagl-tmp").appending(path: "job.json") }

  init(wine wineStatus: WineStatus, game: GameStatus = installed) {
    wine = FakeWinePreparer(status: wineStatus)
    fake = FakeGameClient(status: game)
    directory = FileManager.default.temporaryDirectory.appending(path: "LauncherWineTests-\(UUID().uuidString)")
    try! FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    model = LauncherModel(client: fake, wine: wine, gameDirectory: directory, chunkTempMargin: 0)
    log = EventLog(model.events)
  }

  deinit { try? FileManager.default.removeItem(at: directory) }

  /// Runs `bootstrap()` in the background and returns once Wine is being prepared.
  func bootstrapUntilPreparing() async throws -> (task: Task<Void, Never>, install: Int) {
    let model = model
    let task = Task { @MainActor in await model.bootstrap() }
    let index = try await wine.nextInstall()
    return (task, index)
  }

  func waitUntil(_ predicate: @escaping @MainActor @Sendable () -> Bool) async -> Bool {
    let outcome = AsyncQueue<Bool>()
    let watcher = Task { @MainActor in
      let values = Observations { predicate() }
      for await value in values where value {
        outcome.push(true)
        return
      }
      outcome.push(false)
    }
    let timer = Task {
      try? await Task.sleep(for: AsyncQueue<Int>.failsafe)
      outcome.push(false)
    }
    let result = await outcome.pop() ?? false
    watcher.cancel()
    timer.cancel()
    return result
  }
}

// MARK: - WIN-005 / APP-001: startup order

@MainActor @Suite struct WIN_005_StartupTests {
  @Test func WIN_005_readyWineSkipsPreparationAndReadsGameStatus() async throws {
    let h = Harness(wine: .ready)
    await h.model.bootstrap()
    #expect(h.wine.installCount == 0)
    #expect(h.wine.statusCalls == 1)
    #expect(h.fake.statusCalls == 1)
    #expect(h.model.status == installed)
    #expect(h.model.wineStatus == .ready)
    #expect(h.model.phase == .idle)
    #expect(h.model.primaryAction == .launch)
  }

  @Test(arguments: [
    WineStatus.needsInstall(.notInstalled),
    .needsInstall(.interrupted),
    .needsInstall(.versionMismatch),
    .needsInstall(.corrupt(missing: "bin/wine")),
  ])
  func WIN_005_everyNotReadyReasonStartsPreparation(_ status: WineStatus) async throws {
    let h = Harness(wine: status)
    let (task, install) = try await h.bootstrapUntilPreparing()
    #expect(h.model.phase == .preparingWine)
    #expect(h.model.wineStatus == status)
    h.wine.finish(install: install)
    await task.value
    #expect(h.model.phase == .idle)
  }

  @Test func APP_001_wineIsReadyBeforeGameStatusIsRead() async throws {
    let h = Harness(wine: missing)
    let (task, install) = try await h.bootstrapUntilPreparing()
    #expect(h.model.phase == .preparingWine)
    #expect(h.fake.statusCalls == 0, "game status must not be read before Wine is ready")
    #expect(h.model.status == nil)

    h.wine.finish(install: install)
    await task.value
    #expect(h.fake.statusCalls == 1)
    #expect(h.model.status == installed)
    #expect(h.model.wineStatus == .ready)
    #expect(h.model.phase == .idle)
    #expect(try await h.log.next() == .wineReady)
  }

  @Test func APP_001_failedPreparationNeverReadsGameStatus() async throws {
    let h = Harness(wine: missing)
    let (task, install) = try await h.bootstrapUntilPreparing()
    h.wine.fail(install: install, throwing: WineInstallError.dxmtArchiveInvalid)
    await task.value
    #expect(h.fake.statusCalls == 0)
    #expect(h.model.status == nil)
    #expect(h.model.phase == .idle)
  }

  @Test func WIN_005_preparationWritesNoJobFile() async throws {
    let h = Harness(wine: missing)
    let (task, install) = try await h.bootstrapUntilPreparing()
    #expect(h.model.pendingJob == nil)
    #expect(!FileManager.default.fileExists(atPath: h.jobFile.path))
    #expect(!FileManager.default.fileExists(atPath: h.jobFile.deletingLastPathComponent().path))
    h.wine.fail(install: install, throwing: WineInstallError.dxmtArchiveInvalid)
    await task.value
    #expect(h.model.pendingJob == nil)
    #expect(!FileManager.default.fileExists(atPath: h.jobFile.path))
  }

  @Test func WIN_005_launcherWithoutWineSeamBehavesAsBefore() async throws {
    let fake = FakeGameClient(status: installed)
    let model = LauncherModel(client: fake)
    await model.bootstrap()
    #expect(model.status == installed)
    #expect(model.wineStatus == nil)
    #expect(model.primaryAction == .launch)
  }

  @Test func WIN_005_bootstrapWhileBusyDoesNothing() async throws {
    let h = Harness(wine: missing)
    let (task, install) = try await h.bootstrapUntilPreparing()
    await h.model.bootstrap()
    #expect(h.wine.installCount == 1)
    h.wine.finish(install: install)
    await task.value
  }

  @Test func WIN_005_refreshWineTracksTheDisk() async throws {
    let h = Harness(wine: .ready)
    await h.model.refreshWine()
    #expect(h.model.wineStatus == .ready)
    h.wine.setStatus(.needsInstall(.corrupt(missing: "bin/wine")))
    await h.model.refreshWine()
    #expect(h.model.wineStatus == .needsInstall(.corrupt(missing: "bin/wine")))
    #expect(h.model.primaryAction == .prepareWine)
  }
}

// MARK: - Progress and gating

@MainActor @Suite struct WIN_005_PhaseTests {
  @Test func WIN_005_wineProgressIsForwardedAndClearedAtTheEnd() async throws {
    let h = Harness(wine: missing)
    let (task, install) = try await h.bootstrapUntilPreparing()
    #expect(h.model.progress == .preparing)

    let download = DownloadProgress(completed: 10, total: 100)
    h.wine.yield(.downloadingWine(download), install: install)
    #expect(await h.waitUntil { h.model.progress == .wine(.downloadingWine(download)) })
    h.wine.yield(.extracting, install: install)
    #expect(await h.waitUntil { h.model.progress == .wine(.extracting) })

    h.wine.finish(install: install)
    await task.value
    #expect(h.model.progress == nil)
  }

  @Test func WIN_005_notReadyWineBlocksGameJobsAndLaunch() async throws {
    let h = Harness(wine: missing, game: notInstalled)
    await h.model.refreshWine()
    await h.model.refresh()
    #expect(h.model.primaryAction == .prepareWine)
    for job in [GameJob.install, .update, .repair, .preDownload] {
      await #expect(throws: LauncherError.wineNotReady, "\(job)") { try await h.model.start(job) }
    }
    await #expect(throws: LauncherError.wineNotReady) { try await h.model.launch() }
    #expect(h.fake.runs.isEmpty)
    #expect(h.model.phase == .idle)
  }

  @Test func WIN_005_unreadWineStatusBlocksGameJobsToo() async throws {
    // `bootstrap()` suspends inside `wine.status()`; nothing may slip in during that window.
    let h = Harness(wine: .ready)
    #expect(h.model.wineStatus == nil)
    for job in [GameJob.install, .update, .repair, .preDownload] {
      await #expect(throws: LauncherError.wineNotReady, "\(job)") { try await h.model.start(job) }
    }
    await #expect(throws: LauncherError.wineNotReady) { try await h.model.launch() }
    #expect(h.fake.runs.isEmpty)
    #expect(h.model.phase == .idle)
  }

  @Test func WIN_005_gameJobsWorkOnceWineIsReady() async throws {
    let h = Harness(wine: missing, game: notInstalled)
    let (task, install) = try await h.bootstrapUntilPreparing()
    h.wine.finish(install: install)
    await task.value
    #expect(h.model.primaryAction == .install)
    try await h.model.start(.install)
    #expect(h.model.phase == .installing)
    let run = try await h.fake.nextRun()
    h.fake.finish(run: run)
    await h.model.waitUntilIdle()
  }

  @Test func APP_015_everyExclusiveEntryIsBusyWhileWineIsPrepared() async throws {
    let h = Harness(wine: missing)
    let (task, install) = try await h.bootstrapUntilPreparing()
    for job in [GameJob.install, .update, .repair, .preDownload] {
      await #expect(throws: LauncherError.busy, "\(job)") { try await h.model.start(job) }
    }
    await #expect(throws: LauncherError.busy) { try await h.model.launch() }
    await #expect(throws: LauncherError.busy) { try await h.model.prepareWine() }
    #expect(h.wine.installCount == 1)
    #expect(h.fake.runs.isEmpty)
    h.wine.finish(install: install)
    await task.value
  }

  @Test func APP_015_wineCannotBePreparedWhileAGameJobRuns() async throws {
    let h = Harness(wine: .ready, game: notInstalled)
    await h.model.bootstrap()
    try await h.model.start(.install)
    _ = try await h.fake.nextRun()
    h.wine.setStatus(missing)
    await #expect(throws: LauncherError.busy) { try await h.model.prepareWine() }
    #expect(h.wine.installCount == 0)
    await h.model.shutdown()
  }

  @Test func APP_015_preparingWineStopsARunningPreDownloadFirst() async throws {
    let h = Harness(wine: .ready, game: GameStatus(localVersion: "5.0.0", remoteVersion: "5.0.0", canPreDownload: true))
    await h.model.bootstrap()
    try await h.model.start(.preDownload)
    let run = try await h.fake.nextRun()
    #expect(h.model.isPreDownloading)

    h.wine.setStatus(missing)
    await h.model.refreshWine()
    try await h.model.prepareWine()
    let install = try await h.wine.nextInstall()
    #expect(h.fake.isTerminated(run: run), "the pre-download must have stopped before Wine preparation began")
    #expect(!h.model.isPreDownloading)
    #expect(h.model.phase == .preparingWine)
    h.wine.finish(install: install)
    await h.model.waitUntilIdle()
  }

  @Test func WIN_005_prepareWineIsANoOpWhenWineIsAlreadyReady() async throws {
    let h = Harness(wine: .ready)
    await h.model.bootstrap()
    try await h.model.prepareWine()
    #expect(h.model.phase == .idle)
    #expect(h.wine.installCount == 0)
  }
}

// MARK: - Pause, resume, shutdown

@MainActor @Suite struct WIN_005_PauseTests {
  @Test func WIN_005_pauseCancelsAndWaitsUntilTheInstallHasStopped() async throws {
    let h = Harness(wine: missing)
    h.wine.holdCancellation(true)
    let (task, first) = try await h.bootstrapUntilPreparing()

    let pause = Task { @MainActor in await h.model.pause() }
    #expect(try await h.wine.nextCancellation() == first)
    #expect(await h.waitUntil { h.model.isPausing })
    #expect(h.model.phase == .preparingWine, "pause must not report idle before the install stopped")
    #expect(!h.wine.log.contains("stopped:0"))

    h.wine.releaseCancelled(install: first)
    await pause.value
    await task.value
    #expect(h.wine.log.contains("stopped:0"))
    #expect(h.model.isPausing == false)
    #expect(h.model.phase == .idle)
    #expect(h.model.lastError == nil)
    #expect(h.model.progress == nil)
    #expect(h.fake.statusCalls == 0, "a paused preparation has not made Wine ready")
    #expect(h.model.primaryAction == .prepareWine)
    #expect(h.model.pendingJob == nil)
    #expect(!FileManager.default.fileExists(atPath: h.jobFile.path))
  }

  @Test func WIN_005_pauseIsNotReportedAsAFailure() async throws {
    let h = Harness(wine: missing)
    let (task, _) = try await h.bootstrapUntilPreparing()
    await h.model.pause()
    await task.value
    #expect(h.model.lastError == nil)
    // the sentinel failure proves the paused preparation emitted nothing before it
    try await h.model.prepareWine()
    let retry = try await h.wine.nextInstall()
    h.wine.fail(install: retry, throwing: WineInstallError.dxmtArchiveInvalid)
    await h.model.waitUntilIdle()
    #expect(try await h.log.next() == .wineFailed(.wineInstall(.dxmtArchiveInvalid)))
  }

  @Test func WIN_005_resumeAfterPauseRerunsEnsureInstalledAndReadsGameStatus() async throws {
    let h = Harness(wine: missing)
    let (task, first) = try await h.bootstrapUntilPreparing()
    await h.model.pause()
    await task.value
    #expect(h.wine.installCount == 1)

    try await h.model.resume()
    let second = try await h.wine.nextInstall()
    #expect(second == 1)
    #expect(h.model.phase == .preparingWine)
    h.wine.finish(install: second)
    await h.model.waitUntilIdle()
    #expect(h.wine.installCount == 2)
    #expect(h.wine.log.contains("cancelled:\(first)"))
    #expect(h.model.wineStatus == .ready)
    #expect(h.model.status == installed)
    #expect(try await h.log.next() == .wineReady)
  }

  @Test func WIN_005_pausingWhileIdleIsANoOp() async throws {
    let h = Harness(wine: .ready)
    await h.model.bootstrap()
    await h.model.pause()
    #expect(h.model.isPausing == false)
    #expect(h.model.phase == .idle)
  }

  @Test func WIN_005_shutdownCancelsPreparationAndWaitsForIt() async throws {
    let h = Harness(wine: missing)
    h.wine.holdCancellation(true)
    let (task, install) = try await h.bootstrapUntilPreparing()
    let shutdown = Task { @MainActor in await h.model.shutdown() }
    #expect(try await h.wine.nextCancellation() == install)
    #expect(h.model.phase == .preparingWine)
    h.wine.releaseCancelled(install: install)
    await shutdown.value
    await task.value
    #expect(h.wine.log.contains("stopped:0"))
    #expect(h.model.phase == .idle)
    await #expect(throws: LauncherError.busy) { try await h.model.prepareWine() }
  }
}

// MARK: - APP-013: errors return to idle and are retryable

@MainActor @Suite struct WIN_005_ErrorTests {
  @Test func APP_013_wineFailureReturnsToIdleAndRetryWorks() async throws {
    let h = Harness(wine: missing)
    let (task, first) = try await h.bootstrapUntilPreparing()
    let logURL = URL(filePath: "/tmp/wineboot.log")
    let failure = WineInstallError.prefixInitializationFailed(logURL: logURL)
    h.wine.fail(install: first, throwing: failure)
    await task.value

    #expect(h.model.phase == .idle)
    #expect(h.model.lastError == .wineInstall(failure))
    #expect(h.model.progress == nil)
    #expect(h.model.primaryAction == .prepareWine)
    #expect(try await h.log.next() == .wineFailed(.wineInstall(failure)))

    try await h.model.prepareWine()
    let second = try await h.wine.nextInstall()
    #expect(second == 1)
    #expect(h.model.lastError == nil, "starting a retry clears the previous error")
    h.wine.finish(install: second)
    await h.model.waitUntilIdle()
    #expect(h.model.wineStatus == .ready)
    #expect(h.model.status == installed)
    #expect(try await h.log.next() == .wineReady)
  }

  @Test func APP_013_insufficientDiskSpaceReportsTheShortfall() async throws {
    let h = Harness(wine: missing)
    let (task, install) = try await h.bootstrapUntilPreparing()
    h.wine.fail(install: install, throwing: WineInstallError.insufficientDiskSpace(required: 3_000, available: 1_000))
    await task.value
    let error = LauncherError.insufficientDiskSpace(required: 3_000, available: 1_000)
    #expect(h.model.lastError == error)
    #expect(h.model.lastError?.shortfall == 2_000)
    #expect(try await h.log.next() == .wineFailed(error))
  }

  @Test(arguments: [
    (URLError(.notConnectedToInternet) as any Error, LauncherError.client(.network)),
    (URLError(.timedOut) as any Error, LauncherError.client(.network)),
    (DownloadError.httpStatus(503) as any Error, LauncherError.client(.network)),
    (
      DownloadError.checksumMismatch(expected: "a", actual: "b") as any Error,
      LauncherError.client(.verificationFailed)
    ),
    (
      WineInstallError.extractionFailed(tool: "tar", exitCode: 1, output: "bad") as any Error,
      LauncherError.wineInstall(.extractionFailed(tool: "tar", exitCode: 1, output: "bad"))
    ),
  ])
  func APP_013_downloadAndInstallErrorsAreClassified(_ pair: (any Error, LauncherError)) async throws {
    let h = Harness(wine: missing)
    let (task, install) = try await h.bootstrapUntilPreparing()
    h.wine.fail(install: install, throwing: pair.0)
    await task.value
    #expect(h.model.lastError == pair.1)
    #expect(h.model.phase == .idle)
  }

  @Test func APP_013_urlSessionCancellationCountsAsPause() async throws {
    let h = Harness(wine: missing)
    let (task, install) = try await h.bootstrapUntilPreparing()
    h.wine.fail(install: install, throwing: URLError(.cancelled))
    await task.value
    #expect(h.model.lastError == nil)
    #expect(h.model.phase == .idle)
  }

  @Test func APP_013_failureAfterWineWasReadyDoesNotTouchGameState() async throws {
    let h = Harness(wine: .ready)
    await h.model.bootstrap()
    h.wine.setStatus(.needsInstall(.corrupt(missing: "bin/wine")))
    await h.model.refreshWine()
    #expect(h.model.status == installed, "game status survives a Wine problem")
    #expect(h.model.primaryAction == .prepareWine)
  }
}
