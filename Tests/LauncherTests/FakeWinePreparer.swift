import Foundation
import Synchronization
import TestSupport
import Wine

@testable import Launcher

/// Scriptable `WinePreparing`. Every `ensureInstalled` call hands the test a handle it can drive; the log
/// records "status", "install:N", "cancelled:N" and "stopped:N" in order, so a test can prove an install had
/// really stopped (not merely been asked to) by the time `pause()` returned.
final class FakeWinePreparer: WinePreparing, Sendable {
  private struct Install {
    var backend: GraphicsBackend
    var progress: @Sendable (WineInstallProgress) -> Void
    var continuation: CheckedContinuation<Void, Error>?
    var cancelled = false
  }

  private struct State {
    var status: WineStatus
    var backendStatuses: [GraphicsBackend: WineStatus] = [:]
    var statusCalls = 0
    var statusBackends: [GraphicsBackend] = []
    var installs: [Install] = []
    var installBackends: [GraphicsBackend] = []
    var log: [String] = []
    var holdsCancellation = false
  }

  private let state: Mutex<State>
  /// One element (the install index) each time `ensureInstalled` is suspended and waiting for the test.
  let startedInstalls = AsyncQueue<Int>()
  /// One element (the install index) each time an install receives cancellation.
  let cancelRequests = AsyncQueue<Int>()

  init(status: WineStatus = .ready) {
    state = Mutex(State(status: status))
  }

  // MARK: Stubbing

  func setStatus(_ status: WineStatus) { state.withLock { $0.status = status } }
  func setStatus(_ status: WineStatus, for backend: GraphicsBackend) {
    state.withLock { $0.backendStatuses[backend] = status }
  }

  /// While set, a cancelled install keeps running until `releaseCancelled(install:)`.
  /// This models real work that needs a moment to stop.
  func holdCancellation(_ hold: Bool) { state.withLock { $0.holdsCancellation = hold } }

  // MARK: Observation

  var statusCalls: Int { state.withLock { $0.statusCalls } }
  var statusBackends: [GraphicsBackend] { state.withLock { $0.statusBackends } }
  var installCount: Int { state.withLock { $0.installs.count } }
  var installBackends: [GraphicsBackend] { state.withLock { $0.installBackends } }
  var log: [String] { state.withLock { $0.log } }

  func nextInstall() async throws -> Int { try await startedInstalls.pop("an ensureInstalled call") }
  func nextCancellation() async throws -> Int { try await cancelRequests.pop("a cancelled ensureInstalled") }

  // MARK: Driving installs

  func yield(_ progress: WineInstallProgress, install index: Int) {
    let sink = state.withLock { $0.installs[index].progress }
    sink(progress)
  }

  /// Completes the install successfully; `status()` reports `.ready` afterwards.
  func finish(install index: Int) {
    stop(index, with: .success(()), becomesReady: true)
  }

  func fail(install index: Int, throwing error: any Error) {
    stop(index, with: .failure(error))
  }

  /// Lets a held, cancelled install finish stopping.
  func releaseCancelled(install index: Int) {
    stop(index, with: .failure(CancellationError()))
  }

  // MARK: WinePreparing

  /// When set, `status()` signals `statusQueries` and suspends until `statusGate` is pushed to.
  let stallsStatus = Mutex(false)
  let statusQueries = AsyncQueue<Void>()
  let statusGate = AsyncQueue<Void>()

  func status(for backend: GraphicsBackend) async -> WineStatus {
    state.withLock { $0.statusBackends.append(backend) }
    return await readStatus(for: backend)
  }

  private func readStatus(for backend: GraphicsBackend) async -> WineStatus {
    if stallsStatus.withLock({ $0 }) {
      statusQueries.push(())
      _ = await statusGate.pop()
    }
    return state.withLock { s in
      s.statusCalls += 1
      s.log.append("status")
      return s.backendStatuses[backend] ?? s.status
    }
  }

  func ensureInstalled(
    for backend: GraphicsBackend, progress: @escaping @Sendable (WineInstallProgress) -> Void
  ) async throws {
    state.withLock { $0.installBackends.append(backend) }
    try await runInstall(progress: progress, backend: backend)
  }

  private func runInstall(
    progress: @escaping @Sendable (WineInstallProgress) -> Void, backend: GraphicsBackend
  ) async throws {
    let index = state.withLock { s -> Int in
      s.installs.append(Install(backend: backend, progress: progress))
      s.log.append("install:\(s.installs.count - 1)")
      return s.installs.count - 1
    }
    try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
        let cancelNow = state.withLock { s -> Bool in
          s.installs[index].continuation = continuation
          return s.installs[index].cancelled && !s.holdsCancellation
        }
        startedInstalls.push(index)
        if cancelNow { stop(index) }
      }
    } onCancel: {
      let stopNow = state.withLock { s -> Bool in
        s.installs[index].cancelled = true
        s.log.append("cancelled:\(index)")
        return !s.holdsCancellation
      }
      cancelRequests.push(index)
      if stopNow { stop(index) }
    }
  }

  /// Cancellation path: ends the install only if it is still suspended.
  private func stop(_ index: Int) {
    stop(index, with: .failure(CancellationError()), onlyIfSuspended: true)
  }

  /// Ends install `index` the way a real one would: logs "stopped:N" and resumes its suspended call once.
  private func stop(
    _ index: Int, with result: Result<Void, any Error>, becomesReady: Bool = false, onlyIfSuspended: Bool = false
  ) {
    let continuation = state.withLock { s -> CheckedContinuation<Void, Error>? in
      let continuation = s.installs[index].continuation.take()
      if continuation == nil && onlyIfSuspended { return nil }
      if becomesReady {
        s.status = .ready
        s.backendStatuses[s.installs[index].backend] = .ready
      }
      s.log.append("stopped:\(index)")
      return continuation
    }
    continuation?.resume(with: result)
  }
}

extension Optional {
  fileprivate mutating func take() -> Wrapped? {
    defer { self = nil }
    return self
  }
}
