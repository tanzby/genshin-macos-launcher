import Foundation
import Observation
import Platform
import Wine

public struct GameStatus: Sendable, Equatable {
  public var localVersion: String?
  public var remoteVersion: String?
  public var canUpdate: Bool
  public var canPreDownload: Bool

  public init(
    localVersion: String? = nil,
    remoteVersion: String? = nil,
    canUpdate: Bool = false,
    canPreDownload: Bool = false
  ) {
    self.localVersion = localVersion
    self.remoteVersion = remoteVersion
    self.canUpdate = canUpdate
    self.canPreDownload = canPreDownload
  }
}

public enum GameJob: String, Sendable, Equatable, Codable {
  case install, update, preDownload, repair
}

public enum JobProgress: Sendable, Equatable {
  case preparing
  case running(done: Int64, total: Int64)
  case finalizing
}

/// A snapshot of the settings at launch time. Domain modules never read `UserDefaults`.
public struct LaunchOptions: Sendable, Equatable {
  public var gameDirectory: URL

  public init(gameDirectory: URL) {
    self.gameDirectory = gameDirectory
  }
}

public enum LaunchOutcome: Sendable, Equatable {
  case exited
  case failedExit(code: Int32, logPath: URL)
  case failedToLaunch
}

public enum BackgroundImage: Sendable, Equatable {
  case bundledDefault
  case remote(URL)
}

public enum GameClientError: Error, Sendable, Equatable {
  case network
  case insufficientDiskSpace
  case verificationFailed
  case cancelled
  case wineReinstallRequired
}

/// The seam between the launcher state machine and a concrete game.
public protocol GameClient: Sendable {
  func status() async throws -> GameStatus
  func run(_ job: GameJob) -> AsyncThrowingStream<JobProgress, Error>
  /// Bytes the job will write after decompression, excluding the chunk-cache margin the launcher adds.
  /// Install: unpacked total. Update and pre-download: download size plus new files. 0 when nothing is written.
  func requiredDiskSpace(for job: GameJob) async throws -> Int64
  /// `onStarted` fires once the game process exists; without it within the launch timeout the launcher cancels.
  /// Cancellation must restore Launch Mutations and kill the prefix before returning.
  func launch(_ options: LaunchOptions, onStarted: @escaping @Sendable () -> Void) async throws -> LaunchOutcome
  func backgroundImage() async -> BackgroundImage
}

/// What the main button does next. A pure function of the launcher's state.
public enum PrimaryAction: Sendable, Equatable {
  case install
  case update
  case launch

  public static func derive(_ status: GameStatus?) -> PrimaryAction {
    guard let status, status.localVersion != nil else { return .install }
    return status.canUpdate ? .update : .launch
  }
}
