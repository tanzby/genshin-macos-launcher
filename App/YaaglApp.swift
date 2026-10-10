import GenshinCN
import Launcher
import Platform
import Sparkle
import SwiftUI

@main
struct YaaglApp: App {
  @State private var launcher = LauncherModel(client: GenshinCNClient())
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
