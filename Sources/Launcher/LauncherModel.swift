import Foundation
import Observation
import Platform
import Synchronization
import Wine

/// What the launcher is doing right now. Pre-download is only reported while nothing exclusive runs;
/// `LauncherModel.isPreDownloading` tells whether it overlaps with launching or running.
public enum LauncherPhase: Sendable, Equatable {
  case idle, preparingWine, installing, updating, preDownloading, repairing, launching, running
}

public enum LauncherError: Error, Sendable, Equatable {
  case busy
  /// Wine is missing or damaged; prepare it first.
  case wineNotReady
  /// Wine preparation failed for a reason other than network, verification or disk space.
  case wineInstall(WineInstallError)
  case noGameDirectory
  case notInstalled
  case offline
  case updateRequired
  case pendingJob(GameJob)
  case preDownloadUnavailable
  case insufficientDiskSpace(required: Int64, available: Int64)
  case launchTimeout
  case gameExited(code: Int32, logPath: URL)
  case failedToLaunch
  case client(GameClientError)
  case unexpected(String)

  /// Bytes still missing for `insufficientDiskSpace`.
  public var shortfall: Int64? {
    if case .insufficientDiskSpace(let required, let available) = self { return max(0, required - available) }
    return nil
  }
}

/// Discrete events for system notifications. `@Observable` coalesces states, so it cannot drive them.
public enum JobEvent: Sendable, Equatable {
  case finished(GameJob)
  case failed(GameJob, LauncherError)
  case launchFailed(LauncherError)
  case wineReady
  case wineFailed(LauncherError)
}

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
  public private(set) var isOnline = false
  public private(set) var isPreDownloading = false
  public private(set) var isPausing = false
  public private(set) var progress: JobProgress?
  public private(set) var pendingJob: PendingJob?
  public private(set) var lastError: LauncherError?
  public var gameDirectory: URL? {
    didSet { if gameDirectory != oldValue { client.setGameDirectory(gameDirectory) } }
  }
  /// Snapshots the settings for a launch. The composition root replaces it with one that reads `SettingsModel`.
  public var makeLaunchOptions: @MainActor (URL) -> LaunchOptions = { LaunchOptions(gameDirectory: $0) }

  /// The exclusive slot; pre-download has its own flag.
  private var exclusive: LauncherPhase = .idle

  public var phase: LauncherPhase {
    if exclusive != .idle { return exclusive }
    return isPreDownloading ? .preDownloading : .idle
  }

  public var primaryAction: PrimaryAction {
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
  public static let defaultChunkTempMargin: Int64 = 2 << 30

  private let client: any GameClient
  private let wine: (any WinePreparing)?
  private let launchTimeout: Duration
  private let chunkTempMargin: Int64
  private let availableDiskSpace: @Sendable (URL) -> Int64?
  private let sleep: @Sendable (Duration) async throws -> Void

  private var exclusiveTask: Task<Void, Never>?
  private var preDownloadTask: Task<Void, Never>?
  private var launchGate: LaunchGate?
  private var isShuttingDown = false
  private var launchWork: Task<LaunchOutcome, Error>?
  private var statusRead: Task<Void, Never>?

  public init(
    client: any GameClient,
    wine: (any WinePreparing)? = nil,
    gameDirectory: URL? = nil,
    launchTimeout: Duration = LauncherModel.defaultLaunchTimeout,
    chunkTempMargin: Int64 = LauncherModel.defaultChunkTempMargin,
    availableDiskSpace: @escaping @Sendable (URL) -> Int64? = LauncherModel.systemAvailableCapacity,
    sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
  ) {
    self.client = client
    self.wine = wine
    self.gameDirectory = gameDirectory
    client.setGameDirectory(gameDirectory)
    self.launchTimeout = launchTimeout
    self.chunkTempMargin = chunkTempMargin
    self.availableDiskSpace = availableDiskSpace
    self.sleep = sleep
    (events, eventSink) = AsyncStream.makeStream()
  }

  /// Free bytes on the volume holding `url`, or on its nearest existing ancestor when it does not exist yet.
  nonisolated public static func systemAvailableCapacity(at url: URL) -> Int64? {
    var probe = url
    while !FileManager.default.fileExists(atPath: probe.path), probe.pathComponents.count > 1 {
      probe.deleteLastPathComponent()
    }
    let values = try? probe.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
    return values?.volumeAvailableCapacityForImportantUsage
  }

  // MARK: Status

  /// The startup sequence from ADR 0002, as far as this module owns it: Wine first, then the game status.
  /// A missing Wine is prepared here, so the game status is only read once Wine is ready; if the preparation
  /// is paused or fails, `bootstrap()` returns without reading it (`lastError` and `events` say why).
  public func bootstrap() async {
    guard exclusive == .idle, !isPausing, !isShuttingDown else { return }
    await refreshWine()
    guard isWineMissing else {
      await refresh()
      return
    }
    do {
      try await prepareWine()
    } catch {
      // Someone else (the user pressing "prepare Wine") got the slot while the status was being read.
      guard exclusive == .preparingWine else { return }
    }
    guard exclusive == .preparingWine, let task = exclusiveTask else { return }
    await task.value  // the preparation reads the game status itself once Wine is ready
  }

  /// Re-reads the Wine state from the disk. Without a `WinePreparing` the launcher assumes Wine is fine.
  public func refreshWine() async {
    guard let wine else { return }
    wineStatus = await wine.status()
  }

  /// A failed query keeps the previous status: offline must not turn an installed game into "install".
  public func refresh() async {
    do {
      let fresh = try await client.status()
      status = fresh
      isOnline = !(fresh.remoteVersion ?? "").isEmpty
    } catch {
      isOnline = false
    }
    if let store = store { pendingJob = store.load() }
  }

  private var store: PendingJobStore? {
    gameDirectory.map { PendingJobStore(gameDirectory: $0) }
  }

  // MARK: Jobs

  public func start(_ job: GameJob) async throws {
    guard !isPausing, !isShuttingDown else { throw LauncherError.busy }
    if job == .preDownload {
      try await startPreDownload()
    } else {
      try await startExclusive(job)
    }
  }

  private func startExclusive(_ job: GameJob) async throws {
    guard exclusive == .idle else { throw LauncherError.busy }
    guard !isWineNotReady else { throw LauncherError.wineNotReady }
    if job != .install {
      guard status?.localVersion != nil else { throw LauncherError.notInstalled }
    }
    if job == .repair, status?.canUpdate == true { throw LauncherError.updateRequired }
    guard let store else { throw LauncherError.noGameDirectory }
    exclusive = job.exclusivePhase  // claim before any await so nothing else can slip in
    lastError = nil
    // One Task covers preflight and the job, so pause()/shutdown() always find a handle to cancel and await.
    let (ready, readySink) = AsyncThrowingStream<Void, Error>.makeStream()
    exclusiveTask = Task {
      let stream: AsyncThrowingStream<JobProgress, Error>
      do {
        await stopPreDownload()
        try Task.checkCancellation()
        try await checkDiskSpace(for: job, in: store.gameDirectory)
        try Task.checkCancellation()
        stream = try begin(job, store: store)
      } catch {
        exclusive = .idle
        exclusiveTask = nil
        readySink.finish(throwing: error)
        return
      }
      readySink.finish()
      await drive(job, stream: stream, store: store)
    }
    do { for try await _ in ready {} } catch is CancellationError { return }  // paused before the job began
  }

  private func startPreDownload() async throws {
    guard exclusive == .idle || exclusive == .launching || exclusive == .running,
      !isPreDownloading
    else { throw LauncherError.busy }
    guard !isWineNotReady else { throw LauncherError.wineNotReady }
    guard status?.localVersion != nil else { throw LauncherError.notInstalled }
    guard status?.canPreDownload == true else { throw LauncherError.preDownloadUnavailable }
    guard let store else { throw LauncherError.noGameDirectory }
    isPreDownloading = true
    lastError = nil
    let (ready, readySink) = AsyncThrowingStream<Void, Error>.makeStream()
    preDownloadTask = Task {
      let stream: AsyncThrowingStream<JobProgress, Error>
      do {
        try await checkDiskSpace(for: .preDownload, in: store.gameDirectory)
        try Task.checkCancellation()
        // Starting install/update/repair during the check would have claimed the slot first.
        guard exclusive == .idle || exclusive == .launching || exclusive == .running else {
          throw LauncherError.busy
        }
        stream = try begin(.preDownload, store: store)
      } catch {
        isPreDownloading = false
        preDownloadTask = nil
        readySink.finish(throwing: error)
        return
      }
      readySink.finish()
      await drive(.preDownload, stream: stream, store: store)
    }
    do { for try await _ in ready {} } catch is CancellationError { return }
  }

  private func begin(_ job: GameJob, store: PendingJobStore) throws -> AsyncThrowingStream<JobProgress, Error> {
    let pending = PendingJob(kind: job, targetVersion: status?.remoteVersion)
    // A pre-download must not replace the marker of an unfinished install/update/repair: that one blocks launch.
    if job == .preDownload, let existing = store.load(), existing.kind != .preDownload {
      progress = .preparing
      return client.run(job)
    }
    // Without a marker an interrupted job could neither be continued nor block launching: refuse to start.
    do { try store.save(pending) } catch { throw LauncherError.unexpected("job.json could not be written") }
    pendingJob = pending
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
      let foreign = job == .preDownload && store.load().map { $0.kind != .preDownload } == true
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
    if job == .preDownload {
      isPreDownloading = false
      preDownloadTask = nil
    } else {
      exclusive = .idle
      exclusiveTask = nil
    }
  }

  /// Cancels the chosen slots' Tasks and returns once all of them have stopped.
  private func cancelAndWait(exclusive: Bool, preDownload: Bool) async {
    var tasks: [Task<Void, Never>] = []
    if exclusive { tasks += [exclusiveTask].compactMap { $0 } }
    if preDownload { tasks += [preDownloadTask].compactMap { $0 } }
    for task in tasks { task.cancel() }
    for task in tasks { await task.value }
  }

  private func stopPreDownload() async {
    await cancelAndWait(exclusive: false, preDownload: true)
  }

  private func checkDiskSpace(for job: GameJob, in directory: URL) async throws {
    let bytes: Int64
    do {
      bytes = try await client.requiredDiskSpace(for: job)
    } catch {
      if Task.isCancelled || error is CancellationError { throw CancellationError() }
      throw LauncherError(error)
    }
    guard bytes > 0 else { return }
    let required = bytes + chunkTempMargin
    if let available = availableDiskSpace(directory), available < required {
      throw LauncherError.insufficientDiskSpace(required: required, available: available)
    }
  }

  /// Cancels the running download job and waits until it has really stopped. `job.json` stays.
  public func pause() async {
    // Only download jobs are pausable; cancelling a launch Task alone would leave `await` hanging until the game exits.
    let pausable: Set<LauncherPhase> = [.preparingWine, .installing, .updating, .repairing]
    let exclusivePause = pausable.contains(exclusive)
    guard exclusivePause ? exclusiveTask != nil : preDownloadTask != nil else { return }
    isPausing = true
    await cancelAndWait(exclusive: exclusivePause, preDownload: !exclusivePause)
    isPausing = false
  }

  public func resume() async throws {
    if isWineMissing { return try await prepareWine() }
    guard let pendingJob else { return }
    try await start(pendingJob.kind)
  }

  /// App quit: cancel everything, wait for it to stop, keep `job.json`.
  public func shutdown() async {
    isShuttingDown = true  // before the first suspension, so nothing new can start while we wait
    launchWork?.cancel()
    statusRead?.cancel()
    await cancelAndWait(exclusive: true, preDownload: true)
  }

  // MARK: Wine

  /// Prepares Wine in the exclusive slot. Returns once the Task is running; a no-op when Wine is ready.
  /// Pause is cancel-and-await. The downloads keep their `.part` files, so calling this again resumes.
  public func prepareWine() async throws {
    guard !isPausing, !isShuttingDown, exclusive == .idle else { throw LauncherError.busy }
    guard let wine, wineStatus != .ready else { return }
    exclusive = .preparingWine  // claim before any await so nothing else can slip in
    lastError = nil
    progress = .preparing
    exclusiveTask = Task {
      await stopPreDownload()  // shares the launcher's cancel-and-await rule with install/update/repair
      await self.runWinePreparation(wine)
    }
  }

  private func runWinePreparation(_ wine: any WinePreparing) async {
    let activity = ProcessInfo.processInfo.beginActivity(
      options: [.userInitiated, .idleSystemSleepDisabled], reason: "Yaagl Wine preparation")
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
    let paused = Task.isCancelled || failure is CancellationError || error == .client(.cancelled)
    if paused {
      await refreshWine()  // not ready: the next attempt starts from the stamp and the `.part` files
    } else if let error {
      lastError = error
      await refreshWine()
      eventSink.yield(.wineFailed(error))
    } else {
      await refreshWine()
      if isWineMissing {
        let error = LauncherError.unexpected("Wine is still not ready after installation")
        lastError = error
        eventSink.yield(.wineFailed(error))
      } else {
        progress = .preparing
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
    exclusive = .idle
    exclusiveTask = nil
  }

  // MARK: Launch

  public func launch() async throws {
    guard exclusive == .idle, !isPausing, !isShuttingDown else { throw LauncherError.busy }
    guard !isWineNotReady else { throw LauncherError.wineNotReady }
    guard let status, status.localVersion != nil else { throw LauncherError.notInstalled }
    guard let gameDirectory else { throw LauncherError.noGameDirectory }
    if let kind = store?.load()?.kind, kind != .preDownload { throw LauncherError.pendingJob(kind) }
    guard isOnline else { throw LauncherError.offline }
    guard !status.canUpdate else { throw LauncherError.updateRequired }
    exclusive = .launching
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
    exclusiveTask = Task { await self.finishLaunch(work: work, watchdog: watchdog, gate: gate) }
  }

  private func noteStarted(_ gate: LaunchGate) {
    if launchGate === gate, exclusive == .launching { exclusive = .running }
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
    }
    launchGate = nil
    launchWork = nil
    exclusive = .idle
    exclusiveTask = nil
  }

  /// Test hook: returns once no job or launch Task is outstanding.
  func waitUntilIdle() async {
    while let task = exclusiveTask ?? preDownloadTask {
      await task.value
    }
  }
}

extension GameJob {
  fileprivate var exclusivePhase: LauncherPhase {
    switch self {
    case .install: .installing
    case .update: .updating
    case .repair: .repairing
    case .preDownload: .preDownloading
    }
  }
}

extension LauncherError {
  fileprivate init(_ error: Error) {
    if let error = error as? LauncherError {
      self = error
    } else if let error = error as? GameClientError {
      self = .client(error)
    } else if let error = error as? WineInstallError {
      if case .insufficientDiskSpace(let required, let available) = error {
        self = .insufficientDiskSpace(required: required, available: available)
      } else {
        self = .wineInstall(error)
      }
    } else if let error = error as? DownloadError {
      switch error {
      case .httpStatus: self = .client(.network)
      case .checksumMismatch: self = .client(.verificationFailed)
      }
    } else if let error = error as? URLError {
      self = error.code == .cancelled ? .client(.cancelled) : .client(.network)
    } else if error is CancellationError {
      self = .client(.cancelled)
    } else {
      self = .unexpected(String(describing: error))
    }
  }
}

/// Decides atomically between "game process appeared" and "launch timeout expired".
private final class LaunchGate: Sendable {
  private enum State { case waiting, started, expired }
  private let state = Mutex(State.waiting)

  /// True when the game process won the race against the timeout.
  func markStarted() -> Bool {
    state.withLock {
      if $0 == .waiting { $0 = .started }
      return $0 == .started
    }
  }

  /// True when the timeout won the race.
  func expire() -> Bool {
    state.withLock {
      guard $0 == .waiting else { return false }
      $0 = .expired
      return true
    }
  }

  var timedOut: Bool { state.withLock { $0 == .expired } }
}
