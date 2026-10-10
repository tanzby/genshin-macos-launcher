import Foundation
import Synchronization

@testable import Launcher

/// Scriptable `GameClient`. Every `run(job)` hands the test a stream it can drive; every interesting
/// moment is appended to an ordered event log ("run:update", "terminated:preDownload", "launch", ...).
final class FakeGameClient: GameClient, Sendable {
  private struct RunRecord {
    var job: GameJob
    var continuation: AsyncThrowingStream<JobProgress, Error>.Continuation
    var terminated = false
  }

  private struct State {
    var status: Result<GameStatus, Error>
    var required: [GameJob: Int64] = [:]
    var statusCalls = 0
    var runs: [RunRecord] = []
    var events: [String] = []
    var launchOptions: [LaunchOptions] = []
    var gameDirectories: [URL?] = []
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

  // MARK: Observation

  var statusCalls: Int { state.withLock { $0.statusCalls } }
  var runs: [GameJob] { state.withLock { $0.runs.map(\.job) } }
  var events: [String] { state.withLock { $0.events } }
  var launchOptions: [LaunchOptions] { state.withLock { $0.launchOptions } }
  var gameDirectories: [URL?] { state.withLock { $0.gameDirectories } }
  func isTerminated(run index: Int) -> Bool { state.withLock { $0.runs[index].terminated } }

  /// Suspends until the next `run(_:)` call that the test has not yet consumed; returns its index.
  func nextRun() async throws -> Int { try await startedRuns.pop("a run(_:) call") }
  func nextLaunch() async throws { try await startedLaunches.pop("a launch(_:onStarted:) call") }

  // MARK: Driving runs

  func yield(_ progress: JobProgress, run index: Int) {
    let continuation = state.withLock { $0.runs[index].continuation }
    continuation.yield(progress)
  }

  func finish(run index: Int) {
    let continuation = state.withLock { $0.runs[index].continuation }
    continuation.finish()
  }

  func finish(run index: Int, throwing error: any Error) {
    let continuation = state.withLock { $0.runs[index].continuation }
    continuation.finish(throwing: error)
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

  func status() async throws -> GameStatus {
    if stallsStatus.withLock({ $0 }) {
      statusQueries.push(())
      _ = await statusGate.pop()
      try Task.checkCancellation()
    }
    return try state.withLock { s -> GameStatus in
      s.statusCalls += 1
      return try s.status.get()
    }
  }

  /// When set, `requiredDiskSpace` signals `diskQueries` and suspends until cancelled.
  let stallsDiskQuery = Mutex(false)
  let diskQueries = AsyncQueue<Void>()

  func requiredDiskSpace(for job: GameJob) async throws -> Int64 {
    if stallsDiskQuery.withLock({ $0 }) {
      diskQueries.push(())
      while true {
        try Task.checkCancellation()
        try await Task.sleep(for: .seconds(60))
      }
    }
    return state.withLock { $0.required[job] ?? 0 }
  }

  func run(_ job: GameJob) -> AsyncThrowingStream<JobProgress, Error> {
    let (stream, continuation) = AsyncThrowingStream<JobProgress, Error>.makeStream()
    let index = state.withLock { s -> Int in
      s.runs.append(RunRecord(job: job, continuation: continuation))
      s.events.append("run:\(job.rawValue)")
      return s.runs.count - 1
    }
    continuation.onTermination = { [self] _ in
      state.withLock { s in
        s.runs[index].terminated = true
        s.events.append("terminated:\(job.rawValue)")
      }
    }
    startedRuns.push(index)
    return stream
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

  func setGameDirectory(_ url: URL?) { state.withLock { $0.gameDirectories.append(url) } }
}
