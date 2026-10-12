import AppKit
import Launcher
import SwiftUI

/// First-run guidance: the hosts block is required, then the game folder.
struct OnboardingView: View {
  @Environment(MainController.self) private var controller

  var body: some View {
    let onboarding = controller.onboarding
    VStack(alignment: .leading, spacing: 20) {
      Text("Welcome to Genshin Launcher")
        .font(.largeTitle.bold())
      Text("Two quick steps before the game can start.")
        .foregroundStyle(.secondary)

      StepRow(
        number: 1, title: "Block telemetry",
        detail: "Genshin Launcher adds a marked section to /etc/hosts that sends the game's telemetry domains to 0.0.0.0. The game will not start without it. macOS asks for your administrator password.",
        isDone: onboarding.allowsLaunch
      ) {
        if !onboarding.allowsLaunch {
          Button("Block Telemetry…") { Task { await onboarding.applyHosts() } }
            .buttonStyle(.glassProminent)
            .disabled(onboarding.isApplyingHosts)
          if let error = onboarding.hostsError {
            Text(error).font(.caption).foregroundStyle(.red).lineLimit(3)
          }
        }
      }

      StepRow(
        number: 2, title: "Choose the game folder",
        detail: "Pick an empty folder to install into, or the folder of an existing installation. It can be on an external drive.",
        isDone: onboarding.hasUsableGameDirectory
      ) {
        if onboarding.step == .gameDirectory {
          Button("Choose Folder…") { _ = GameFolderPicker.choose(into: controller) }
            .buttonStyle(.glassProminent)
        } else if let url = controller.settings.gameDirectory {
          Text(url.path).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
        }
      }
    }
    .padding(28)
    .frame(width: 520)
    .background(AllowsTermination())
  }
}

private struct StepRow<Actions: View>: View {
  let number: Int
  let title: LocalizedStringKey
  let detail: LocalizedStringKey
  let isDone: Bool
  @ViewBuilder var actions: Actions

  var body: some View {
    HStack(alignment: .top, spacing: 14) {
      Image(systemName: isDone ? "checkmark.circle.fill" : "\(number).circle")
        .font(.title)
        .foregroundStyle(isDone ? AnyShapeStyle(.green) : AnyShapeStyle(.secondary))
        .accessibilityHidden(true)
      VStack(alignment: .leading, spacing: 8) {
        Text(title).font(.headline)
        Text(detail).font(.callout).foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
        actions
      }
    }
  }
}

/// AppKit refuses `terminate(_:)` while a sheet is up (`preventsApplicationTerminationWhenModal`, true by default),
/// so Quit and Sparkle's "Install and Relaunch" did nothing while the first-run sheet was open. The sheet holds no
/// unsaved work: put the setting back on the sheet's own window.
private struct AllowsTermination: NSViewRepresentable {
  func makeNSView(context: Context) -> NSView { Anchor() }
  func updateNSView(_ view: NSView, context: Context) {}

  private final class Anchor: NSView {
    override func viewDidMoveToWindow() {
      super.viewDidMoveToWindow()
      window?.preventsApplicationTerminationWhenModal = false
    }
  }
}
