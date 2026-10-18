import Foundation
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

  /// The version a pre-download fetches: its own branch, else the current remote one.
  package var preDownloadTarget: String? { preDownloadVersion ?? remoteVersion }
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
  public var graphicsBackend: GraphicsBackend
  public var retina: Bool
  public var leftCommandIsControl: Bool
  public var metalHUD: Bool
  /// Debug mode: diagnostic logging in Wine, DXMT and the game host (off: errors and results only).
  public var debugMode: Bool
  public var hdr: Bool
  public var metalFX: Bool
  /// Lift the game's 60 FPS cap (to 120 for Genshin).
  public var unlockFrameRate: Bool
  /// `nil` leaves the game's own resolution alone.
  public var customResolution: Resolution?
  /// Raw `host:port`; `nil` or empty means no proxy.
  public var proxyHost: String?

  public init(
    gameDirectory: URL, graphicsBackend: GraphicsBackend = .gptk4, retina: Bool = false,
    leftCommandIsControl: Bool = false, metalHUD: Bool = false,
    hdr: Bool = false, metalFX: Bool = false, unlockFrameRate: Bool = false, customResolution: Resolution? = nil,
    proxyHost: String? = nil, debugMode: Bool = false
  ) {
    self.gameDirectory = gameDirectory
    self.graphicsBackend = graphicsBackend
    self.retina = retina
    self.leftCommandIsControl = leftCommandIsControl
    self.metalHUD = metalHUD
    self.hdr = hdr
    self.metalFX = metalFX
    self.unlockFrameRate = unlockFrameRate
    self.customResolution = customResolution
    self.proxyHost = proxyHost
    self.debugMode = debugMode
  }
}

public enum LaunchOutcome: Sendable, Equatable {
  case exited
  case failedExit(code: Int32, logPath: URL)
  case failedToLaunch
  /// No game process appeared within the client's startup timeout (LCH-036, #28 15); everything is already cleaned up.
  case startupTimedOut
}

public enum BackgroundImage: Sendable, Equatable {
  case bundledDefault
  case remote(URL)
}

public enum GameClientError: Error, Sendable, Equatable {
  case network
  case insufficientDiskSpace
  case verificationFailed
  /// The game folder is damaged or not the China release (Bilibili); neither update nor repair can start from it.
  case brokenInstallation
  /// The folder chosen for an install holds something else than an interrupted install.
  case installDirectoryNotEmpty
}

/// The seam between the launcher state machine and a concrete game. The client keeps no Game Directory: every
/// operation that reads one takes it as a parameter (`launch` through `LaunchOptions.gameDirectory`).
public protocol GameClient: Sendable {
  /// `directory` is the Game Directory, `nil` when none is chosen yet: the remote state is still reported.
  func status(in directory: URL?) async throws -> GameStatus
  /// Runs `job` and returns once all its work has stopped: when it is done, when it fails, or after a cancellation
  /// (throwing `CancellationError`). `progress` may be called from any thread until then.
  func run(
    _ job: GameJob, in directory: URL, backend: GraphicsBackend,
    progress: @escaping @Sendable (JobProgress) -> Void
  ) async throws
  /// Bytes the job will write after decompression, excluding the chunk-cache margin the launcher adds.
  /// Install: unpacked total. Update and pre-download: download size plus new files. 0 when nothing is written.
  /// This is the launcher's preflight, run before it writes anything, so it also refuses a folder the job could
  /// not use (an install into a folder with other content throws `installDirectoryNotEmpty`) and touches nothing.
  func requiredDiskSpace(for job: GameJob, in directory: URL) async throws -> Int64
  /// `onStarted` fires once the game process exists (launching → running). The client owns the startup timeout: when
  /// no process appears in time it restores Launch Mutations, kills the prefix and returns `.startupTimedOut`.
  /// Cancellation does the same cleanup before returning.
  func launch(_ options: LaunchOptions, onStarted: @escaping @Sendable () -> Void) async throws -> LaunchOutcome
  func backgroundImage() async -> BackgroundImage
  /// Opens an interactive Wine command prompt with the environment of a launch with `options` (CFG-032).
  /// Returns when the prompt is closed.
  func openWineCommandPrompt(_ options: LaunchOptions) async
}

extension GameClient {
  public func openWineCommandPrompt(_ options: LaunchOptions) async {}
}
