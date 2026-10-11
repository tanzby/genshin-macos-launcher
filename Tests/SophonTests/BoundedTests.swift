import Foundation
import Synchronization
import Testing
import TestSupport

@testable import Sophon

@Suite struct BoundedTests {
  private final class Gauge: Sendable {
    private let state = Mutex((running: 0, peak: 0, started: 0))
    func enter() { state.withLock { $0.running += 1; $0.started += 1; $0.peak = max($0.peak, $0.running) } }
    func leave() { state.withLock { $0.running -= 1 } }
    var peak: Int { state.withLock { $0.peak } }
    var started: Int { state.withLock { $0.started } }
  }

  @Test func runBoundedKeepsAtMostLimitInFlightAndRunsEveryItem() async throws {
    let gauge = Gauge()
    try await runBounded(Array(0..<20), limit: 3) { _ in
      gauge.enter()
      defer { gauge.leave() }
      await Task.yield()
    }
    #expect(gauge.started == 20)
    #expect(gauge.peak <= 3)
  }

  @Test func mapBoundedReturnsResultsInItemOrder() async throws {
    let results = try await mapBounded(Array(0..<20), limit: 4) { item in
      for _ in 0..<(20 - item) { await Task.yield() }
      return item * 2
    }
    #expect(results == (0..<20).map { $0 * 2 })
  }

  @Test func runBoundedStopsStartingItemsAndThrowsAfterCancellation() async throws {
    let gauge = Gauge()
    let task = Task {
      try await runBounded(Array(0..<50), limit: 2) { item in
        gauge.enter()
        defer { gauge.leave() }
        while !Task.isCancelled { await Task.yield() }
      }
    }
    #expect(await pollUntil { gauge.started >= 2 })
    task.cancel()
    await #expect(throws: CancellationError.self) { try await task.value }
    #expect(gauge.started < 50)
  }
}
