import Foundation
import Synchronization
import TestSupport
import Wine

@testable import Launcher

/// Scriptable `GameClient`. Every `run(job)` suspends until the test drives it; every interesting
/// moment is appended to an ordered event log ("run:update", "terminated:preDownload", "launch", ...).
final class FakeGameClient: GameClient, Sendable {
  private enum RunCommand: Sendable {
    case progress(JobProgress)
    case finish
    case fail(any Error)
  }

  private struct RunRecord {
    var job: GameJob
    var commands: AsyncStream<RunCommand>.Continuation
    /// `run` has returned (finished, failed or cancelled).
    var terminated = false
  }

  private struct State {
    var status: Result<GameStatus, Error>
    var required: [GameJob: Int64] = [:]
    var diskCheckFailure: (any Error)?
    var statusCalls = 0
    var runs: [RunRecord] = []
    var events: [String] = []
    var launchOptions: [LaunchOptions] = []
    var statusDirectories: [URL?] = []
    var diskCheckDirectories: [URL] = []
    var runDirectories: [URL] = []
    var prompts: [LaunchOptions] = []
    var launchContinuation: CheckedContinuation<LaunchOutcome, Error>?
    var launchCancelled = false
    var onStarted: (@Sendable () -> Void)?
  }

  private let state: Mutex<State>
  /// Indices into `runs`, one per `run(_:)` call, in call order.
  let startedRuns = AsyncQueue<Int>()
  /// One element each time `launch` is suspended and waiting for the test.
  let startedLaunches = AsyncQueue<Void>()

  init(status: GameStatus = GameStatus()) {
    state = Mutex(State(status: .success(status)))
  }

  // MARK: Stubbing

  func setStatus(_ status: GameStatus) { state.withLock { $0.status = .success(status) } }
  func setStatusFailure(_ error: any Error) { state.withLock { $0.status = .failure(error) } }
  func setRequiredDiskSpace(_ bytes: Int64, for job: GameJob) { state.withLock { $0.required[job] = bytes } }
  /// `requiredDiskSpace` also validates the folder; this makes it refuse.
  func setDiskCheckFailure(_ error: any Error) { state.withLock { $0.diskCheckFailure = error } }

  // MARK: Observation

  var statusCalls: Int { state.withLock { $0.statusCalls } }
  var runs: [GameJob] { state.withLock { $0.runs.map(\.job) } }
  var events: [String] { state.withLock { $0.events } }
  var launchOptions: [LaunchOptions] { state.withLock { $0.launchOptions } }
  /// The folder each `status(in:)`, `requiredDiskSpace` and `run` call was given, in call order.
  var statusDirectories: [URL?] { state.withLock { $0.statusDirectories } }
  var diskCheckDirectories: [URL] { state.withLock { $0.diskCheckDirectories } }
  var runDirectories: [URL] { state.withLock { $0.runDirectories } }
  var commandPrompts: [LaunchOptions] { state.withLock { $0.prompts } }

  func openWineCommandPrompt(_ options: LaunchOptions) async { state.withLock { $0.prompts.append(options) } }
  func isTerminated(run index: Int) -> Bool { state.withLock { $0.runs[index].terminated } }

  /// Suspends until the next `run(_:)` call that the test has not yet consumed; returns its index.
  func nextRun() async throws -> Int { try await startedRuns.pop("a run(_:) call") }
  func nextLaunch() async throws { try await startedLaunches.pop("a launch(_:onStarted:) call") }

  // MARK: Driving runs

  func yield(_ progress: JobProgress, run index: Int) { send(.progress(progress), run: index) }
  func finish(run index: Int) { send(.finish, run: index) }
  func finish(run index: Int, throwing error: any Error) { send(.fail(error), run: index) }

  private func send(_ command: RunCommand, run index: Int) {
    let commands = state.withLock { $0.runs[index].commands }
    commands.yield(command)
  }

  // MARK: Driving launch

  func fireStarted() {
    let callback = state.withLock { $0.onStarted }
    callback?()
  }

  func finishLaunch(_ outcome: LaunchOutcome) {
    let continuation = takeLaunchContinuation()
    continuation?.resume(returning: outcome)
  }

  func failLaunch(_ error: any Error) {
    let continuation = takeLaunchContinuation()
    continuation?.resume(throwing: error)
  }

  private func takeLaunchContinuation() -> CheckedContinuation<LaunchOutcome, Error>? {
    state.withLock { s in
      let continuation = s.launchContinuation
      s.launchContinuation = nil
      return continuation
    }
  }

  private func log(_ event: String) { state.withLock { $0.events.append(event) } }

  // MARK: GameClient

  /// When set, `status()` signals `statusQueries` and suspends until `statusGate` is pushed to (or cancelled).
  let stallsStatus = Mutex(false)
  let statusQueries = AsyncQueue<Void>()
  let statusGate = AsyncQueue<Void>()

  /// The answer is fixed when the query starts, like a response to a request already sent.
  func status(in directory: URL?) async throws -> GameStatus {
    let answer = state.withLock { s -> Result<GameStatus, Error> in
      s.statusCalls += 1
      s.statusDirectories.append(directory)
      return s.status
    }
    if stallsStatus.withLock({ $0 }) {
      statusQueries.push(())
      _ = await statusGate.pop()
      try Task.checkCancellation()
    }
    return try answer.get()
  }

  /// When set, `requiredDiskSpace` signals `diskQueries` and suspends until cancelled.
  let stallsDiskQuery = Mutex(false)
  let diskQueries = AsyncQueue<Void>()

  func requiredDiskSpace(for job: GameJob, in directory: URL) async throws -> Int64 {
    state.withLock { $0.diskCheckDirectories.append(directory) }
    if stallsDiskQuery.withLock({ $0 }) {
      diskQueries.push(())
      while true {
        try Task.checkCancellation()
        try await Task.sleep(for: .seconds(60))
      }
    }
    return try state.withLock { s in
      if let failure = s.diskCheckFailure { throw failure }
      return s.required[job] ?? 0
    }
  }

  /// Suspends until the test finishes or fails the run, or the caller is cancelled (then throws `CancellationError`).
  func run(
    _ job: GameJob, in directory: URL, backend: GraphicsBackend, progress: @escaping @Sendable (JobProgress) -> Void
  ) async throws {
    let (commands, sink) = AsyncStream<RunCommand>.makeStream()
    let index = state.withLock { s -> Int in
      s.runs.append(RunRecord(job: job, commands: sink))
      s.runDirectories.append(directory)
      s.events.append("run:\(job.rawValue)")
      return s.runs.count - 1
    }
    defer {
      state.withLock { s in
        s.runs[index].terminated = true
        s.events.append("terminated:\(job.rawValue)")
      }
    }
    startedRuns.push(index)
    // The iteration ends when the caller is cancelled.
    for await command in commands {
      switch command {
      case .progress(let update): progress(update)
      case .finish: return
      case .fail(let error): throw error
      }
    }
    throw CancellationError()
  }

  func launch(
    _ options: LaunchOptions, onStarted: @escaping @Sendable () -> Void
  ) async throws -> LaunchOutcome {
    state.withLock { s in
      s.launchOptions.append(options)
      s.launchCancelled = false
      s.onStarted = onStarted
      s.events.append("launch")
    }
    do {
      let outcome = try await withTaskCancellationHandler {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<LaunchOutcome, Error>) in
          let cancelled = state.withLock { s -> Bool in
            if s.launchCancelled { return true }
            s.launchContinuation = continuation
            return false
          }
          if cancelled {
            continuation.resume(throwing: CancellationError())
          } else {
            startedLaunches.push(())
          }
        }
      } onCancel: {
        let continuation = state.withLock { s -> CheckedContinuation<LaunchOutcome, Error>? in
          s.events.append("launch:cancelled")
          s.launchCancelled = true
          let continuation = s.launchContinuation
          s.launchContinuation = nil
          return continuation
        }
        continuation?.resume(throwing: CancellationError())
      }
      log("launch:ended")
      return outcome
    } catch {
      log("launch:ended")
      throw error
    }
  }

  func backgroundImage() async -> BackgroundImage { .bundledDefault }
}
