import Foundation
import Synchronization

@testable import Launcher

struct TestTimeout: Error, CustomStringConvertible {
  var what: String
  var description: String { "timed out waiting for \(what) (failsafe, not a synchronization primitive)" }
}

/// FIFO hand-off between a producer and an awaiting test. `pop()` suspends without polling. The
/// failsafe only exists so a red test fails instead of hanging; it never decides a passing outcome.
final class AsyncQueue<T: Sendable>: Sendable {
  private struct State {
    var items: [T] = []
    var waiters: [(id: Int, continuation: CheckedContinuation<T?, Never>)] = []
    var nextID = 0
  }
  private let state = Mutex(State())
  static var failsafe: Duration { .seconds(5) }

  func push(_ item: T) {
    let waiter: CheckedContinuation<T?, Never>? = state.withLock { s in
      if s.waiters.isEmpty {
        s.items.append(item)
        return nil
      }
      return s.waiters.removeFirst().continuation
    }
    waiter?.resume(returning: item)
  }

  /// Returns nil when the failsafe expires.
  func pop() async -> T? {
    await withTaskGroup(of: T?.self) { group in
      group.addTask { await self.popUnbounded() }
      group.addTask {
        try? await Task.sleep(for: Self.failsafe)
        return nil
      }
      let first = await group.next() ?? nil
      group.cancelAll()
      return first
    }
  }

  func pop(_ what: String) async throws -> T {
    guard let item = await pop() else { throw TestTimeout(what: what) }
    return item
  }

  private func popUnbounded() async -> T? {
    let id = state.withLock { s -> Int in
      s.nextID += 1
      return s.nextID
    }
    return await withTaskCancellationHandler {
      await withCheckedContinuation { (continuation: CheckedContinuation<T?, Never>) in
        let immediate: T?? = state.withLock { s in
          if !s.items.isEmpty { return .some(s.items.removeFirst()) }
          s.waiters.append((id, continuation))
          return nil
        }
        if let immediate {
          continuation.resume(returning: immediate)
        } else if Task.isCancelled {
          cancelWaiter(id)
        }
      }
    } onCancel: {
      cancelWaiter(id)
    }
  }

  private func cancelWaiter(_ id: Int) {
    let continuation = state.withLock { s -> CheckedContinuation<T?, Never>? in
      guard let index = s.waiters.firstIndex(where: { $0.id == id }) else { return nil }
      return s.waiters.remove(at: index).continuation
    }
    continuation?.resume(returning: nil)
  }
}

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
