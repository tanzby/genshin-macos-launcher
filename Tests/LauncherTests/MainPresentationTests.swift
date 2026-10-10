import Foundation
import Synchronization
import Platform
import Testing
import Wine

@testable import Launcher

private func snapshot(
  phase: LauncherPhase = .idle, preDownloading: Bool = false, pausing: Bool = false,
  progress: JobProgress? = nil, pending: PendingJob? = nil, error: LauncherError? = nil,
  status: GameStatus? = GameStatus(localVersion: "5.0.0", remoteVersion: "5.0.0"),
  online: Bool = true, hostsOK: Bool = true
) -> MainSnapshot {
  MainSnapshot(
    phase: phase, isPreDownloading: preDownloading, isPausing: pausing, progress: progress,
    pendingJob: pending, lastError: error, status: status, isOnline: online, hostsAllowLaunch: hostsOK)
}

@Suite struct APP_017_MainButtonTests {
  @Test func APP_017_notInstalledOffersInstall() {
    let p = MainPresentation.derive(snapshot(status: nil))
    #expect(p.button == .install)
    #expect(p.buttonEnabled)
    #expect(p.status == .none)
  }

  @Test func APP_017_updateAvailableOffersUpdate() {
    let status = GameStatus(localVersion: "5.0.0", remoteVersion: "5.1.0", canUpdate: true)
    let p = MainPresentation.derive(snapshot(status: status))
    #expect(p.button == .update)
    #expect(p.status == .updateAvailable(version: "5.1.0"))
  }

  @Test func APP_017_upToDateOffersLaunchWithNoStatus() {
    let p = MainPresentation.derive(snapshot())
    #expect(p.button == .launch)
    #expect(p.buttonEnabled)
    #expect(p.status == .none)
  }

  @Test func APP_017_installAndUpdateCanBePausedAndResumed() {
    let running = JobProgress.running(done: 10, total: 100)
    for (phase, job) in [(LauncherPhase.installing, GameJob.install), (.updating, .update)] {
      let busy = MainPresentation.derive(snapshot(phase: phase, progress: running))
      #expect(busy.button == .pause)
      #expect(busy.buttonEnabled)
      #expect(busy.status == .job(job, running, paused: false))

      let pausing = MainPresentation.derive(snapshot(phase: phase, pausing: true, progress: running))
      #expect(pausing.button == .pausing)
      #expect(!pausing.buttonEnabled)
    }
    let paused = MainPresentation.derive(snapshot(pending: PendingJob(kind: .install)))
    #expect(paused.button == .resume)
    #expect(paused.buttonEnabled)
    #expect(paused.status == .job(.install, nil, paused: true))
  }

  @Test func APP_017_repairIsADisabledButton() {
    let p = MainPresentation.derive(snapshot(phase: .repairing, progress: .running(done: 3, total: 9)))
    #expect(p.button == .repairing)
    #expect(!p.buttonEnabled)
  }

  @Test func APP_017_errorWithUnfinishedJobOffersRetryFromTheBreakpoint() {
    let p = MainPresentation.derive(
      snapshot(pending: PendingJob(kind: .update), error: .client(.network)))
    #expect(p.button == .retry)
    #expect(p.buttonEnabled)
    #expect(p.status == .error(.client(.network)))
  }

  @Test func APP_017_preDownloadDoesNotBlockLaunch() {
    let status = GameStatus(
      localVersion: "5.0.0", remoteVersion: "5.0.0", canPreDownload: true, preDownloadVersion: "5.1.0")
    let offer = MainPresentation.derive(snapshot(status: status))
    #expect(offer.button == .launch)
    #expect(offer.status == .preDownloadAvailable(version: "5.1.0"))

    let running = JobProgress.running(done: 1, total: 2)
    let active = MainPresentation.derive(
      snapshot(phase: .preDownloading, preDownloading: true, progress: running, status: status))
    #expect(active.button == .launch)
    #expect(active.buttonEnabled)
    #expect(active.status == .job(.preDownload, running, paused: false))
  }

  @Test func APP_017_aFailedPreDownloadKeepsItsRetryEntry() {
    let status = GameStatus(localVersion: "5.0.0", remoteVersion: "5.0.0", canPreDownload: true)
    let failed = MainPresentation.derive(
      snapshot(pending: PendingJob(kind: .preDownload), error: .client(.network), status: status))
    #expect(failed.button == .launch)
    #expect(failed.status == .error(.client(.network)))
    #expect(failed.canPreDownload)
    let running = MainPresentation.derive(
      snapshot(phase: .preDownloading, preDownloading: true, status: status))
    #expect(!running.canPreDownload)
    #expect(!MainPresentation.derive(snapshot()).canPreDownload)
  }

  @Test func APP_015_preDownloadStaysAvailableWhileTheGameStartsOrRuns() {
    let status = GameStatus(localVersion: "5.0.0", remoteVersion: "5.0.0", canPreDownload: true)
    for phase in [LauncherPhase.launching, .running] {
      #expect(MainPresentation.derive(snapshot(phase: phase, status: status)).canPreDownload)
    }
    for phase in [LauncherPhase.installing, .updating, .repairing] {
      #expect(!MainPresentation.derive(snapshot(phase: phase, status: status)).canPreDownload)
    }
  }

  @Test func APP_010_preDownloadIsNotOfferedOffline() {
    let status = GameStatus(localVersion: "5.0.0", remoteVersion: "5.0.0", canPreDownload: true)
    #expect(!MainPresentation.derive(snapshot(status: status, online: false)).canPreDownload)
  }

  @Test func APP_017_pendingPreDownloadIsNotAResumeOfTheMainButton() {
    let p = MainPresentation.derive(snapshot(pending: PendingJob(kind: .preDownload)))
    #expect(p.button == .launch)
  }

  @Test func APP_017_launchAndRunningAreDisabled() {
    let launching = MainPresentation.derive(snapshot(phase: .launching))
    #expect(launching.button == .launching)
    #expect(!launching.buttonEnabled)
    let running = MainPresentation.derive(snapshot(phase: .running))
    #expect(running.button == .running)
    #expect(!running.buttonEnabled)
  }

  @Test func APP_010_offlineDisablesLaunchAndUpdateButKeepsTheKnownState() {
    let offline = MainPresentation.derive(snapshot(online: false))
    #expect(offline.button == .launch)
    #expect(!offline.buttonEnabled)
    #expect(offline.status == .offline)
    let update = MainPresentation.derive(
      snapshot(status: GameStatus(localVersion: "5.0.0", remoteVersion: "5.1.0", canUpdate: true), online: false))
    #expect(!update.buttonEnabled)
  }

  @Test func APP_010_installIsDisabledWhileOfflineAndNothingIsKnown() {
    let loaded = MainPresentation.derive(snapshot(status: nil, online: false))
    #expect(loaded.button == .install)
    #expect(!loaded.buttonEnabled)
    #expect(loaded.status == .offline)
    var loading = snapshot(status: nil, online: false)
    loading.hasLoaded = false
    let first = MainPresentation.derive(loading)
    #expect(!first.buttonEnabled)
    #expect(first.status == .none, "no Offline claim before the first query returned")
  }

  @Test func APP_017_launchNeedsTheHostsBlocklist() {
    let p = MainPresentation.derive(snapshot(hostsOK: false))
    #expect(p.button == .launch)
    #expect(!p.buttonEnabled)
    #expect(p.status == .hostsRequired)
  }

  @Test func APP_017_launchFailureShowsTheErrorButKeepsLaunchEnabled() {
    let p = MainPresentation.derive(snapshot(error: .launchTimeout))
    #expect(p.button == .launch)
    #expect(p.buttonEnabled)
    #expect(p.status == .error(.launchTimeout))
  }

  @Test func APP_017_wineIsPreparedBeforeAnythingElse() {
    var s = snapshot(status: nil)
    s.wineNotReady = true
    let needed = MainPresentation.derive(s)
    #expect(needed.button == .prepareWine)
    #expect(needed.buttonEnabled)
    #expect(needed.status == .wineRequired)
    #expect(!needed.canRepair)

    let progress = JobProgress.wine(.extracting)
    let running = MainPresentation.derive(snapshot(phase: .preparingWine, progress: progress))
    #expect(running.button == .preparingWine)
    #expect(!running.buttonEnabled)
    #expect(running.status == .wine(progress))

    s.lastError = .wineInstall(.dxmtArchiveInvalid)
    #expect(MainPresentation.derive(s).status == .error(.wineInstall(.dxmtArchiveInvalid)))
  }

  @Test func PRG_005_wineDownloadsReportBytesLikeGameDownloads() {
    let download = JobProgress.wine(.downloadingWine(DownloadProgress(completed: 50, total: 200)))
    #expect(download.counts?.done == 50 && download.counts?.total == 200)
    #expect(download.fraction == 0.25)
    #expect(JobProgress.wine(.extracting).fraction == nil)
    #expect(JobProgress.wine(.downloadingDXMT(DownloadProgress(completed: 5, total: -1))).fraction == nil)
  }

  @Test func APP_017_menuActionsFollowTheState() {
    #expect(MainPresentation.derive(snapshot()).canRepair)
    #expect(!MainPresentation.derive(snapshot(status: nil)).canRepair)
    #expect(!MainPresentation.derive(snapshot(phase: .installing)).canRepair)
    #expect(!MainPresentation.derive(snapshot(phase: .running)).canRepair)
    let update = GameStatus(localVersion: "5.0.0", remoteVersion: "5.1.0", canUpdate: true)
    #expect(!MainPresentation.derive(snapshot(status: update)).canRepair)
  }
}

@Suite struct PRG_Presentation_Tests {
  @Test func PRG_002_speedIsMeasuredOverASlidingWindow() {
    var estimator = TransferEstimator(window: 10)
    #expect(estimator.bytesPerSecond == nil)
    estimator.record(done: 0, at: 0)
    #expect(estimator.bytesPerSecond == nil)
    estimator.record(done: 5_000, at: 5)
    #expect(estimator.bytesPerSecond == 1_000)
    estimator.record(done: 15_000, at: 15)
    // The sample at t=0 fell out of the window: (15000-5000)/(15-5).
    #expect(estimator.bytesPerSecond == 1_000)
    estimator.record(done: 35_000, at: 20)
    #expect(estimator.bytesPerSecond == 4_000)
  }

  @Test func PRG_002_remainingTimeAndZeroTotals() {
    var estimator = TransferEstimator(window: 10)
    estimator.record(done: 0, at: 0)
    estimator.record(done: 1_000, at: 1)
    #expect(estimator.remaining(done: 1_000, total: 11_000) == 10)
    #expect(estimator.remaining(done: 1_000, total: 0) == nil)
    var stalled = TransferEstimator(window: 10)
    stalled.record(done: 5, at: 0)
    stalled.record(done: 5, at: 4)
    #expect(stalled.remaining(done: 5, total: 100) == nil)
  }

  @Test func PRG_002_aNewPhaseResetsTheWindow() {
    var estimator = TransferEstimator(window: 10)
    estimator.record(done: 0, at: 0)
    estimator.record(done: 9_000, at: 3)
    estimator.record(done: 100, at: 4)  // counter went backwards: a new phase began
    #expect(estimator.bytesPerSecond == nil)
  }

  @Test func PRG_003_progressMapsToTheShownFraction() {
    #expect(JobProgress.preparing.fraction == nil)
    #expect(JobProgress.finalizing.fraction == nil)
    #expect(JobProgress.running(done: 50, total: 200).fraction == 0.25)
  }

  @Test func PRG_005_zeroAndUnknownProgressAreIndeterminate() {
    #expect(JobProgress.running(done: 0, total: 100).fraction == nil)
    #expect(JobProgress.running(done: 5, total: 0).fraction == nil)
    #expect(JobProgress.running(done: 500, total: 100).fraction == 1)
  }

  @Test func PRG_004_bytesAreIECWithOneDecimal() {
    #expect(ByteFormat.iec(5_242_880) == "5.0 MiB")
    #expect(ByteFormat.iec(1023) == "1023 B")
    #expect(ByteFormat.iec(0) == "0 B")
    #expect(ByteFormat.iec(1024) == "1.0 KiB")
    #expect(ByteFormat.iec(1_048_575) == "1.0 MiB")  // rounds up into the next unit
    #expect(ByteFormat.iec(3 << 30) == "3.0 GiB")
  }

  @Test func INS_004_shortfallIsShownInWholeGiBRoundedUp() {
    #expect(ByteFormat.wholeGiBRoundedUp(1) == 1)
    #expect(ByteFormat.wholeGiBRoundedUp(1 << 30) == 1)
    #expect(ByteFormat.wholeGiBRoundedUp((1 << 30) + 1) == 2)
    #expect(ByteFormat.wholeGiBRoundedUp(0) == 0)
  }
}

@MainActor @Suite struct ProgressMeterTests {
  @Test func PRG_002_meterReportsSpeedAndRemainingTime() {
    let now = Mutex(0.0)
    let meter = ProgressMeter(clock: { now.withLock { $0 } })
    meter.update(.running(done: 0, total: 10_240))
    now.withLock { $0 = 2 }
    meter.update(.running(done: 4_096, total: 10_240))
    #expect(meter.bytesPerSecond == 2_048)  // rounded to whole KiB/s
    #expect(meter.remaining == 3)
    meter.update(nil)
    #expect(meter.bytesPerSecond == nil && meter.remaining == nil)
  }
}
