import AppKit
import GenshinCN
import Launcher
import Platform
import Sparkle
import SwiftUI
import Wine

/// Everything built on a prepared data directory.
@MainActor
struct AppRuntime {
  let controller: MainController
  let client: GenshinCNClient
  let notifier: EventNotifier
  let dataDirectory: DataDirectory

  /// `prepare()` migrates a TS-launcher data directory before anything reads it, so nothing here is built
  /// when it fails. `--autolaunch` may point at a sandbox root.
  init(autoLaunch: AutoLaunchOptions) throws {
    let data = try autoLaunch.prepareDataDirectory()
    // One `WineRuntime` for the client (launches the game with it) and the model (prepares it).
    let wine = WineRuntime(dataDirectory: data)
    let client = GenshinCNClient.bundled(wine: wine, dataDirectory: data)
    let settings = SettingsModel()
    let onboarding = OnboardingModel(hosts: GenshinCN.hostsBlocklist(), settings: settings)
    // A diagnostic run names its own game folder; it must not touch the one saved in the real preferences.
    let launcher = LauncherModel(
      client: client, wine: wine,
      startup: StartupSteps(
        rosettaInstalled: { StartupSteps.isRosettaInstalled() }, recoverSession: { await client.recover() }),
      gameDirectory: autoLaunch.enabled ? autoLaunch.gameDirectory : settings.gameDirectory)
    launcher.makeLaunchOptions = { settings.launchOptions(gameDirectory: $0) }
    controller = MainController(launcher: launcher, settings: settings, onboarding: onboarding)
    self.client = client
    notifier = EventNotifier(delivery: UserNotificationDelivery())
    dataDirectory = data
    AppDelegate.launcher = launcher
  }
}

@main
struct YaaglApp: App {
  @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
  @State private var meter = ProgressMeter()
  private let runtime: AppRuntime?
  private let startupFailure: DataDirectoryFailure?
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
    do {
      runtime = try AppRuntime(autoLaunch: autoLaunch)
      startupFailure = nil
    } catch {
      runtime = nil
      let failure = DataDirectoryFailure(error, root: autoLaunch.dataRoot ?? DataDirectory.defaultRoot)
      startupFailure = failure
      // `--autolaunch` has no one to read the window: leave the verdict `yaagl-diag` polls for, and exit.
      if autoLaunch.enabled {
        let log = DiagLog(logsDirectory: DataDirectory(root: failure.root).logs)
        log.reset()
        AutoLaunch.reportPrepareFailure(error, to: log)
        FileHandle.standardError.write(Data("yaagl: \(failure.message)\n".utf8))
        exit(1)
      }
    }
  }

  /// `--autolaunch` (APP-020): drive one session without clicks, log to `<data>/logs/launcher.log`, quit.
  private func runAutoLaunch(_ runtime: AppRuntime) async {
    guard autoLaunch.enabled else { return }
    runtime.controller.onboarding.refresh()
    await AutoLaunch.runIfRequested(
      autoLaunch, model: runtime.controller.launcher, log: DiagLog(logsDirectory: runtime.dataDirectory.logs)
    ) { NSApp.terminate(nil) }
  }

  var body: some Scene {
    Window("Yaagl", id: "main") {
      if let runtime {
        MainView(
          notifier: runtime.notifier, drivenByAutoLaunch: autoLaunch.enabled,
          backgroundProvider: { await runtime.client.backgroundImage() })
          .environment(runtime.controller)
          .environment(meter)
          .task { await runAutoLaunch(runtime) }
      } else if let startupFailure {
        DataDirectoryFailureView(failure: startupFailure)
      }
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
      if let runtime {
        SettingsView(dataDirectory: runtime.dataDirectory.root, updater: updater)
          .environment(runtime.controller)
      }
    }
  }
}

/// Stops jobs cleanly on quit (the unfinished one keeps its `job.json`) and asks before ending a running game.
final class AppDelegate: NSObject, NSApplicationDelegate {
  @MainActor static var launcher: LauncherModel?

  func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

  func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
    guard let launcher = Self.launcher, launcher.quitPlan != .quitNow else { return .terminateNow }
    if launcher.quitPlan == .confirmThenShutDown {
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
