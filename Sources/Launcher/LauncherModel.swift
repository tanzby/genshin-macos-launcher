import Foundation
import Observation
import Platform
import Wine

/// Single source of truth for the main window, and the job coordinator (ADR 0002).
///
/// Exclusive work (Wine preparation, install, update, repair, launch) runs one at a time. Pre-download only
/// writes the temporary directory, so it may overlap with launching and running, but starting Wine preparation,
/// install, update or repair first cancels it and waits for it to stop. Pause is cancel-and-await; resuming reruns the same idempotent job.
///
/// Wine preparation is not a Pending Job: it writes no `job.json`. Its state is whatever the Wine runtime's
/// version stamp says, so `wineStatus` is re-read from `WinePreparing.status()` and a paused or failed
/// preparation simply leaves `wineStatus` at `.needsInstall` for the next attempt.
@MainActor @Observable
public final class LauncherModel {
  public private(set) var status: GameStatus?
  public private(set) var wineStatus: WineStatus?
  /// `bootstrap()` got past the Rosetta check. The window runs it again until this is true.
  package private(set) var hasBootstrapped = false
  package private(set) var isRosettaMissing = false
  package private(set) var isOnline = false
  public private(set) var isPausing = false
  public private(set) var progress: JobProgress?
  package private(set) var pendingJob: PendingJob?
  public private(set) var lastError: LauncherError?
  public var gameDirectory: URL?
  /// Snapshots the settings for a launch. The composition root replaces it with one that reads `SettingsModel`.
  public var makeLaunchOptions: @MainActor (URL) -> LaunchOptions = { LaunchOptions(gameDirectory: $0) }

  private let jobs = JobCoordinator()

  package var isPreDownloading: Bool { jobs.isPreDownloading }
  package var phase: LauncherPhase { jobs.phase }

  package var primaryAction: PrimaryAction {
    isWineNotReady ? .prepareWine : PrimaryAction.derive(status)
  }

  /// Wine is known to need preparation.
  private var isWineMissing: Bool {
    if case .needsInstall = wineStatus { return true }
    return false
  }

  /// Gate for game jobs and launch: with a Wine seam, an unread status counts as not ready, so nothing
  /// slips in while the first `refreshWine()` is still suspended.
  private var isWineNotReady: Bool {
    wine != nil && wineStatus != .ready
  }

  @ObservationIgnored public let events: AsyncStream<JobEvent>
  @ObservationIgnored private let eventSink: AsyncStream<JobEvent>.Continuation

  public static let defaultLaunchTimeout: Duration = .seconds(120)
  /// Room for the chunk cache and files being assembled next to the finished ones.
  public static let defaultChunkTempMargin: Int64 = DiskSpaceCheck.defaultMargin

  private let client: any GameClient
  private let wine: (any WinePreparing)?
  private let startup: StartupSteps?
  private let launchTimeout: Duration
  private let diskSpace: DiskSpaceCheck
  private let sleep: @Sendable (Duration) async throws -> Void

  private var launchGate: LaunchGate?
  private var isShuttingDown = false
  private var launchWork: Task<LaunchOutcome, Error>?
  private var statusRead: Task<Void, Never>?
  /// The error the last `refresh()` put into `lastError`, so a later good refresh can take it away again.
  private var refreshFailure: LauncherError?
  /// Numbers the `refresh()` calls, and the newest call whose status was published: an answer older than
  /// that is stale and dropped.
  private var refreshGeneration = 0
  private var publishedGeneration = 0
  /// `GameSession.recover()` has run in this process; it must not run again while a game may be running.
  private var hasRecovered = false
  private var recovery: Task<Void, Never>?
  /// The game launch found Wine broken although the stamp says ready; only a reinstall clears it.
  private var needsForcedReinstall = false

  public init(
    client: any GameClient,
    wine: (any WinePreparing)? = nil,
    startup: StartupSteps? = nil,
    gameDirectory: URL? = nil,
    launchTimeout: Duration = LauncherModel.defaultLaunchTimeout,
    chunkTempMargin: Int64 = LauncherModel.defaultChunkTempMargin,
    availableDiskSpace: @escaping @Sendable (URL) -> Int64? = LauncherModel.systemAvailableCapacity,
    sleep: @escaping @Sendable (Duration) async throws -> Void = LauncherModel.defaultSleep
  ) {
    self.client = client
    self.wine = wine
    self.startup = startup
    self.gameDirectory = gameDirectory
    self.launchTimeout = launchTimeout
    diskSpace = DiskSpaceCheck(margin: chunkTempMargin, availableSpace: availableDiskSpace)
    self.sleep = sleep
    (events, eventSink) = AsyncStream.makeStream()
  }

  /// A named function, not a closure literal in the default argument: with a closure literal there,
  /// Xcode 26.6's runtime trapped ("freed pointer was not the last allocation") in suites that build a
  /// `LauncherModel` without passing `sleep` (issue #48).
  nonisolated public static func defaultSleep(_ duration: Duration) async throws {
    try await Task.sleep(for: duration)
  }

  /// Free bytes on the volume holding `url`, or on its nearest existing ancestor when it does not exist yet.
  nonisolated public static func systemAvailableCapacity(at url: URL) -> Int64? {
    DiskSpaceCheck.systemAvailableCapacity(at: url)
  }

  // MARK: Status

  /// The startup sequence from ADR 0002, as far as this module owns it: Rosetta, Wine, recovery, game status.
  /// Without Rosetta it stops before any Wine work (`lastError == .rosettaMissing`); call it again to retry.
  /// A missing Wine is prepared here, so recovery and the game status only come once Wine is ready; if the
  /// preparation is paused or fails, `bootstrap()` returns without them (`lastError` and `events` say why).
  public func bootstrap() async {
    guard jobs.exclusive == .idle, !isPausing, !isShuttingDown else { return }
    guard await rosettaIsAvailable() else { return }
    hasBootstrapped = true
    await refreshWine()
    guard isWineMissing else {
      await recoverOnce()
      await refresh()
      return
    }
    do {
      try await prepareWine()
    } catch {
      // Someone else (the user pressing "prepare Wine") got the slot while the status was being read.
      guard jobs.exclusive == .preparingWine else { return }
    }
    guard jobs.exclusive == .preparingWine, let task = jobs.exclusiveTask else { return }
    await task.value  // the preparation reads the game status itself once Wine is ready
  }

  /// Re-reads the Wine state from the disk. Without a `WinePreparing` the launcher assumes Wine is fine.
  package func refreshWine() async {
    guard let wine else { return }
    let status = await wine.status()
    // A launch that found Wine broken outranks the stamp: only a successful reinstall clears the request.
    wineStatus = needsForcedReinstall && status == .ready ? Self.reportedByLaunch : status
  }

  /// Re-checks Rosetta (when there is a check to make) and records the result. False: `lastError` says why.
  private func rosettaIsAvailable() async -> Bool {
    guard let startup else { return true }
    isRosettaMissing = !(await startup.rosettaInstalled())
    if isRosettaMissing {
      lastError = .rosettaMissing
    } else if lastError == .rosettaMissing {
      lastError = nil
    }
    return !isRosettaMissing
  }

  /// The game launch found Wine broken although the stamp says ready: Wine counts as missing until a
  /// reinstall succeeds, and the main button goes back to "prepare Wine".
  func requireWineReinstall() {
    needsForcedReinstall = true
    wineStatus = Self.reportedByLaunch
  }

  private static let reportedByLaunch = WineStatus.needsInstall(.corrupt(missing: "reported by the game launch"))

  /// Runs `recover()` once per process. Overlapping callers share the one running recovery and all wait for
  /// it; it counts as done only after it has returned, so nothing reads the game state before. While it runs
  /// every job and launch entry answers `busy` (it kills the prefix and rewrites game files).
  private func recoverOnce() async {
    guard !hasRecovered, let startup else { return }
    let task = recovery ?? Task { await startup.recoverSession() }
    recovery = task
    await task.value
    hasRecovered = true
    recovery = nil
  }

  /// A failed query keeps the previous status: offline must not turn an installed game into "install".
  /// A slow answer about an older directory or state must not overwrite a newer one.
  public func refresh() async {
    refreshGeneration += 1
    let generation = refreshGeneration
    client.setGameDirectory(gameDirectory)
    do {
      let fresh = try await client.status()
      guard generation > publishedGeneration else { return }
      publishedGeneration = generation
      status = fresh
      isOnline = !(fresh.remoteVersion ?? "").isEmpty
      if refreshFailure != nil, lastError == refreshFailure { lastError = nil }
      refreshFailure = nil
    } catch {
      guard generation > publishedGeneration else { return }
      isOnline = false
      // Offline is a state of its own; anything else (a broken install) needs to be seen.
      let failure = LauncherError(error)
      if failure != .client(.network), failure != .client(.cancelled) {
        lastError = failure
        refreshFailure = failure
      }
    }
    if let store = store { pendingJob = store.load() }
  }

  private var store: PendingJobStore? {
    gameDirectory.map { PendingJobStore(gameDirectory: $0) }
  }

  // MARK: Jobs

  public func start(_ job: GameJob) async throws {
    guard !isPausing, !isShuttingDown, recovery == nil else { throw LauncherError.busy }
    if job == .preDownload {
      try await startPreDownload()
    } else {
      try await startExclusive(job)
    }
  }

  private func startExclusive(_ job: GameJob) async throws {
    guard jobs.exclusive == .idle else { throw LauncherError.busy }
    guard !isWineNotReady else { throw LauncherError.wineNotReady }
    if job != .install {
      guard status?.localVersion != nil else { throw LauncherError.notInstalled }
    }
    if job == .repair, status?.canUpdate == true { throw LauncherError.updateRequired }
    guard let store else { throw LauncherError.noGameDirectory }
    jobs.claim(job.exclusivePhase)  // claim before any await so nothing else can slip in
    try await spawn(job, store: store, preDownload: false) {
      await self.stopPreDownload()
      try Task.checkCancellation()
      try await self.checkDiskSpace(for: job, in: store.gameDirectory)
      try Task.checkCancellation()
    }
  }

  private func startPreDownload() async throws {
    guard jobs.allowsPreDownload, !jobs.isPreDownloading else { throw LauncherError.busy }
    guard !isWineNotReady else { throw LauncherError.wineNotReady }
    guard status?.localVersion != nil else { throw LauncherError.notInstalled }
    guard status?.canPreDownload == true else { throw LauncherError.preDownloadUnavailable }
    guard let store else { throw LauncherError.noGameDirectory }
    jobs.claimPreDownload()
    try await spawn(.preDownload, store: store, preDownload: true) {
      try await self.checkDiskSpace(for: .preDownload, in: store.gameDirectory)
      try Task.checkCancellation()
      // Starting install/update/repair during the check would have claimed the slot first.
      guard self.jobs.allowsPreDownload else { throw LauncherError.busy }
    }
  }

  /// Runs `preflight`, then the job, in one Task, so pause()/shutdown() always find a handle to cancel and
  /// await. Returns once the job has begun; a failed preflight releases the slot and throws.
  private func spawn(
    _ job: GameJob, store: PendingJobStore, preDownload: Bool, preflight: @escaping () async throws -> Void
  ) async throws {
    lastError = nil
    let (ready, readySink) = AsyncThrowingStream<Void, Error>.makeStream()
    let task = Task {
      let stream: AsyncThrowingStream<JobProgress, Error>
      do {
        try await preflight()
        stream = try self.begin(job, store: store)
      } catch {
        self.jobs.release(preDownload: preDownload)
        readySink.finish(throwing: error)
        return
      }
      readySink.finish()
      await self.drive(job, stream: stream, store: store)
    }
    if preDownload { jobs.preDownloadTask = task } else { jobs.exclusiveTask = task }
    do { for try await _ in ready {} } catch is CancellationError { return }  // paused before the job began
  }

  private func begin(_ job: GameJob, store: PendingJobStore) throws -> AsyncThrowingStream<JobProgress, Error> {
    client.setGameDirectory(store.gameDirectory)
    let pending = PendingJob(kind: job, targetVersion: job == .preDownload ? status?.preDownloadTarget : status?.remoteVersion)
    // A pre-download must not replace the marker of an unfinished install/update/repair: that one blocks launch.
    if !Self.leavesMarkerAlone(job, store: store) {
      // Without a marker an interrupted job could neither be continued nor block launching: refuse to start.
      do { try store.save(pending) } catch { throw LauncherError.unexpected("job.json could not be written") }
      pendingJob = pending
    }
    progress = .preparing
    return client.run(job)
  }

  private func drive(
    _ job: GameJob, stream: AsyncThrowingStream<JobProgress, Error>, store: PendingJobStore
  ) async {
    let activity = ProcessInfo.processInfo.beginActivity(
      options: [.userInitiated, .idleSystemSleepDisabled], reason: "Yaagl game job")
    var failure: Error?
    do {
      for try await update in stream { progress = update }
    } catch {
      failure = error
    }
    // An AsyncThrowingStream iteration may end normally on cancellation, so classify by cancellation state.
    let paused = Task.isCancelled || failure is CancellationError || (failure as? GameClientError) == .cancelled
    if paused {
      // Keep job.json: the job is resumable.
    } else if let failure {
      let error = LauncherError(failure)
      lastError = error
      eventSink.yield(.failed(job, error))
    } else {
      // A finished pre-download leaves an unfinished install/update/repair marker alone.
      let foreign = Self.leavesMarkerAlone(job, store: store)
      let cleared = foreign || store.clear()
      if !foreign { pendingJob = nil }
      await refresh()
      if cleared {
        eventSink.yield(.finished(job))
      } else {
        // The job is done, but the stale marker would keep blocking launch; surface it instead of hiding it.
        let error = LauncherError.unexpected("job.json could not be removed")
        lastError = error
        eventSink.yield(.failed(job, error))
      }
    }
    ProcessInfo.processInfo.endActivity(activity)
    progress = nil
    jobs.release(preDownload: job == .preDownload)
  }

  /// A pre-download running beside an unfinished install/update/repair neither writes nor clears its marker.
  private static func leavesMarkerAlone(_ job: GameJob, store: PendingJobStore) -> Bool {
    job == .preDownload && store.load()?.blocksLaunch == true
  }

  /// Cancels the chosen slots' Tasks, returns once all of them have stopped and the client is quiet.
  private func cancelAndWait(exclusive: Bool, preDownload: Bool) async {
    await jobs.cancelAndWait(exclusive: exclusive, preDownload: preDownload)
    // The streams are over, but the work behind them may still be finishing a file.
    await client.quiesce()
  }

  private func stopPreDownload() async {
    await cancelAndWait(exclusive: false, preDownload: true)
  }

  private func checkDiskSpace(for job: GameJob, in directory: URL) async throws {
    let bytes: Int64
    do {
      client.setGameDirectory(directory)
      bytes = try await client.requiredDiskSpace(for: job)
    } catch {
      if Task.isCancelled || error is CancellationError { throw CancellationError() }
      throw LauncherError(error)
    }
    try diskSpace.verify(required: bytes, in: directory)
  }

  /// Cancels the running download job and waits until it has really stopped. `job.json` stays.
  public func pause() async {
    // Only download jobs are pausable; cancelling a launch Task alone would leave `await` hanging until the game exits.
    let pausable: Set<LauncherPhase> = [.preparingWine, .installing, .updating, .repairing]
    let exclusivePause = pausable.contains(jobs.exclusive)
    guard exclusivePause ? jobs.exclusiveTask != nil : jobs.preDownloadTask != nil else { return }
    isPausing = true
    await cancelAndWait(exclusive: exclusivePause, preDownload: !exclusivePause)
    isPausing = false
  }

  public func resume() async throws {
    if isWineMissing { return try await prepareWine() }
    guard let pendingJob else { return }
    try await start(pendingJob.kind)
  }

  /// What quitting has to do first (APP-022). A pure function of the phase, so asking twice gives the same answer.
  public enum QuitPlan: Sendable, Equatable {
    /// Nothing is running.
    case quitNow
    /// A job or Wine preparation is running: `shutdown()` stops it, keeping `job.json`.
    case shutDownFirst
    /// The game is running: quitting closes it, so the user is asked first.
    case confirmThenShutDown
  }

  public var quitPlan: QuitPlan {
    switch phase {
    case .idle: .quitNow
    case .running: .confirmThenShutDown
    case .preparingWine, .installing, .updating, .preDownloading, .repairing, .launching: .shutDownFirst
    }
  }

  /// App quit: cancel everything, wait for it to stop, keep `job.json`.
  public func shutdown() async {
    isShuttingDown = true  // before the first suspension, so nothing new can start while we wait
    launchWork?.cancel()
    statusRead?.cancel()
    await cancelAndWait(exclusive: true, preDownload: true)
    // The recovery is cleanup (kills the prefix, replays the journal): never cancel it, but do not quit mid-way.
    await recovery?.value
  }

  // MARK: Wine

  /// Prepares Wine in the exclusive slot. Returns once the Task is running; a no-op when Wine is ready.
  /// Pause is cancel-and-await. The downloads keep their `.part` files, so calling this again resumes.
  public func prepareWine() async throws {
    // Pressed before `bootstrap()` got to the Rosetta check: do it here, the 2 GB download must not come first.
    if !hasBootstrapped, !(await rosettaIsAvailable()) { throw LauncherError.rosettaMissing }
    guard !isPausing, !isShuttingDown, jobs.exclusive == .idle, recovery == nil else { throw LauncherError.busy }
    guard !isRosettaMissing else { throw LauncherError.rosettaMissing }
    guard let wine, wineStatus != .ready else { return }
    jobs.claim(.preparingWine)  // claim before any await so nothing else can slip in
    lastError = nil
    progress = .preparing
    jobs.exclusiveTask = Task {
      await self.stopPreDownload()  // shares the launcher's cancel-and-await rule with install/update/repair
      await self.runWinePreparation(wine)
    }
  }

  private func runWinePreparation(_ wine: any WinePreparing) async {
    let activity = ProcessInfo.processInfo.beginActivity(
      options: [.userInitiated, .idleSystemSleepDisabled], reason: "Yaagl Wine preparation")
    let (updates, sink) = AsyncStream<WineInstallProgress>.makeStream(bufferingPolicy: .bufferingNewest(1))  // only the latest progress matters
    var failure: Error?
    let forced = needsForcedReinstall
    // A task group, so cancelling this Task cancels the install; `updates` ends when the install returns.
    await withTaskGroup(of: (any Error)?.self) { group in
      group.addTask {
        defer { sink.finish() }
        do {
          try Task.checkCancellation()  // paused while waiting for a pre-download: do not begin the install
          if forced {
            try await wine.reinstall { sink.yield($0) }
          } else {
            try await wine.ensureInstalled { sink.yield($0) }
          }
          return nil
        } catch {
          return error
        }
      }
      for await update in updates { progress = .wine(update) }
      failure = await group.next() ?? nil
    }
    let error = failure.map(LauncherError.init)
    let paused = Task.isCancelled || failure is CancellationError || error == .client(.cancelled)
    if failure == nil { needsForcedReinstall = false }
    await refreshWine()  // after a pause or failure still not ready: the next attempt starts from the stamp and the `.part` files
    if !paused {
      let failed = error ?? (isWineMissing ? .unexpected("Wine is still not ready after installation") : nil)
      if let failed {
        lastError = failed
        eventSink.yield(.wineFailed(failed))
      } else {
        progress = .preparing
        await recoverOnce()
        // The game status is only read once Wine is ready. Wine is installed by now, so a pause must not
        // cancel this read (it would leave `status` nil and offer "install"); only shutdown does.
        if !isShuttingDown {
          let read = Task { await self.refresh() }
          statusRead = read
          await read.value
          statusRead = nil
        }
        eventSink.yield(.wineReady)
      }
    }
    ProcessInfo.processInfo.endActivity(activity)
    progress = nil
    jobs.release(preDownload: false)
  }

  // MARK: Launch

  /// A Wine command prompt needs a game folder (its path goes into `WINEPATH`) and an installed Wine.
  public var canOpenWineCommandPrompt: Bool { gameDirectory != nil && !isWineNotReady }

  /// Developer convenience (CFG-032, WIN-022). Independent of the launch slot: it touches no game files.
  public func openWineCommandPrompt() async {
    guard canOpenWineCommandPrompt, let gameDirectory else { return }
    await client.openWineCommandPrompt(makeLaunchOptions(gameDirectory))
  }

  public func launch() async throws {
    client.setGameDirectory(gameDirectory)
    guard jobs.exclusive == .idle, !isPausing, !isShuttingDown, recovery == nil else { throw LauncherError.busy }
    guard !isWineNotReady else { throw LauncherError.wineNotReady }
    guard let status, status.localVersion != nil else { throw LauncherError.notInstalled }
    guard let gameDirectory else { throw LauncherError.noGameDirectory }
    if let pending = store?.load(), pending.blocksLaunch { throw LauncherError.pendingJob(pending.kind) }
    guard isOnline else { throw LauncherError.offline }
    guard !status.canUpdate else { throw LauncherError.updateRequired }
    jobs.claim(.launching)
    lastError = nil
    let gate = LaunchGate()
    launchGate = gate
    let client = client
    let options = makeLaunchOptions(gameDirectory)
    let onStarted: @Sendable () -> Void = { [weak self] in
      // Only the callback that beats the timeout may switch the phase to running.
      guard gate.markStarted() else { return }
      Task { @MainActor in self?.noteStarted(gate) }
    }
    let work = Task { try await client.launch(options, onStarted: onStarted) }
    launchWork = work
    let timeout = launchTimeout
    let sleep = sleep
    let watchdog = Task {
      try? await sleep(timeout)
      if !Task.isCancelled, gate.expire() { work.cancel() }
    }
    jobs.exclusiveTask = Task { await self.finishLaunch(work: work, watchdog: watchdog, gate: gate) }
  }

  private func noteStarted(_ gate: LaunchGate) {
    if launchGate === gate { jobs.markRunning() }
  }

  private func finishLaunch(
    work: Task<LaunchOutcome, Error>, watchdog: Task<Void, Never>, gate: LaunchGate
  ) async {
    let result = await work.result
    watchdog.cancel()
    let failure: LauncherError?
    if gate.timedOut {
      failure = .launchTimeout
    } else {
      switch result {
      case .success(.exited): failure = nil
      case .success(.failedExit(let code, let logPath)): failure = .gameExited(code: code, logPath: logPath)
      case .success(.failedToLaunch): failure = .failedToLaunch
      case .failure(let error):
        let mapped = LauncherError(error)
        failure = mapped == .client(.cancelled) ? nil : mapped
      }
    }
    if let failure {
      lastError = failure
      eventSink.yield(.launchFailed(failure))
      if failure == .client(.wineReinstallRequired) { requireWineReinstall() }
    }
    launchGate = nil
    launchWork = nil
    jobs.release(preDownload: false)
  }

  /// Test hook: returns once no job or launch Task is outstanding.
  func waitUntilIdle() async { await jobs.waitUntilIdle() }
}
