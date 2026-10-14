import Foundation
import Launcher
import Platform
import Sophon
import Wine

/// What `GenshinCNClient` needs from the Wine side to start the game. `GameSession` is the production implementation.
package protocol GameLaunching: Sendable {
  func launch(_ recipe: LaunchRecipe, onStarted: @escaping @Sendable () -> Void) async -> LaunchResult
  func recover() async
  func openCommandPrompt(_ recipe: LaunchRecipe, gameDirectory: URL?) async -> Int32?
}

extension GameSession: GameLaunching {}

/// Composes Sophon, Wine and Platform into the `GameClient` for Genshin Impact, China server.
///
/// The client holds no game folder: each operation gets it as a parameter. `run(_:in:)` jobs are serialized: a job starts only after the
/// previous one, paused or not, has really returned.
public final class GenshinCNClient: GameClient {
  let dataDirectory: URL
  let protonExtras: URL
  let launcher: any GameLaunching
  let sophon: SophonClient
  let background: BackgroundImageProvider?
  let serializer = JobSerializer()

  package init(
    dataDirectory: URL,
    protonExtras: URL,
    launcher: any GameLaunching,
    sophon: SophonClient = SophonClient(game: GenshinCN.sophonGame),
    background: BackgroundImageProvider? = nil
  ) {
    self.dataDirectory = dataDirectory
    self.protonExtras = protonExtras
    self.launcher = launcher
    self.sophon = sophon
    self.background = background
  }

  /// The production composition: the game runs in `wine`'s prefix through a `GameSession`.
  static func live(
    wine: WineRuntime, dataDirectory: DataDirectory, helpers: GameHostHelpers?, protonExtras: URL
  ) -> GenshinCNClient {
    let session = GameSession(
      layout: wine.layout, runner: SystemProcessRunner(allowedRoots: [wine.runtimeDirectory]),
      launchServices: SystemLaunchServices(), helpers: helpers)
    return GenshinCNClient(
      dataDirectory: dataDirectory.root, protonExtras: protonExtras, launcher: session,
      background: BackgroundImageProvider(cacheDirectory: dataDirectory.background))
  }

  /// The composition for the app: helpers and protonextras come from `bundle` (`Contents/Helpers`, `Resources`).
  public static func bundled(
    wine: WineRuntime, dataDirectory: DataDirectory, bundle: Bundle
  ) -> GenshinCNClient {
    live(
      wine: wine, dataDirectory: dataDirectory, helpers: helpers(in: bundle.bundleURL),
      protonExtras: (bundle.resourceURL ?? bundle.bundleURL).appending(path: "protonextras", directoryHint: .isDirectory))
  }

  /// The Game Mode helpers inside an app bundle, or `nil` when either is missing (the game then starts
  /// without Game Mode, LCH-023).
  static func helpers(in appBundle: URL) -> GameHostHelpers? {
    let directory = appBundle.appending(path: "Contents/Helpers", directoryHint: .isDirectory)
    let shim = directory.appending(path: "genshin-launcher-wine-shim")
    let dylib = directory.appending(path: "genshin-launcher-gamehost.dylib")
    let fileManager = FileManager.default
    guard fileManager.fileExists(atPath: shim.path), fileManager.fileExists(atPath: dylib.path) else { return nil }
    return GameHostHelpers(shim: shim, dylib: dylib)
  }

  /// `GameSession.recover()` for the launcher's startup sequence (`StartupSteps.recoverSession`).
  public func recover() async { await launcher.recover() }

  public func quiesce() async { await serializer.waitUntilIdle() }

  // MARK: - Status

  public func status(in directory: URL?) async throws -> GameStatus {
    do { return try await loadStatus(in: directory) } catch { throw Self.map(error) }
  }

  private func loadStatus(in directory: URL?) async throws -> GameStatus {
    let status = try await sophon.status(in: directory)
    return GameStatus(
      localVersion: status.installedVersion, remoteVersion: status.remoteVersion, canUpdate: status.canUpdate,
      canPreDownload: status.canPreDownload, preDownloadVersion: status.preDownloadVersion)
  }

  // MARK: - Launch

  public func launch(
    _ options: LaunchOptions, onStarted: @escaping @Sendable () -> Void
  ) async throws -> LaunchOutcome {
    let directory = options.gameDirectory
    // An unsupported path (LCH-010) or an empty folder has nothing to launch.
    guard GenshinLaunchRecipe.isSupported(gameDirectory: directory),
      FileManager.default.fileExists(atPath: directory.appending(path: GenshinCN.executableName).path)
    else { return .failedToLaunch }
    // The game is not running (the launcher holds the exclusive slot), so leftovers can be put back.
    GenshinGameFiles.healBackups(in: directory)

    let recipe = recipe(for: options)
    // The session restores everything itself, also when this Task is cancelled, and returns only afterwards.
    switch await launcher.launch(recipe, onStarted: onStarted) {
    case .exited: return .exited
    case .failedExit(let code, let log): return .failedExit(code: code, logPath: log)
    case .startupTimedOut, .failedToLaunch: return .failedToLaunch
    case .cancelled: throw CancellationError()
    }
  }

  public func openWineCommandPrompt(_ options: LaunchOptions) async {
    _ = await launcher.openCommandPrompt(recipe(for: options), gameDirectory: options.gameDirectory)
  }

  private func recipe(for options: LaunchOptions) -> LaunchRecipe {
    GenshinLaunchRecipe.make(
      settings: GenshinLaunchSettings(options), gameDirectory: options.gameDirectory, dataDirectory: dataDirectory,
      protonExtras: protonExtras)
  }

  /// The official launcher picture (APP-021); without a provider (tests) the bundled one.
  public func backgroundImage() async -> BackgroundImage {
    await background?.backgroundImage() ?? .bundledDefault
  }

  // MARK: - Errors

  /// Translates module errors into the ones the launcher knows (`GameClientError`).
  static func map(_ error: any Error) -> any Error {
    switch error {
    case is CancellationError:
      return error
    case let error as URLError where error.code == .cancelled:
      return CancellationError()
    case _ where SophonError.isOffline(error):
      return GameClientError.network
    case let error as SophonError:
      switch error {
      case .checksumMismatch, .verificationFailed: return GameClientError.verificationFailed
      case .brokenInstallation: return GameClientError.brokenInstallation
      case .installDirectoryNotEmpty: return GameClientError.installDirectoryNotEmpty
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
