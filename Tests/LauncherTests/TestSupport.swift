import Foundation
import Synchronization
import TestSupport

@testable import Launcher

/// Injected `sleep`: suspends until the test calls `fire()`; throws `CancellationError` when cancelled.
final class ManualSleeper: Sendable {
  private struct State {
    var durations: [Duration] = []
    var cancelledCount = 0
    var waiters: [(id: Int, continuation: CheckedContinuation<Void, Error>)] = []
    var nextID = 0
  }
  private let state = Mutex(State())
  /// One element per `sleep` call that has started waiting.
  let sleeping = AsyncQueue<Duration>()

  var durations: [Duration] { state.withLock { $0.durations } }
  var cancelledCount: Int { state.withLock { $0.cancelledCount } }

  func sleep(_ duration: Duration) async throws {
    let id = state.withLock { s -> Int in
      s.nextID += 1
      s.durations.append(duration)
      return s.nextID
    }
    try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
        // `fire()` only wakes sleeps already waiting, so a retry's new sleep waits for its own fire.
        state.withLock { $0.waiters.append((id, continuation)) }
        sleeping.push(duration)
        if Task.isCancelled { cancelWaiter(id) }
      }
    } onCancel: {
      cancelWaiter(id)
    }
  }

  func fire() {
    let waiters = state.withLock { s -> [CheckedContinuation<Void, Error>] in
      let all = s.waiters.map(\.continuation)
      s.waiters = []
      return all
    }
    for waiter in waiters { waiter.resume() }
  }

  private func cancelWaiter(_ id: Int) {
    let continuation = state.withLock { s -> CheckedContinuation<Void, Error>? in
      guard let index = s.waiters.firstIndex(where: { $0.id == id }) else { return nil }
      s.cancelledCount += 1
      return s.waiters.remove(at: index).continuation
    }
    continuation?.resume(throwing: CancellationError())
  }
}

/// Drains `LauncherModel.events` in the background so tests can await the next event.
final class EventLog: Sendable {
  private let queue = AsyncQueue<JobEvent>()
  private let task: Task<Void, Never>

  init(_ stream: AsyncStream<JobEvent>) {
    let queue = queue
    task = Task {
      for await event in stream { queue.push(event) }
    }
  }

  deinit { task.cancel() }

  func next() async throws -> JobEvent { try await queue.pop("next JobEvent") }
}
