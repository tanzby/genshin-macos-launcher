import Foundation
import Platform
import Wine

/// What the launcher is doing right now. Pre-download is only reported while nothing exclusive runs;
/// `LauncherModel.isPreDownloading` tells whether it overlaps with launching or running.
package enum LauncherPhase: Sendable, Equatable {
  case idle, preparingWine, installing, updating, preDownloading, repairing, launching, running
}

public enum LauncherError: Error, Sendable, Equatable {
  case busy
  /// Wine is missing or damaged; prepare it first.
  case wineNotReady
  /// Wine preparation failed for a reason other than network, verification or disk space.
  case wineInstall(WineInstallError)
  /// Rosetta 2 is not installed, so Wine cannot run. Install it, then reopen the window.
  case rosettaMissing
  case noGameDirectory
  case notInstalled
  case offline
  case updateRequired
  case pendingJob(GameJob)
  case preDownloadUnavailable
  case insufficientDiskSpace(required: Int64, available: Int64)
  case launchTimeout
  case gameExited(code: Int32, logPath: URL)
  case failedToLaunch
  case client(GameClientError)
  case unexpected(String)

  /// Bytes still missing for `insufficientDiskSpace`.
  public var shortfall: Int64? {
    if case .insufficientDiskSpace(let required, let available) = self { return max(0, required - available) }
    return nil
  }
}

/// Discrete events for system notifications. `@Observable` coalesces states, so it cannot drive them.
public enum JobEvent: Sendable, Equatable {
  case finished(GameJob)
  case failed(GameJob, LauncherError)
  case launchFailed(LauncherError)
  case wineReady
  case wineFailed(LauncherError)
}

extension GameJob {
  var exclusivePhase: LauncherPhase {
    switch self {
    case .install: .installing
    case .update: .updating
    case .repair: .repairing
    case .preDownload: .preDownloading
    }
  }
}

extension LauncherError {
  init(_ error: Error) {
    if let error = error as? LauncherError {
      self = error
    } else if let error = error as? GameClientError {
      self = .client(error)
    } else if let error = error as? WineInstallError {
      if case .insufficientDiskSpace(let required, let available) = error {
        self = .insufficientDiskSpace(required: required, available: available)
      } else {
        self = .wineInstall(error)
      }
    } else if let error = error as? DownloadError {
      switch error {
      case .httpStatus: self = .client(.network)
      case .checksumMismatch: self = .client(.verificationFailed)
      }
    } else if let error = error as? URLError {
      self = error.code == .cancelled ? .client(.cancelled) : .client(.network)
    } else if error is CancellationError {
      self = .client(.cancelled)
    } else {
      self = .unexpected(String(describing: error))
    }
  }
}
