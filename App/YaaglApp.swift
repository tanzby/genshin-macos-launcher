import AppKit
import GenshinCN
import Launcher
import Platform
import Sparkle
import SwiftUI

@main
struct YaaglApp: App {
  @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
  @State private var controller: MainController
  @State private var meter = ProgressMeter()
  private let client: GenshinCNClient
  private let notifier: EventNotifier
  private let dataDirectory = DataDirectory.defaultRoot

  // Sparkle refuses to start without an EdDSA public key, so builds made before
  // the key exists (SUPublicEDKey empty) leave the updater stopped. Debug builds
  // never start it: a local build must not offer to replace itself with a release.
  private let updaterController = SPUStandardUpdaterController(
    startingUpdater: Self.startsUpdater,
    updaterDelegate: nil,
    userDriverDelegate: nil
  )

  private let updater: UpdaterModel

  private static var startsUpdater: Bool {
    #if DEBUG
      return false
    #else
      let key = Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String
      return key?.isEmpty == false
    #endif
  }

  init() {
    updater = UpdaterModel(updater: updaterController.updater)
    let client = GenshinCNClient()
    let settings = SettingsModel()
    let onboarding = OnboardingModel(hosts: GenshinCN.hostsBlocklist(), settings: settings)
    let launcher = LauncherModel(client: client, gameDirectory: settings.gameDirectory)
    let controller = MainController(launcher: launcher, settings: settings, onboarding: onboarding)
    self.client = client
    _controller = State(initialValue: controller)
    notifier = EventNotifier(delivery: UserNotificationDelivery())
    AppDelegate.launcher = launcher
  }

  var body: some Scene {
    Window("Yaagl", id: "main") {
      MainView(notifier: notifier, backgroundProvider: { await client.backgroundImage() })
        .environment(controller)
        .environment(meter)
    }
    .windowStyle(.hiddenTitleBar)
    .windowResizability(.contentMinSize)
    .commands {
      CommandGroup(replacing: .appInfo) {
        Button("About Yaagl") {
          NSApp.orderFrontStandardAboutPanel(options: [.credits: Credits.attributed])
        }
      }
      CommandGroup(after: .appInfo) {
        CheckForUpdatesCommand(updater: updater)
      }
    }

    Settings {
      SettingsView(dataDirectory: dataDirectory, updater: updater)
        .environment(controller)
    }
  }
}

/// Stops jobs cleanly on quit (the unfinished one keeps its `job.json`) and asks before ending a running game.
final class AppDelegate: NSObject, NSApplicationDelegate {
  @MainActor static var launcher: LauncherModel?

  func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

  func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
    guard let launcher = Self.launcher, launcher.phase != .idle else { return .terminateNow }
    if launcher.phase == .running {
      let alert = NSAlert()
      alert.messageText = String(localized: "The game is still running")
      alert.informativeText = String(localized: "Quitting Yaagl will close the game.")
      alert.addButton(withTitle: String(localized: "Quit"))
      alert.addButton(withTitle: String(localized: "Cancel"))
      guard alert.runModal() == .alertFirstButtonReturn else { return .terminateCancel }
    }
    Task { @MainActor in
      await launcher.shutdown()
      sender.reply(toApplicationShouldTerminate: true)
    }
    return .terminateLater
  }
}
