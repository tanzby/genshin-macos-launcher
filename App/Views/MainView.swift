import AppKit
import Launcher
import SwiftUI

struct MainView: View {
  @Environment(MainController.self) private var controller
  let notifier: EventNotifier
  /// `--autolaunch` drives the launcher itself (APP-020); the window must not start Wine preparation in parallel.
  let drivenByAutoLaunch: Bool
  let backgroundProvider: @Sendable () async -> BackgroundImage
  @State private var background: BackgroundImage = .bundledDefault

  var body: some View {
    ZStack(alignment: .bottom) {
      BackgroundView(source: background)
      CapsuleView(chooseGameDirectory: { GameFolderPicker.choose(into: controller) })
    }
    .frame(minWidth: 880, minHeight: 495)
    .ignoresSafeArea()
    .sheet(isPresented: .constant(controller.onboarding.showsSheet(unattended: drivenByAutoLaunch))) {
      OnboardingView()
        .interactiveDismissDisabled()
    }
    .task { if !drivenByAutoLaunch { await controller.refresh() } }
    .task { background = await backgroundProvider() }
    .task { await controller.deliverNotifications(to: notifier) }
    .modifier(LauncherObservers(drivenByAutoLaunch: drivenByAutoLaunch))
    .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
      if !drivenByAutoLaunch { Task { await controller.refreshWhenIdle() } }
    }
  }
}

/// The `onChange` handlers that follow the settings, in their own modifier so they invalidate this body only.
private struct LauncherObservers: ViewModifier {
  @Environment(MainController.self) private var controller
  let drivenByAutoLaunch: Bool

  func body(content: Content) -> some View {
    content
      .onChange(of: controller.settings.gameDirectory) { _, _ in
        if !drivenByAutoLaunch { Task { await controller.refresh() } }
      }
  }
}

/// `NSOpenPanel` for the game folder. Returns whether a valid folder was stored.
@MainActor
enum GameFolderPicker {
  static func choose(into controller: MainController) -> Bool {
    let panel = NSOpenPanel()
    panel.canChooseDirectories = true
    panel.canChooseFiles = false
    panel.canCreateDirectories = true
    panel.allowsMultipleSelection = false
    panel.prompt = String(localized: "Choose")
    panel.message = String(localized: "Choose an empty folder to install the game into, or the folder of an existing installation.")
    while panel.runModal() == .OK, let url = panel.url {
      do {
        try controller.onboarding.chooseGameDirectory(url)
        return true
      } catch let problem as GameDirectoryProblem {
        let alert = NSAlert()
        alert.messageText = String(localized: "This folder cannot be used")
        alert.informativeText = problem.explanation
        alert.runModal()
      } catch {
        return false
      }
    }
    return false
  }
}

extension GameDirectoryProblem {
  var explanation: String {
    switch self {
    case .missing: String(localized: "The folder does not exist.")
    case .notADirectory: String(localized: "That is a file, not a folder.")
    case .unsupportedPath: String(localized: "The folder path contains a quotation mark or a line break.")
    case .unreadable: String(localized: "The folder cannot be read.")
    case .notEmpty: String(localized: "The folder is not empty and does not contain the game.")
    }
  }
}
