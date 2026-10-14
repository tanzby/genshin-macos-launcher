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
  public private(set) var progress: JobProgress? {
    didSet { meter.update(progress) }
  }
  /// Speed and time remaining of `progress`, for the capsule.
  public let meter = ProgressMeter()
  package private(set) var pendingJob: PendingJob?
  public private(set) var lastError: LauncherError?
  /// Read on every use, never copied: the app passes a closure over `SettingsModel`, so a folder picked a moment
  /// ago is the one the next operation sees. Tests with a fixed folder pass `gameDirectory:` instead.
  private var directorySource: @MainActor () -> URL?
  public package(set) var gameDirectory: URL? {
    get { directorySource() }
    set { directorySource = { newValue } }
  }
  /// Snapshots the settings for a launch. The composition root replaces it with one that reads `SettingsModel`.
  public var makeLaunchOptions: @MainActor (URL) -> LaunchOptions = { LaunchOptions(gameDirectory: $0) }

  private let jobs = JobCoordinator()

  package var isPreDownloading: Bool { jobs.isPreDownloading }
  package var phase: LauncherPhase { jobs.phase }

  package var primaryAction: PrimaryAction {
    isWineNotReady ? .prepareWine : PrimaryAction.derive(status)
  }

  /// The hosts blocklist is in place (or there is no hosts seam to ask). Without it the game must not start.
  package var hostsAllowLaunch: Bool {
    hosts?.allowsLaunch ?? true
  }

  /// Wine is known to need preparation.
  private var isWineMissing: Bool {
    if case .needsInstall = wineStatus { return true }
    return false
  }

  /// Gate for game jobs and launch: with a Wine seam, an unread status counts as not ready, so nothing
  /// slips in while the first `refreshWine()` is still suspended.
  package var isWineNotReady: Bool {
    wine != nil && wineStatus != .ready
  }

  @ObservationIgnored public let events: AsyncStream<JobEvent>
  @ObservationIgnored private let eventSink: AsyncStream<JobEvent>.Continuation

  /// Room for the chunk cache and files being assembled next to the finished ones.
  public static let defaultChunkTempMargin: Int64 = DiskSpaceCheck.defaultMargin

  private let client: any GameClient
  private let wine: (any WinePreparing)?
  private let hosts: HostsModel?
  private let startup: StartupSteps?
  private let diskSpace: DiskSpaceCheck

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

  public init(
    client: any GameClient,
    wine: (any WinePreparing)? = nil,
    hosts: HostsModel? = nil,
    startup: StartupSteps? = nil,
    gameDirectory: URL? = nil,
    gameDirectorySource: (@MainActor () -> URL?)? = nil,
    chunkTempMargin: Int64 = LauncherModel.defaultChunkTempMargin,
    availableDiskSpace: @escaping @Sendable (URL) -> Int64? = LauncherModel.systemAvailableCapacity
  ) {
    self.client = client
    self.wine = wine
    self.hosts = hosts
    self.startup = startup
    directorySource = gameDirectorySource ?? { gameDirectory }
    diskSpace = DiskSpaceCheck(margin: chunkTempMargin, availableSpace: availableDiskSpace)
    (events, eventSink) = AsyncStream.makeStream()
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
      try await startWinePreparation()
    } catch {
      // Someone else (the user pressing "prepare Wine") got the slot while the status was being read.
      guard jobs.exclusive == .preparingWine else { return }
    }
    guard jobs.exclusive == .preparingWine else { return }
    await jobs.waitForExclusive()  // the preparation reads the game status itself once Wine is ready
  }

  /// Re-reads the Wine state from the disk. Without a `WinePreparing` the launcher assumes Wine is fine.
  package func refreshWine() async {
    guard let wine else { return }
    let status = await wine.status()
    wineStatus = status
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
    refreshHosts()
    refreshGeneration += 1
    let generation = refreshGeneration
    do {
      let fresh = try await client.status(in: gameDirectory)
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
      if !error.isCancellation, failure != .client(.network) {
        lastError = failure
        refreshFailure = failure
      }
    }
    if let store = store { pendingJob = store.load() }
  }

  /// Re-reads `/etc/hosts` (no privileges needed) and drops a `hostsRequired` error the read resolved. An unreadable
  /// file counts as "not in place".
  package func refreshHosts() {
    guard let hosts else { return }
    hosts.refresh()
    if hostsAllowLaunch, lastError == .hostsRequired { lastError = nil }
  }

  private var store: PendingJobStore? {
    gameDirectory.map { PendingJobStore(gameDirectory: $0) }
  }

  // MARK: Availability

  /// Why `action` may not run now; nil = allowed. The one place that decides this: `start`, `launch`,
  /// `resume` and `prepareWine` guard through it, and the main window reads it for its buttons and status line.
  /// The disk-space check is not part of it: it needs the client and runs as a preflight of the job.
  package func refusal(for action: LauncherAction) -> LauncherError? {
    switch action {
    case .prepareWine: prepareWineRefusal
    case .start(let job): startRefusal(job)
    case .resume:
      if isWineMissing { prepareWineRefusal } else { pendingJob.flatMap { startRefusal($0.kind) } }
    case .launch: launchRefusal
    }
  }

  private var isBusyWithBookkeeping: Bool { isPausing || isShuttingDown || recovery != nil }

  private var prepareWineRefusal: LauncherError? {
    if isBusyWithBookkeeping || jobs.exclusive != .idle { return .busy }
    return isRosettaMissing ? .rosettaMissing : nil
  }

  private func startRefusal(_ job: GameJob) -> LauncherError? {
    if isBusyWithBookkeeping { return .busy }
    if job == .preDownload {
      if !jobs.allowsPreDownload || jobs.isPreDownloading { return .busy }
    } else if jobs.exclusive != .idle {
      return .busy
    }
    if isWineNotReady { return .wineNotReady }
    if job != .install, status?.localVersion == nil { return .notInstalled }
    switch job {
    case .repair:
      if let pending = pendingJob, pending.blocksLaunch, pending.kind != .repair { return .pendingJob(pending.kind) }
      if status?.canUpdate == true { return .updateRequired }
    case .preDownload:
      if !isOnline { return .offline }
      if status?.canPreDownload != true { return .preDownloadUnavailable }
    case .install, .update:
      break
    }
    // Every job downloads.
    if !isOnline { return .offline }
    return store == nil ? .noGameDirectory : nil
  }

  private var launchRefusal: LauncherError? {
    if isBusyWithBookkeeping || jobs.exclusive != .idle { return .busy }
    if isWineNotReady { return .wineNotReady }
    guard let status, status.localVersion != nil else { return .notInstalled }
    if gameDirectory == nil { return .noGameDirectory }
    if let pending = pendingJob, pending.blocksLaunch { return .pendingJob(pending.kind) }
    if !hostsAllowLaunch { return .hostsRequired }
    if !isOnline { return .offline }
    return status.canUpdate ? .updateRequired : nil
  }

  /// A refused start is an error the window shows like a failed job: one channel, `lastError`.
  private func recordingFailure<T>(_ work: () async throws -> T) async throws -> T {
    do {
      return try await work()
    } catch {
      if !error.isCancellation { lastError = LauncherError(error) }
      throw error
    }
  }

  // MARK: Jobs

  public func start(_ job: GameJob) async throws {
    try await recordingFailure { try await startJob(job) }
  }

  private func startJob(_ job: GameJob) async throws {
    if let refusal = refusal(for: .start(job)) { throw refusal }
    if job == .preDownload {
      try await startPreDownload()
    } else {
      try await startExclusive(job)
    }
  }

  private func startExclusive(_ job: GameJob) async throws {
    guard let store else { throw LauncherError.noGameDirectory }
    try await spawn(job, store: store) {
      await self.stopPreDownload()
      try Task.checkCancellation()
      try await self.checkDiskSpace(for: job, in: store.gameDirectory)
      try Task.checkCancellation()
    }
  }

  private func startPreDownload() async throws {
    guard let store else { throw LauncherError.noGameDirectory }
    try await spawn(.preDownload, store: store) {
      try await self.checkDiskSpace(for: .preDownload, in: store.gameDirectory)
      try Task.checkCancellation()
      // Starting install/update/repair during the check would have claimed the slot first.
      guard self.jobs.allowsPreDownload else { throw LauncherError.busy }
    }
  }

  /// Runs `preflight`, then the job, in one Task, so pause()/shutdown() always find a handle to cancel and
  /// await. Returns once the job has begun; a failed preflight frees the slot and throws.
  private func spawn(
    _ job: GameJob, store: PendingJobStore, preflight: @escaping () async throws -> Void
  ) async throws {
    lastError = nil
    let (ready, readySink) = AsyncThrowingStream<Void, Error>.makeStream()
    let body: @MainActor () async -> Void = {
      do {
        try await preflight()
        try self.begin(job, store: store)
      } catch {
        readySink.finish(throwing: error)
        return
      }
      readySink.finish()
      await self.drive(job, store: store)
    }
    if job == .preDownload { jobs.startPreDownload(body: body) } else { jobs.startExclusive(job.exclusivePhase, body: body) }
    do { for try await _ in ready {} } catch is CancellationError { return }  // paused before the job began
  }

  private func begin(_ job: GameJob, store: PendingJobStore) throws {
    let pending = PendingJob(kind: job, targetVersion: job == .preDownload ? status?.preDownloadTarget : status?.remoteVersion)
    // A pre-download must not replace the marker of an unfinished install/update/repair: that one blocks launch.
    if !Self.leavesMarkerAlone(job, store: store) {
      // Without a marker an interrupted job could neither be continued nor block launching: refuse to start.
      do { try store.save(pending) } catch { throw LauncherError.unexpected("job.json could not be written") }
      pendingJob = pending
    }
    progress = .preparing
  }

  /// Runs the job in this (the slot's) Task, so cancelling the slot cancels the work and awaiting the slot waits for it.
  private func drive(_ job: GameJob, store: PendingJobStore) async {
    let activity = ProcessInfo.processInfo.beginActivity(
      options: [.userInitiated, .idleSystemSleepDisabled], reason: "Genshin Launcher game job")
    // Progress arrives on worker threads. One ordered stream brings it to the main actor, and it ends when the job
    // returns, so no late update can land after the final state below.
    let (updates, sink) = AsyncStream<JobProgress>.makeStream(bufferingPolicy: .bufferingNewest(1))
    async let outcome = Self.run(job, client: client, in: store.gameDirectory, progress: sink)
    for await update in updates { progress = update }
    let failure = await outcome
    let paused = Task.isCancelled || failure?.isCancellation == true
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
  }

  /// The job's error, `nil` when it finished. Ends `progress` either way.
  private nonisolated static func run(
    _ job: GameJob, client: any GameClient, in directory: URL, progress: AsyncStream<JobProgress>.Continuation
  ) async -> (any Error)? {
    defer { progress.finish() }
    do {
      try await client.run(job, in: directory) { progress.yield($0) }
      return nil
    } catch {
      return error
    }
  }

  /// A pre-download running beside an unfinished install/update/repair neither writes nor clears its marker.
  private static func leavesMarkerAlone(_ job: GameJob, store: PendingJobStore) -> Bool {
    job == .preDownload && store.load()?.blocksLaunch == true
  }

  private func stopPreDownload() async {
    await jobs.cancelAndWait(exclusive: false, preDownload: true)
  }

  private func checkDiskSpace(for job: GameJob, in directory: URL) async throws {
    let bytes: Int64
    do {
      bytes = try await client.requiredDiskSpace(for: job, in: directory)
    } catch {
      if Task.isCancelled || error.isCancellation { throw CancellationError() }
      throw LauncherError(error)
    }
    try diskSpace.verify(required: bytes, in: directory)
  }

  /// Cancels the running download job and waits until it has really stopped. `job.json` stays.
  public func pause() async {
    // Only download jobs are pausable; cancelling a launch Task alone would leave `await` hanging until the game exits.
    let pausable: Set<LauncherPhase> = [.preparingWine, .installing, .updating, .repairing]
    let exclusivePause = pausable.contains(jobs.exclusive)
    guard jobs.isHolding(exclusive: exclusivePause) else { return }
    isPausing = true
    await jobs.cancelAndWait(exclusive: exclusivePause, preDownload: !exclusivePause)
    isPausing = false
  }

  public func resume() async throws {
    try await recordingFailure {
      if let refusal = refusal(for: .resume) { throw refusal }
      if isWineMissing { return try await startWinePreparation() }
      guard let pendingJob else { return }
      try await startJob(pendingJob.kind)
    }
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
    await jobs.cancelAndWait(exclusive: true, preDownload: true)
    // The recovery is cleanup (kills the prefix, replays the journal): never cancel it, but do not quit mid-way.
    await recovery?.value
  }

  // MARK: Wine

  /// Prepares Wine in the exclusive slot. Returns once the Task is running; a no-op when Wine is ready.
  /// Pause is cancel-and-await. The downloads keep their `.part` files, so calling this again resumes.
  public func prepareWine() async throws {
    try await recordingFailure { try await startWinePreparation() }
  }

  private func startWinePreparation() async throws {
    // Pressed before `bootstrap()` got to the Rosetta check: do it here, the 2 GB download must not come first.
    if !hasBootstrapped, !(await rosettaIsAvailable()) { throw LauncherError.rosettaMissing }
    if let refusal = refusal(for: .prepareWine) { throw refusal }
    guard let wine, wineStatus != .ready else { return }
    lastError = nil
    progress = .preparing
    jobs.startExclusive(.preparingWine) {
      await self.stopPreDownload()  // shares the launcher's cancel-and-await rule with install/update/repair
      await self.runWinePreparation(wine)
    }
  }

  private func runWinePreparation(_ wine: any WinePreparing) async {
    let activity = ProcessInfo.processInfo.beginActivity(
      options: [.userInitiated, .idleSystemSleepDisabled], reason: "Genshin Launcher Wine preparation")
    let (updates, sink) = AsyncStream<WineInstallProgress>.makeStream(bufferingPolicy: .bufferingNewest(1))  // only the latest progress matters
    var failure: Error?
    // A task group, so cancelling this Task cancels the install; `updates` ends when the install returns.
    await withTaskGroup(of: (any Error)?.self) { group in
      group.addTask {
        defer { sink.finish() }
        do {
          try Task.checkCancellation()  // paused while waiting for a pre-download: do not begin the install
          try await wine.ensureInstalled { sink.yield($0) }
          return nil
        } catch {
          return error
        }
      }
      for await update in updates { progress = .wine(update) }
      failure = await group.next() ?? nil
    }
    let error = failure.map(LauncherError.init)
    let paused = Task.isCancelled || failure?.isCancellation == true
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
    try await recordingFailure { try startLaunch() }
  }

  private func startLaunch() throws {
    // The disk and /etc/hosts can change under the window: look again right before the game starts.
    if let store { pendingJob = store.load() }
    refreshHosts()
    if let refusal = refusal(for: .launch) { throw refusal }
    guard let gameDirectory else { throw LauncherError.noGameDirectory }
    lastError = nil
    let client = client
    let options = makeLaunchOptions(gameDirectory)
    // The client owns the startup timeout (`GameSession`); this callback only moves launching → running.
    let onStarted: @Sendable () -> Void = { [weak self] in
      Task { @MainActor in self?.noteStarted() }
    }
    let work = Task { try await client.launch(options, onStarted: onStarted) }
    launchWork = work
    jobs.startExclusive(.launching) { await self.finishLaunch(work: work) }
  }

  private func noteStarted() {
    if launchWork != nil { jobs.markRunning() }
  }

  private func finishLaunch(work: Task<LaunchOutcome, Error>) async {
    let result = await work.result
    let failure: LauncherError?
    switch result {
    case .success(.exited): failure = nil
    case .success(.failedExit(let code, let logPath)): failure = .gameExited(code: code, logPath: logPath)
    case .success(.startupTimedOut): failure = .launchTimeout
    case .success(.failedToLaunch): failure = .failedToLaunch
    case .failure(let error):
      failure = error.isCancellation ? nil : LauncherError(error)
    }
    if let failure {
      lastError = failure
      eventSink.yield(.launchFailed(failure))
      // Wine's own status is the only judge: if the failure came from a damaged Wine, the main button goes back to "prepare Wine".
      await refreshWine()
    }
    launchWork = nil
  }

  /// Test hook: returns once no job or launch Task is outstanding.
  func waitUntilIdle() async { await jobs.waitUntilIdle() }
}
