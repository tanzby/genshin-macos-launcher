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

/// The update controls for the Settings window. Embedded in the General page of the Settings window.
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
