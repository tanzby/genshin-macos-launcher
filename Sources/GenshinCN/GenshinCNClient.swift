import Foundation
import Launcher
import Platform
import Sophon
import Synchronization
import Wine

public enum GenshinCNClientError: Error, Sendable, Equatable {
  case noGameDirectory
  /// The folder holds no (complete) install, so there is nothing to update or repair.
  case notInstalled
  /// Repair needs the latest version (REP-002); update first.
  case outdated(installed: String, latest: String)
  /// The installed version is already the latest (UPG-006).
  case noUpdate
  /// The server has no pre-download newer than the installed version.
  case noPreDownload
}

/// What `GenshinCNClient` needs from the Wine side to start the game. `GameSession` is the production implementation.
public protocol GameLaunching: Sendable {
  func launch(_ recipe: LaunchRecipe, onStarted: @escaping @Sendable () -> Void) async -> LaunchResult
}

extension GameSession: GameLaunching {}

/// Composes Sophon, Wine and Platform into the `GameClient` for Genshin Impact, China server.
///
/// The client works on one game folder at a time, which the launcher hands over with `setGameDirectory(_:)`
/// (`GameClient`'s job methods take no path). `run(_:)` jobs are serialized: a job starts only after the
/// previous one, paused or not, has really returned.
public final class GenshinCNClient: GameClient {
  let dataDirectory: URL
  let protonExtras: URL
  let launcher: any GameLaunching
  let sophon: SophonAPI
  let downloader: SophonDownloader
  let updater: SophonUpdater
  private let location = Mutex<URL?>(nil)
  let serializer = JobSerializer()

  public init(
    dataDirectory: URL,
    protonExtras: URL,
    launcher: any GameLaunching,
    sophon: SophonAPI = SophonAPI(),
    downloader: SophonDownloader = SophonDownloader(),
    updater: SophonUpdater = SophonUpdater()
  ) {
    self.dataDirectory = dataDirectory
    self.protonExtras = protonExtras
    self.launcher = launcher
    self.sophon = sophon
    self.downloader = downloader
    self.updater = updater
  }

  /// The production composition: the game runs in `wine`'s prefix through a `GameSession`.
  public static func live(
    wine: WineRuntime, dataDirectory: DataDirectory, helpers: GameHostHelpers?, protonExtras: URL
  ) -> GenshinCNClient {
    let session = GameSession(
      layout: wine.layout, runner: SystemProcessRunner(allowedRoots: [wine.runtimeDirectory]),
      launchServices: SystemLaunchServices(), helpers: helpers)
    return GenshinCNClient(dataDirectory: dataDirectory.root, protonExtras: protonExtras, launcher: session)
  }

  /// The composition for the app: helpers and protonextras come from `bundle` (`Contents/Helpers`, `Resources`).
  public static func bundled(
    wine: WineRuntime, dataDirectory: DataDirectory, bundle: Bundle = .main
  ) -> GenshinCNClient {
    live(
      wine: wine, dataDirectory: dataDirectory, helpers: helpers(in: bundle.bundleURL),
      protonExtras: (bundle.resourceURL ?? bundle.bundleURL).appending(path: "protonextras", directoryHint: .isDirectory))
  }

  /// The Game Mode helpers inside an app bundle, or `nil` when either is missing (the game then starts
  /// without Game Mode, LCH-023).
  static func helpers(in appBundle: URL) -> GameHostHelpers? {
    let directory = appBundle.appending(path: "Contents/Helpers", directoryHint: .isDirectory)
    let shim = directory.appending(path: "yaagl-wine-shim")
    let dylib = directory.appending(path: "yaagl-gamehost")
    let fileManager = FileManager.default
    guard fileManager.fileExists(atPath: shim.path), fileManager.fileExists(atPath: dylib.path) else { return nil }
    return GameHostHelpers(shim: shim, dylib: dylib)
  }

  public func setGameDirectory(_ url: URL?) {
    location.withLock { $0 = url }
  }

  var gameDirectory: URL? { location.withLock { $0 } }

  func requireGameDirectory() throws -> URL {
    guard let directory = gameDirectory else { throw GenshinCNClientError.noGameDirectory }
    return directory
  }

  // MARK: - Status

  public func status() async throws -> GameStatus {
    let directory = gameDirectory
    // A folder that is not a China-release install reads as "no install"; the install then refuses it by name.
    let installed = directory.flatMap { (try? SophonInstallation.installedVersion(in: $0)) ?? nil }
    let branches: SophonGameBranches
    do {
      branches = try await sophon.gameBranches()
    } catch where Self.isOffline(error) {
      return GameStatus(localVersion: installed)
    }
    guard let main = branches.main else { throw SophonError.malformedResponse }

    var status = GameStatus(localVersion: installed, remoteVersion: main.tag)
    guard let installed, let directory else { return status }
    status.canUpdate = SophonVersion.isOlder(installed, than: main.tag)
    if let pre = branches.preDownload, SophonVersion.isOlder(installed, than: pre.tag) {
      status.preDownloadVersion = pre.tag
      status.canPreDownload =
        pre.diffTags.contains(installed)
        && !SophonUpdater.isPredownloaded(
          pre.tag, from: installed, in: SophonInstallation.tempDirectory(in: directory))
    }
    return status
  }

  // MARK: - Launch

  public func launch(
    _ options: LaunchOptions, onStarted: @escaping @Sendable () -> Void
  ) async throws -> LaunchOutcome {
    let directory = options.gameDirectory
    // `cmd` cannot take such a path in config.bat (LCH-011); an empty folder has nothing to launch.
    guard GenshinLaunchRecipe.isSupported(gameDirectory: directory),
      FileManager.default.fileExists(atPath: directory.appending(path: GenshinCN.executableName).path)
    else { return .failedToLaunch }
    // The game is not running (the launcher holds the exclusive slot), so leftovers can be put back.
    GenshinGameFiles.healBackups(in: directory)

    let recipe = GenshinLaunchRecipe.make(
      settings: GenshinLaunchSettings(options), gameDirectory: directory, dataDirectory: dataDirectory,
      protonExtras: protonExtras)
    // The session restores everything itself, also when this Task is cancelled, and returns only afterwards.
    switch await launcher.launch(recipe, onStarted: onStarted) {
    case .exited: return .exited
    case .failedExit(let code, let log): return .failedExit(code: code, logPath: log)
    case .startupTimedOut, .failedToLaunch: return .failedToLaunch
    case .cancelled: throw CancellationError()
    }
  }

  /// Not implemented yet (ticket #39): the launcher shows the bundled picture.
  public func backgroundImage() async -> BackgroundImage {
    .bundledDefault
  }

  // MARK: - Errors

  static func isOffline(_ error: any Error) -> Bool {
    switch error {
    case is URLError: true
    case let error as SophonError:
      switch error {
      case .transport, .http: true
      default: false
      }
    default: false
    }
  }

  /// Translates module errors into the ones the launcher knows (`GameClientError`).
  static func map(_ error: any Error) -> any Error {
    switch error {
    case is CancellationError:
      return error
    case let error as URLError:
      return error.code == .cancelled ? CancellationError() : GameClientError.network
    case let error as SophonError:
      switch error {
      case .transport, .http: return GameClientError.network
      case .checksumMismatch, .verificationFailed: return GameClientError.verificationFailed
      default: return error
      }
    case let error as CocoaError where error.code == .fileWriteOutOfSpace:
      return GameClientError.insufficientDiskSpace
    case let error as POSIXError where error.code == .ENOSPC:
      return GameClientError.insufficientDiskSpace
    default:
      return error
    }
  }
}
