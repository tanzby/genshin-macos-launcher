import Foundation
import TestSupport

@testable import Launcher

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
