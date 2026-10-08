import Foundation
import Observation
import Synchronization

/// What the launcher is doing right now. Pre-download is only reported while nothing exclusive runs;
/// `LauncherModel.isPreDownloading` tells whether it overlaps with launching or running.
public enum LauncherPhase: Sendable, Equatable {
  case idle, installing, updating, preDownloading, repairing, launching, running
}

public enum LauncherError: Error, Sendable, Equatable {
  case busy
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
}

/// Single source of truth for the main window, and the job coordinator (ADR 0002).
///
/// Exclusive work (install, update, repair, launch) runs one at a time. Pre-download only writes the temporary
/// directory, so it may overlap with launching and running, but starting install, update or repair first
/// cancels it and waits for it to stop. Pause is cancel-and-await; resuming reruns the same idempotent job.
@MainActor @Observable
public final class LauncherModel {
  public private(set) var status: GameStatus?
  public private(set) var isOnline = false
  public private(set) var isPreDownloading = false
  public private(set) var isPausing = false
  public private(set) var progress: JobProgress?
  public private(set) var pendingJob: PendingJob?
  public private(set) var lastError: LauncherError?
  public var gameDirectory: URL?

  /// The exclusive slot; pre-download has its own flag.
  private var exclusive: LauncherPhase = .idle

  public var phase: LauncherPhase {
    if exclusive != .idle { return exclusive }
    return isPreDownloading ? .preDownloading : .idle
  }

  public var primaryAction: PrimaryAction {
    PrimaryAction.derive(status)
  }

  @ObservationIgnored public let events: AsyncStream<JobEvent>
  @ObservationIgnored private let eventSink: AsyncStream<JobEvent>.Continuation

  public static let defaultLaunchTimeout: Duration = .seconds(120)
  /// Room for the chunk cache and files being assembled next to the finished ones.
  public static let defaultChunkTempMargin: Int64 = 2 << 30

  private let client: any GameClient
  private let launchTimeout: Duration
  private let chunkTempMargin: Int64
  private let availableDiskSpace: @Sendable (URL) -> Int64?
  private let sleep: @Sendable (Duration) async throws -> Void

  private var exclusiveTask: Task<Void, Never>?
  private var preDownloadTask: Task<Void, Never>?
  private var exclusivePreflight: Task<Void, Error>?
  private var preDownloadPreflight: Task<Void, Error>?
  private var launchGate: LaunchGate?
  private var launchWork: Task<LaunchOutcome, Error>?

  public init(
    client: any GameClient,
    gameDirectory: URL? = nil,
    launchTimeout: Duration = LauncherModel.defaultLaunchTimeout,
    chunkTempMargin: Int64 = LauncherModel.defaultChunkTempMargin,
    availableDiskSpace: @escaping @Sendable (URL) -> Int64? = LauncherModel.systemAvailableCapacity,
    sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
  ) {
    self.client = client
    self.gameDirectory = gameDirectory
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
    guard !isPausing else { throw LauncherError.busy }
    if job == .preDownload {
      try await startPreDownload()
    } else {
      try await startExclusive(job)
    }
  }

  private func startExclusive(_ job: GameJob) async throws {
    guard exclusive == .idle else { throw LauncherError.busy }
    if job != .install {
      guard status?.localVersion != nil else { throw LauncherError.notInstalled }
    }
    if job == .repair, status?.canUpdate == true { throw LauncherError.updateRequired }
    guard let store else { throw LauncherError.noGameDirectory }
    exclusive = job.exclusivePhase  // claim before any await so nothing else can slip in
    lastError = nil
    // The preflight is a Task the model owns, so pause() and shutdown() can cancel it and wait for it.
    let preflight = Task<Void, Error> {
      defer { exclusivePreflight = nil }
      do {
        await stopPreDownload()
        try Task.checkCancellation()
        try await checkDiskSpace(for: job, in: store.gameDirectory)
        try Task.checkCancellation()
      } catch {
        exclusive = .idle
        throw error
      }
    }
    exclusivePreflight = preflight
    do { try await preflight.value } catch is CancellationError { return }  // paused before the job began
    let stream = begin(job, store: store)
    exclusiveTask = Task { await self.drive(job, stream: stream, store: store) }
  }

  private func startPreDownload() async throws {
    guard exclusive == .idle || exclusive == .launching || exclusive == .running,
      !isPreDownloading
    else { throw LauncherError.busy }
    guard status?.localVersion != nil else { throw LauncherError.notInstalled }
    guard status?.canPreDownload == true else { throw LauncherError.preDownloadUnavailable }
    guard let store else { throw LauncherError.noGameDirectory }
    isPreDownloading = true
    lastError = nil
    let preflight = Task<Void, Error> {
      defer { preDownloadPreflight = nil }
      do {
        try await checkDiskSpace(for: .preDownload, in: store.gameDirectory)
        try Task.checkCancellation()
        // Starting install/update/repair during the check would have claimed the slot first.
        guard exclusive == .idle || exclusive == .launching || exclusive == .running else {
          throw LauncherError.busy
        }
      } catch {
        isPreDownloading = false
        throw error
      }
    }
    preDownloadPreflight = preflight
    do { try await preflight.value } catch is CancellationError { return }
    let stream = begin(.preDownload, store: store)
    preDownloadTask = Task { await self.drive(.preDownload, stream: stream, store: store) }
  }

  private func begin(_ job: GameJob, store: PendingJobStore) -> AsyncThrowingStream<JobProgress, Error> {
    let pending = PendingJob(kind: job, targetVersion: status?.remoteVersion)
    do {
      try store.save(pending)
      pendingJob = pending
    } catch {
      // Without job.json the job still runs; it just cannot be offered as "continue" after a restart.
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
      store.clear()
      pendingJob = nil
      await refresh()
      eventSink.yield(.finished(job))
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

  /// Cancels the preflight and job Tasks of the chosen slots and returns once all of them have stopped.
  private func cancelAndWait(exclusive: Bool, preDownload: Bool) async {
    var preflights: [Task<Void, Error>] = []
    var jobs: [Task<Void, Never>] = []
    if exclusive { preflights += [exclusivePreflight].compactMap { $0 }; jobs += [exclusiveTask].compactMap { $0 } }
    if preDownload { preflights += [preDownloadPreflight].compactMap { $0 }; jobs += [preDownloadTask].compactMap { $0 } }
    for task in preflights { task.cancel() }
    for task in jobs { task.cancel() }
    for task in preflights { _ = await task.result }
    for task in jobs { await task.value }
  }

  private func stopPreDownload() async {
    guard let task = preDownloadTask else { return }
    task.cancel()
    await task.value
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
    let pausable: Set<LauncherPhase> = [.installing, .updating, .repairing]
    let exclusivePause = pausable.contains(exclusive)
    guard exclusivePause ? (exclusivePreflight != nil || exclusiveTask != nil)
      : (preDownloadPreflight != nil || preDownloadTask != nil)
    else { return }
    isPausing = true
    await cancelAndWait(exclusive: exclusivePause, preDownload: !exclusivePause)
    isPausing = false
  }

  public func resume() async throws {
    guard let pendingJob else { return }
    try await start(pendingJob.kind)
  }

  /// App quit: cancel everything, wait for it to stop, keep `job.json`.
  public func shutdown() async {
    launchWork?.cancel()
    await cancelAndWait(exclusive: true, preDownload: true)
  }

  // MARK: Launch

  public func launch() async throws {
    guard exclusive == .idle, !isPausing else { throw LauncherError.busy }
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
    let options = LaunchOptions(gameDirectory: gameDirectory)
    let onStarted: @Sendable () -> Void = { [weak self] in
      gate.markStarted()
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
    while let task = exclusivePreflight ?? preDownloadPreflight {
      _ = await task.result
    }
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

  func markStarted() { state.withLock { if $0 == .waiting { $0 = .started } } }

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
