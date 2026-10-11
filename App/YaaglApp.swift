import GenshinCN
import Launcher
import Platform
import Sparkle
import SwiftUI
import Wine

@main
struct YaaglApp: App {
  @State private var launcher = Self.makeLauncher()

  /// One `WineRuntime` shared by the client (which launches the game with it) and the model (which
  /// prepares it). `prepare()` migrates a TS-launcher data directory before anything reads it; if it
  /// fails the app stops rather than run on a directory it could not migrate.
  private static func makeLauncher() -> LauncherModel {
    let data: DataDirectory
    do {
      // `--autolaunch` may point at a sandbox root; then nothing outside it is cleaned.
      data = try AutoLaunchOptions.current.prepareDataDirectory()
    } catch {
      fatalError("Cannot prepare the data directory: \(error)")
    }
    let wine = WineRuntime(dataDirectory: data)
    return LauncherModel(client: GenshinCNClient.bundled(wine: wine, dataDirectory: data), wine: wine)
  }
  private let autoLaunch = AutoLaunchOptions.current

  // Sparkle refuses to start without an EdDSA public key, so builds made before
  // the key exists (SUPublicEDKey empty) leave the updater stopped. Debug builds
  // never start it: a local build must not offer to replace itself with a release.
  private let updaterController = SPUStandardUpdaterController(
    startingUpdater: Self.startsUpdater,
    updaterDelegate: nil,
    userDriverDelegate: nil
  )

  private let updater: UpdaterModel

  init() {
    updater = UpdaterModel(updater: updaterController.updater)
  }

  private static var startsUpdater: Bool {
    #if DEBUG
      return false
    #else
      let key = Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String
      return key?.isEmpty == false
    #endif
  }

  /// `--autolaunch` (APP-020): drive one session without clicks, log to `<data>/logs/launcher.log`, quit.
  private func runAutoLaunch() async {
    guard autoLaunch.enabled else { return }
    let root = autoLaunch.dataRoot ?? DataDirectory.defaultRoot
    await AutoLaunch.runIfRequested(
      autoLaunch, model: launcher, log: DiagLog(logsDirectory: DataDirectory(root: root).logs)
    ) { NSApp.terminate(nil) }
  }

  var body: some Scene {
    Window("Yaagl", id: "main") {
      MainView()
        .environment(launcher)
        .task { await runAutoLaunch() }
    }
    .commands {
      CommandGroup(after: .appInfo) {
        CheckForUpdatesCommand(updater: updater)
      }
    }

    Settings {
      SettingsView(updater: updater)
    }
  }
}
