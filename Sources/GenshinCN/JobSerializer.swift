import Foundation
import Synchronization

/// Runs jobs one after another. A job starts only after the one queued before it has returned, so a paused
/// (cancelled) job that is still finishing its file never overlaps with the job that resumes it.
///
/// Cancelling a `for try await` loop over an `AsyncThrowingStream` ends the loop at once; what stops the
/// work behind the stream is the Task, and only awaiting that Task proves it stopped.
final class JobSerializer: Sendable {
  private let tail = Mutex<Task<Void, Never>?>(nil)

  @discardableResult
  func enqueue(_ work: @escaping @Sendable () async -> Void) -> Task<Void, Never> {
    tail.withLock { tail in
      let previous = tail
      let task = Task {
        await previous?.value
        await work()
      }
      tail = task
      return task
    }
  }
}
