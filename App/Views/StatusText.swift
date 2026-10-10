import Foundation
import Launcher
import SwiftUI

extension PrimaryButton {
  var title: LocalizedStringResource {
    switch self {
    case .install: "Install Game"
    case .update: "Update Game"
    case .launch: "Start Game"
    case .pause: "Pause"
    case .pausing: "Pausing…"
    case .resume: "Resume"
    case .retry: "Retry"
    case .repairing: "Verifying…"
    case .launching: "Starting…"
    case .running: "Running"
    }
  }
}

extension GameJob {
  func title(paused: Bool) -> LocalizedStringResource {
    switch (self, paused) {
    case (.install, false): "Installing"
    case (.install, true): "Install paused"
    case (.update, false): "Updating"
    case (.update, true): "Update paused"
    case (.preDownload, false): "Pre-downloading"
    case (.preDownload, true): "Pre-download paused"
    case (.repair, _): "Verifying files"
    }
  }
}

extension LauncherError {
  var message: LocalizedStringResource {
    switch self {
    case .busy: "Another task is still running."
    case .noGameDirectory: "Choose a game folder first."
    case .notInstalled: "The game is not installed."
    case .offline: "You are offline."
    case .updateRequired: "Update the game before playing."
    case .pendingJob: "An unfinished task has to be continued first."
    case .preDownloadUnavailable: "There is no pre-download available."
    case .insufficientDiskSpace:
      "Not enough disk space: \(ByteFormat.wholeGiBRoundedUp(shortfall ?? 0)) GB more needed."
    case .launchTimeout: "The game did not start within 2 minutes."
    case .gameExited(let code, _): "The game exited with code \(Int(code))."
    case .failedToLaunch: "The game could not be started."
    case .client(.network): "Network error."
    case .client(.insufficientDiskSpace): "Not enough disk space."
    case .client(.verificationFailed): "File verification failed."
    case .client(.cancelled): "Cancelled."
    case .client(.wineReinstallRequired): "Wine has to be reinstalled."
    case .unexpected(let detail): "Unexpected error: \(detail)"
    }
  }

  /// The log to open from the capsule, when the game left one.
  var logURL: URL? {
    if case .gameExited(_, let url) = self { return url }
    return nil
  }
}

extension AppNotification {
  var title: LocalizedStringResource {
    switch self {
    case .jobFinished(.install): "Installation finished"
    case .jobFinished(.update): "Update finished"
    case .jobFinished(.preDownload): "Pre-download finished"
    case .jobFinished(.repair): "Verification finished"
    case .jobFailed: "Task failed"
    case .launchFailed: "The game could not run"
    case .updateAvailable: "Game update available"
    case .preDownloadAvailable: "Pre-download available"
    }
  }

  var body: LocalizedStringResource {
    switch self {
    case .jobFinished: "You can start the game now."
    case .jobFailed(_, let error), .launchFailed(let error): error.message
    case .updateAvailable(let version): "Version \(version) is ready to install."
    case .preDownloadAvailable(let version):
      version.map { "Version \($0) can be downloaded in advance." } ?? "A new version can be downloaded in advance."
    }
  }
}

enum Format {
  static func bytes(_ value: Int64) -> String { ByteFormat.iec(value) }

  static func duration(_ seconds: TimeInterval) -> String {
    Duration.seconds(seconds.rounded())
      .formatted(.units(allowed: [.hours, .minutes, .seconds], width: .abbreviated, maximumUnitCount: 2))
  }
}
