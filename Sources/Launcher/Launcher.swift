import Foundation
import Observation
import Platform
import Wine

public struct GameStatus: Sendable, Equatable {
  public var localVersion: String?
  public var remoteVersion: String?
  public var canUpdate: Bool
  public var canPreDownload: Bool
  /// The pre-download branch's target version. It can differ from `remoteVersion` (the main branch), and both
  /// `canUpdate` and `canPreDownload` may be true at once.
  public var preDownloadVersion: String?

  public init(
    localVersion: String? = nil,
    remoteVersion: String? = nil,
    canUpdate: Bool = false,
    canPreDownload: Bool = false,
    preDownloadVersion: String? = nil
  ) {
    self.localVersion = localVersion
    self.remoteVersion = remoteVersion
    self.canUpdate = canUpdate
    self.canPreDownload = canPreDownload
    self.preDownloadVersion = preDownloadVersion
  }
}

public enum GameJob: String, Sendable, Equatable, Codable {
  case install, update, preDownload, repair
}

public enum JobProgress: Sendable, Equatable {
  case preparing
  case running(done: Int64, total: Int64)
  case finalizing
  /// Wine preparation: download (Wine, DXMT), extraction, prefix and DXMT setup.
  case wine(WineInstallProgress)
}

/// A snapshot of the settings at launch time. Domain modules never read `UserDefaults`.
public struct LaunchOptions: Sendable, Equatable {
  public struct Resolution: Sendable, Equatable {
    public var width: Int
    public var height: Int

    public init(width: Int, height: Int) {
      self.width = width
      self.height = height
    }
  }

  public var gameDirectory: URL
  public var retina: Bool
  public var leftCommandIsControl: Bool
  public var metalHUD: Bool
  public var hdr: Bool
  public var metalFX: Bool
  /// `nil` leaves the game's own resolution alone.
  public var customResolution: Resolution?
  /// Raw `host:port`; `nil` or empty means no proxy.
  public var proxyHost: String?

  public init(
    gameDirectory: URL, retina: Bool = false, leftCommandIsControl: Bool = false, metalHUD: Bool = false,
    hdr: Bool = false, metalFX: Bool = false, customResolution: Resolution? = nil, proxyHost: String? = nil
  ) {
    self.gameDirectory = gameDirectory
    self.retina = retina
    self.leftCommandIsControl = leftCommandIsControl
    self.metalHUD = metalHUD
    self.hdr = hdr
    self.metalFX = metalFX
    self.customResolution = customResolution
    self.proxyHost = proxyHost
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
  /// The launcher tells the client which folder `status()`, `run(_:)` and `requiredDiskSpace(for:)` work on
  /// (they take no path). Called with the current folder, also `nil`, before every refresh, job start and launch.
  func setGameDirectory(_ url: URL?)
}

extension GameClient {
  public func setGameDirectory(_ url: URL?) {}
}

/// The seam between the launcher and the Wine runtime. `WineRuntime` is the production implementation;
/// tests use a Fake so the state machine never touches the disk or the network.
public protocol WinePreparing: Sendable {
  /// Whether the pinned Wine and DXMT are installed and intact. Looks at the disk (the version stamp).
  func status() async -> WineStatus
  /// Installs Wine, DXMT and the prefix when `status()` is not `.ready`. Must stop when its Task is
  /// cancelled; downloads resume from their `.part` files on the next call.
  func ensureInstalled(progress: @escaping @Sendable (WineInstallProgress) -> Void) async throws
}

extension WineRuntime: WinePreparing {}

/// What the main button does next. A pure function of the launcher's state.
public enum PrimaryAction: Sendable, Equatable {
  /// Wine is missing or damaged; nothing else can run until it is prepared.
  case prepareWine
  case install
  case update
  case launch

  public static func derive(_ status: GameStatus?) -> PrimaryAction {
    guard let status, status.localVersion != nil else { return .install }
    return status.canUpdate ? .update : .launch
  }
}
