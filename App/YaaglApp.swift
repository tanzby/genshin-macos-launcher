import GenshinCN
import Launcher
import Sparkle
import SwiftUI

@main
struct YaaglApp: App {
  @State private var launcher = LauncherModel(client: GenshinCNClient())

  // Sparkle refuses to start without an EdDSA public key, so builds made before
  // the key exists (SUPublicEDKey empty) leave the updater stopped. Debug builds
  // never start it: a local build must not offer to replace itself with a release.
  private let updaterController = SPUStandardUpdaterController(
    startingUpdater: Self.startsUpdater,
    updaterDelegate: nil,
    userDriverDelegate: nil
  )

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
        Button("Check for Updates…") {
          updaterController.checkForUpdates(nil)
        }
      }
    }
  }
}
