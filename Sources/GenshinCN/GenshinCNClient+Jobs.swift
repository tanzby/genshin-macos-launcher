import Foundation
import Launcher
import Sophon

extension GenshinCNClient {
  // MARK: - Running jobs

  public func run(
    _ job: GameJob, in directory: URL, progress: @escaping @Sendable (JobProgress) -> Void
  ) async throws {
    do {
      // Paused before it began: do not touch the disk at all.
      try Task.checkCancellation()
      try await recoverIfGameFilesAreTouched(by: job)
      try await sophon.run(Self.sophonJob(job), in: directory) { progress(Self.jobProgress($0)) }
    } catch {
      throw Self.map(error)
    }
  }

  /// Repair and update verify or patch the game's files, so files a crashed launch left aside must be back first. The
  /// launcher holds the exclusive slot, so no game is running. Install has nothing to restore and pre-download may
  /// run next to a running game: `recover()` would shut its prefix down.
  private func recoverIfGameFilesAreTouched(by job: GameJob) async throws {
    switch job {
    case .repair, .update:
      // Uncancellable, like the recovery before a launch: a half-done restore would still delete the journal.
      await Task { await launcher.recover() }.value
      try Task.checkCancellation()
    case .install, .preDownload:
      break
    }
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
