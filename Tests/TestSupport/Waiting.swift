import Foundation
import Observation
import Synchronization

// Waiting in tests: never a fixed `Task.sleep` (AGENTS.md); CI runners are slow and uneven.

public struct TestTimeout: Error, CustomStringConvertible {
  public var what: String
  public init(what: String) { self.what = what }
  public var description: String { "timed out waiting for \(what) (failsafe, not a synchronization primitive)" }
}

/// How long any wait in a test may take before it gives up. Only a red test ever reaches it.
public let testFailsafe: Duration = .seconds(10)

/// Polls `condition` every few milliseconds until it holds; false once `timeout` has passed or the task is cancelled.
public func pollUntil(timeout: Duration = testFailsafe, _ condition: () async throws -> Bool) async rethrows -> Bool {
  let deadline = ContinuousClock.now + timeout
  while ContinuousClock.now < deadline && !Task.isCancelled {
    if try await condition() { return true }
    try? await Task.sleep(for: .milliseconds(2))
  }
  return try await condition()
}

/// Suspends (no polling) until `predicate` holds, via `Observations`; false when the failsafe expires.
public func waitUntil(_ predicate: @escaping @MainActor @Sendable () -> Bool) async -> Bool {
  let outcome = AsyncQueue<Bool>()
  let watcher = Task { @MainActor in
    for await value in Observations({ predicate() }) where value {
      outcome.push(true)
      return
    }
    outcome.push(false)
  }
  defer { watcher.cancel() }
  return await outcome.pop() ?? false
}

/// FIFO hand-off between a producer and an awaiting test. `pop()` suspends without polling. The
/// failsafe only exists so a red test fails instead of hanging; it never decides a passing outcome.
public final class AsyncQueue<T: Sendable>: Sendable {
  private struct State {
    var items: [T] = []
    var waiters: [(id: Int, continuation: CheckedContinuation<T?, Never>)] = []
    var nextID = 0
  }
  private let state = Mutex(State())
  public static var failsafe: Duration { testFailsafe }

  public init() {}

  public func push(_ item: T) {
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
  public func pop() async -> T? {
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

  public func pop(_ what: String) async throws -> T {
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
