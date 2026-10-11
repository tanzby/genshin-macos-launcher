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
      data = try DataDirectory.prepare()
    } catch {
      fatalError("Cannot prepare the data directory: \(error)")
    }
    let wine = WineRuntime(dataDirectory: data)
    return LauncherModel(client: GenshinCNClient.bundled(wine: wine, dataDirectory: data), wine: wine)
  }

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

  var body: some Scene {
    Window("Yaagl", id: "main") {
      MainView()
        .environment(launcher)
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
