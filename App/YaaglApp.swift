import AppKit
import GenshinCN
import Launcher
import Platform
import Sparkle
import SwiftUI
import Wine

@main
struct YaaglApp: App {
  @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
  @State private var controller: MainController
  @State private var meter = ProgressMeter()
  private let client: GenshinCNClient
  private let notifier: EventNotifier
  private let dataDirectory = DataDirectory.defaultRoot
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
    // `prepare()` migrates a TS-launcher data directory before anything reads it; if it fails the app stops
    // rather than run on a directory it could not migrate. `--autolaunch` may point at a sandbox root.
    let data: DataDirectory
    do {
      data = try AutoLaunchOptions.current.prepareDataDirectory()
    } catch {
      fatalError("Cannot prepare the data directory: \(error)")
    }
    // One `WineRuntime` for the client (launches the game with it) and the model (prepares it).
    let wine = WineRuntime(dataDirectory: data)
    let client = GenshinCNClient.bundled(wine: wine, dataDirectory: data)
    let settings = SettingsModel()
    let onboarding = OnboardingModel(hosts: GenshinCN.hostsBlocklist(), settings: settings)
    // A diagnostic run names its own game folder; it must not touch the one saved in the real preferences.
    let launcher = LauncherModel(
      client: client, wine: wine,
      gameDirectory: AutoLaunchOptions.current.enabled ? AutoLaunchOptions.current.gameDirectory : settings.gameDirectory)
    launcher.makeLaunchOptions = { settings.launchOptions(gameDirectory: $0) }
    let controller = MainController(launcher: launcher, settings: settings, onboarding: onboarding)
    self.client = client
    _controller = State(initialValue: controller)
    notifier = EventNotifier(delivery: UserNotificationDelivery())
    AppDelegate.launcher = launcher
  }

  /// `--autolaunch` (APP-020): drive one session without clicks, log to `<data>/logs/launcher.log`, quit.
  private func runAutoLaunch() async {
    guard autoLaunch.enabled else { return }
    controller.onboarding.refresh()
    let root = autoLaunch.dataRoot ?? DataDirectory.defaultRoot
    await AutoLaunch.runIfRequested(
      autoLaunch, model: controller.launcher, log: DiagLog(logsDirectory: DataDirectory(root: root).logs)
    ) { NSApp.terminate(nil) }
  }

  var body: some Scene {
    Window("Yaagl", id: "main") {
      MainView(
        notifier: notifier, drivenByAutoLaunch: autoLaunch.enabled,
        backgroundProvider: { await client.backgroundImage() })
        .environment(controller)
        .environment(meter)
        .task { await runAutoLaunch() }
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
