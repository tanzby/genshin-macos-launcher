import SwiftUI

struct CheckForUpdatesCommand: View {
  let updater: UpdaterModel

  var body: some View {
    Button("Check for Updates…") {
      updater.checkForUpdates()
    }
    .disabled(!updater.canCheckForUpdates)
  }
}

/// The update controls for the Settings window. The General pane (#14) can embed it as a section.
struct UpdateSettingsSection: View {
  @Bindable var updater: UpdaterModel

  var body: some View {
    Section {
      Toggle("Automatically check for updates", isOn: $updater.automaticallyChecksForUpdates)
      Button("Check Now") {
        updater.checkForUpdates()
      }
      .disabled(!updater.canCheckForUpdates)
    } header: {
      Text("Updates")
    }
  }
}

struct SettingsView: View {
  let updater: UpdaterModel

  var body: some View {
    Form {
      UpdateSettingsSection(updater: updater)
    }
    .formStyle(.grouped)
    .frame(width: 420)
    .fixedSize(horizontal: false, vertical: true)
  }
}
