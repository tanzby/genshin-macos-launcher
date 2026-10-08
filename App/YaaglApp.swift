import GenshinCN
import Launcher
import Sparkle
import SwiftUI

@main
struct YaaglApp: App {
  @State private var launcher = LauncherModel(client: GenshinCNClient())

  // Sparkle starts once the appcast URL and EdDSA public key are in Info.plist.
  private let updaterController = SPUStandardUpdaterController(
    startingUpdater: false,
    updaterDelegate: nil,
    userDriverDelegate: nil
  )

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
