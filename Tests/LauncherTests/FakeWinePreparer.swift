import Foundation
import Synchronization
import Wine

@testable import Launcher

/// Scriptable `WinePreparing`. Every `ensureInstalled` call hands the test a handle it can drive; the log
/// records "status", "install:N", "cancelled:N" and "stopped:N" in order, so a test can prove an install had
/// really stopped (not merely been asked to) by the time `pause()` returned.
final class FakeWinePreparer: WinePreparing, Sendable {
  private struct Install {
    var progress: @Sendable (WineInstallProgress) -> Void
    var continuation: CheckedContinuation<Void, Error>?
    var cancelled = false
  }

  private struct State {
    var status: WineStatus
    var statusCalls = 0
    var installs: [Install] = []
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

  /// While set, a cancelled install keeps running until `releaseCancelled(install:)`.
  /// This models real work that needs a moment to stop.
  func holdCancellation(_ hold: Bool) { state.withLock { $0.holdsCancellation = hold } }

  // MARK: Observation

  var statusCalls: Int { state.withLock { $0.statusCalls } }
  var installCount: Int { state.withLock { $0.installs.count } }
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
    let continuation = state.withLock { s -> CheckedContinuation<Void, Error>? in
      s.status = .ready
      s.log.append("stopped:\(index)")
      return s.installs[index].continuation.take()
    }
    continuation?.resume()
  }

  func fail(install index: Int, throwing error: any Error) {
    let continuation = state.withLock { s -> CheckedContinuation<Void, Error>? in
      s.log.append("stopped:\(index)")
      return s.installs[index].continuation.take()
    }
    continuation?.resume(throwing: error)
  }

  /// Lets a held, cancelled install finish stopping.
  func releaseCancelled(install index: Int) {
    let continuation = state.withLock { s -> CheckedContinuation<Void, Error>? in
      s.log.append("stopped:\(index)")
      return s.installs[index].continuation.take()
    }
    continuation?.resume(throwing: CancellationError())
  }

  // MARK: WinePreparing

  func status() async -> WineStatus {
    state.withLock { s in
      s.statusCalls += 1
      s.log.append("status")
      return s.status
    }
  }

  func ensureInstalled(progress: @escaping @Sendable (WineInstallProgress) -> Void) async throws {
    let index = state.withLock { s -> Int in
      s.installs.append(Install(progress: progress))
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

  private func stop(_ index: Int) {
    let continuation = state.withLock { s -> CheckedContinuation<Void, Error>? in
      guard let continuation = s.installs[index].continuation.take() else { return nil }
      s.log.append("stopped:\(index)")
      return continuation
    }
    continuation?.resume(throwing: CancellationError())
  }
}

extension Optional {
  fileprivate mutating func take() -> Wrapped? {
    defer { self = nil }
    return self
  }
}
