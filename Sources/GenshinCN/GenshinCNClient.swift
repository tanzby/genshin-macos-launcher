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
/// The client holds no game folder: each operation gets it as a parameter. It does not order jobs: the launcher's job
/// slots do (`JobCoordinator`), and `run` returns only after its work has stopped.
public final class GenshinCNClient: GameClient {
  let dataDirectory: URL
  let protonExtras: URL
  let launchers: [GraphicsBackend: any GameLaunching]
  let sophon: SophonClient
  let background: BackgroundImageProvider?

  package init(
    dataDirectory: URL,
    protonExtras: URL,
    launcher: (GraphicsBackend) -> any GameLaunching,
    sophon: SophonClient = SophonClient(game: GenshinCN.sophonGame),
    background: BackgroundImageProvider? = nil
  ) {
    self.dataDirectory = dataDirectory
    self.protonExtras = protonExtras
    launchers = Dictionary(uniqueKeysWithValues: GraphicsBackend.allCases.map { ($0, launcher($0)) })
    self.sophon = sophon
    self.background = background
  }

  /// The production composition: the game runs in `wine`'s prefix through a `GameSession`.
  static func live(
    wine: WineRuntime, dataDirectory: DataDirectory, helpers: GameHostHelpers?, protonExtras: URL
  ) -> GenshinCNClient {
    let runner = wine.runner
    return GenshinCNClient(
      dataDirectory: dataDirectory.root, protonExtras: protonExtras,
      launcher: { backend in
        GameSession(
          layout: wine.layout(for: backend), runner: runner, launchServices: SystemLaunchServices(), helpers: helpers)
      },
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
    return GameHostHelpers(shim: shim, dylib: dylib, icon: appBundle.appending(path: "Contents/Resources/AppIcon.icns"))
  }

  /// `GameSession.recover()` for the launcher's startup sequence (`StartupSteps.recoverSession`).
  public func recover(backend: GraphicsBackend) async { await gameLauncher(for: backend).recover() }

  package func gameLauncher(for backend: GraphicsBackend) -> any GameLaunching {
    launchers[backend]!  // filled for every case by init
  }

  // MARK: - Status

  public func status(in directory: URL?) async throws -> GameStatus {
    try await Self.mapping {
      let status = try await sophon.status(in: directory)
      return GameStatus(
        localVersion: status.installedVersion, remoteVersion: status.remoteVersion, canUpdate: status.canUpdate,
        canPreDownload: status.canPreDownload, preDownloadVersion: status.preDownloadVersion)
    }
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

    let recipe = recipe(for: options)
    // The session restores everything itself, also when this Task is cancelled, and returns only afterwards.
    switch await gameLauncher(for: options.graphicsBackend).launch(recipe, onStarted: onStarted) {
    case .exited: return .exited
    case .failedExit(let code, let log): return .failedExit(code: code, logPath: log)
    case .startupTimedOut: return .startupTimedOut
    case .failedToLaunch: return .failedToLaunch
    case .cancelled: throw CancellationError()
    }
  }

  public func openWineCommandPrompt(_ options: LaunchOptions) async {
    _ = await gameLauncher(for: options.graphicsBackend).openCommandPrompt(
      recipe(for: options), gameDirectory: options.gameDirectory)
  }

  private func recipe(for options: LaunchOptions) -> LaunchRecipe {
    GenshinLaunchRecipe.make(
      options: options, dataDirectory: dataDirectory, protonExtras: protonExtras)
  }

  /// The official launcher picture (APP-021); without a provider (tests) the bundled one.
  public func backgroundImage() async -> BackgroundImage {
    await background?.backgroundImage() ?? .bundledDefault
  }

  // MARK: - Errors

  /// Runs `body` and throws what `map` makes of its error.
  static func mapping<Result>(_ body: () async throws -> Result) async throws -> Result {
    do { return try await body() } catch { throw map(error) }
  }

  /// Translates module errors into the ones the launcher knows (`GameClientError`).
  static func map(_ error: any Error) -> any Error {
    switch error {
    case _ where error.isCancellation:
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
