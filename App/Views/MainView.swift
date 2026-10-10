import AppKit
import GenshinCN
import Launcher
import SwiftUI

struct MainView: View {
  @Environment(MainController.self) private var controller
  @Environment(ProgressMeter.self) private var meter
  let notifier: EventNotifier
  let backgroundProvider: @Sendable () async -> BackgroundImage
  @State private var background: BackgroundImage = .bundledDefault

  var body: some View {
    ZStack(alignment: .bottom) {
      BackgroundView(source: background)
      CapsuleView(chooseGameDirectory: { GameFolderPicker.choose(into: controller) })
    }
    .frame(minWidth: 880, minHeight: 495)
    .ignoresSafeArea()
    .sheet(isPresented: .constant(!controller.onboarding.isComplete)) {
      OnboardingView()
        .interactiveDismissDisabled()
    }
    .task { await controller.refresh() }
    .task { background = await backgroundProvider() }
    .task {
      for await event in controller.launcher.events { await notifier.handle(event) }
    }
    .onChange(of: controller.launcher.status) { _, status in
      Task { await notifier.observe(status: status) }
    }
    .onChange(of: controller.launcher.progress) { _, progress in meter.update(progress) }
    .onChange(of: controller.settings.gameDirectory) { _, _ in Task { await controller.refresh() } }
    .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
      Task { await controller.refreshWhenIdle() }
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
        _ = try GameDirectoryValidator.validate(
          url, gameExecutable: GenshinCN.executableName, isSupportedPath: GenshinLaunchRecipe.isSupported)
        controller.onboarding.useGameDirectory(url)
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
