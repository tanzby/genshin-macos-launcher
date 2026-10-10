import GenshinCN
import Launcher
import Platform
import Sparkle
import SwiftUI
import Wine

@main
struct YaaglApp: App {
  @State private var launcher = LauncherModel(client: Self.makeClient())

  private static func makeClient() -> GenshinCNClient {
    let data = DataDirectory(root: DataDirectory.defaultRoot)
    return GenshinCNClient.bundled(wine: WineRuntime(dataDirectory: data), dataDirectory: data)
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
