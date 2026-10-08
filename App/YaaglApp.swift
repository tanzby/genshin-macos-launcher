import GenshinCN
import Launcher
import Sparkle
import SwiftUI

@main
struct YaaglApp: App {
  @State private var launcher = LauncherModel(client: GenshinCNClient())

  // Sparkle refuses to start without an EdDSA public key, so builds made before
  // the key exists (SUPublicEDKey empty) leave the updater stopped.
  private let updaterController = SPUStandardUpdaterController(
    startingUpdater: Self.hasUpdateKey,
    updaterDelegate: nil,
    userDriverDelegate: nil
  )

  private static var hasUpdateKey: Bool {
    let key = Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String
    return key?.isEmpty == false
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
