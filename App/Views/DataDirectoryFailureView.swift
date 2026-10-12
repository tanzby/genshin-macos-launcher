import AppKit
import Platform
import SwiftUI

/// Why `DataDirectory.prepare()` failed. The app shows it instead of running on a directory it could not
/// migrate (ADR 0001); nothing was deleted for the first two, and the third retries on the next launch.
struct DataDirectoryFailure {
  let message: String
  let root: URL

  init(_ error: any Error, root: URL) {
    self.root = root
    message =
      switch error as? DataDirectory.PrepareError {
      case .unrecognizedMarker:
        String(localized: "The data folder's marker file is damaged. Nothing was deleted. Remove the file .genshin-launcher-native or the whole folder, then reopen Genshin Launcher.")
      case .unsupportedSchemaVersion(let version):
        String(localized: "The data folder was written by a newer version of Genshin Launcher (format \(version)). Update Genshin Launcher, then reopen it.")
      case .cleanupFailed(let url, let detail):
        String(localized: "Genshin Launcher could not remove \(url.path): \(detail). Remove it yourself, then reopen Genshin Launcher.")
      case nil:
        String(localized: "The data folder could not be prepared: \(String(describing: error))")
      }
  }
}

/// Shown in place of the main window when the data directory could not be prepared.
struct DataDirectoryFailureView: View {
  let failure: DataDirectoryFailure

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      Label("Genshin Launcher can't start", systemImage: "exclamationmark.triangle.fill")
        .font(.title2.bold())
      Text(failure.message)
        .textSelection(.enabled)
      Text(failure.root.path)
        .font(.caption)
        .foregroundStyle(.secondary)
        .textSelection(.enabled)
      HStack {
        Button("Show Data Folder in Finder") {
          NSWorkspace.shared.activateFileViewerSelecting([failure.root])
        }
        Spacer()
        Button("Quit") { NSApp.terminate(nil) }
          .keyboardShortcut(.defaultAction)
      }
    }
    .padding(28)
    .frame(width: 520)
  }
}
