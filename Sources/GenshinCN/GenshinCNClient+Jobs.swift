import Foundation
import Launcher
import Sophon

extension GenshinCNClient {
  // MARK: - Running jobs

  public func run(_ job: GameJob, in directory: URL) -> AsyncThrowingStream<JobProgress, Error> {
    let (stream, continuation) = AsyncThrowingStream<JobProgress, Error>.makeStream()
    let task = serializer.enqueue { [self] in
      // Paused before it began: do not touch the disk at all.
      if Task.isCancelled {
        continuation.finish(throwing: CancellationError())
        return
      }
      do {
        try await sophon.run(Self.sophonJob(job), in: directory) { continuation.yield(Self.jobProgress($0)) }
        continuation.finish()
      } catch {
        continuation.finish(throwing: Self.map(error))
      }
    }
    continuation.onTermination = { _ in task.cancel() }
    return stream
  }

  public func requiredDiskSpace(for job: GameJob, in directory: URL) async throws -> Int64 {
    do {
      return try await sophon.requiredDiskSpace(for: Self.sophonJob(job), in: directory)
    } catch {
      throw Self.map(error)
    }
  }

  static func sophonJob(_ job: GameJob) -> SophonJob {
    switch job {
    case .install: .install
    case .update: .update
    case .repair: .repair
    case .preDownload: .preDownload
    }
  }

  static func jobProgress(_ progress: SophonProgress) -> JobProgress {
    switch progress {
    case .preparing: .preparing
    case .downloading(let done, let total), .verifying(let done, let total), .patching(let done, let total):
      .running(done: done, total: total)
    case .finalizing: .finalizing
    }
  }
}
