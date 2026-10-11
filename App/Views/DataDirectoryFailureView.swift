import AppKit
import Platform
import SwiftUI

/// Why `DataDirectory.prepare()` failed. The app shows it instead of running on a directory it could not
/// migrate (ADR 0001); nothing was deleted for the first two, and the third retries on the next launch.
struct DataDirectoryFailure {
  enum Reason {
    case unrecognizedMarker
    case unsupportedSchemaVersion(Int)
    case cleanupFailed(URL, String)
    case other(String)
  }

  let reason: Reason
  let root: URL

  init(_ error: any Error, root: URL) {
    self.root = root
    switch error as? DataDirectory.PrepareError {
    case .unrecognizedMarker: reason = .unrecognizedMarker
    case .unsupportedSchemaVersion(let version): reason = .unsupportedSchemaVersion(version)
    case .cleanupFailed(let url, let detail): reason = .cleanupFailed(url, detail)
    case nil: reason = .other(String(describing: error))
    }
  }

  var message: String {
    switch reason {
    case .unrecognizedMarker:
      String(localized: "The data folder's marker file is damaged. Nothing was deleted. Remove the file .yaagl-native or the whole folder, then reopen Yaagl.")
    case .unsupportedSchemaVersion(let version):
      String(localized: "The data folder was written by a newer version of Yaagl (format \(version)). Update Yaagl, then reopen it.")
    case .cleanupFailed(let url, let detail):
      String(localized: "Yaagl could not remove \(url.path): \(detail). Remove it yourself, then reopen Yaagl.")
    case .other(let detail):
      String(localized: "The data folder could not be prepared: \(detail)")
    }
  }
}

/// Shown in place of the main window when the data directory could not be prepared.
struct DataDirectoryFailureView: View {
  let failure: DataDirectoryFailure

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      Label("Yaagl can't start", systemImage: "exclamationmark.triangle.fill")
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
