import AppKit
import Launcher
import SwiftUI

/// The single Liquid Glass capsule at the bottom: status area, primary button, "…" menu (#21).
struct CapsuleView: View {
  @Environment(MainController.self) private var controller
  let chooseGameDirectory: () -> Bool

  var body: some View {
    let presentation = controller.presentation
    GlassEffectContainer {
      HStack(spacing: 12) {
        if presentation.status != .none {
          StatusArea(status: presentation.status, canPreDownload: presentation.canPreDownload)
            .padding(.leading, 14)
            .transition(.opacity.combined(with: .move(edge: .trailing)))
        }
        Button {
          Task { await tap(presentation.button) }
        } label: {
          Text(presentation.button.title)
            .frame(minWidth: 96)
        }
        .buttonStyle(.glassProminent)
        .controlSize(.extraLarge)
        .disabled(!presentation.buttonEnabled)
        MoreMenu(canRepair: presentation.canRepair)
      }
      .padding(6)
      .glassEffect(.regular, in: .capsule)
    }
    .animation(.smooth, value: presentation.status != .none)
    .padding(.bottom, 28)
    .padding(.horizontal, 28)
  }

  private func tap(_ button: PrimaryButton) async {
    if controller.needsGameDirectory(for: button), !chooseGameDirectory() { return }
    await controller.perform(button)
  }
}

private struct MoreMenu: View {
  @Environment(MainController.self) private var controller
  @Environment(\.openSettings) private var openSettings
  let canRepair: Bool

  var body: some View {
    Menu {
      Button("Check File Integrity") { Task { await controller.repair() } }
        .disabled(!canRepair)
      Button("Open Game Folder") {
        if let url = controller.settings.gameDirectory { NSWorkspace.shared.open(url) }
      }
      .disabled(controller.settings.gameDirectory == nil)
      Divider()
      Button("Settings…") { openSettings() }
    } label: {
      Image(systemName: "ellipsis")
        .frame(width: 22, height: 22)
    }
    .menuStyle(.button)
    .buttonStyle(.glass)
    .controlSize(.extraLarge)
    .menuIndicator(.hidden)
    .accessibilityLabel("More")
  }
}

private struct StatusArea: View {
  @Environment(MainController.self) private var controller
  @Environment(ProgressMeter.self) private var meter
  let status: StatusLine
  let canPreDownload: Bool

  var body: some View {
    HStack(spacing: 12) {
      VStack(alignment: .leading, spacing: 4) {
        Text(headline)
          .font(.callout.weight(.medium))
          .lineLimit(1)
        if let detail {
          Text(detail)
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
        if let progress = movingProgress {
          // A `nil` fraction renders the indeterminate bar (PRG-005).
          ProgressView(value: progress.fraction)
            .progressViewStyle(.linear)
        }
      }
      .frame(minWidth: 180, maxWidth: 360, alignment: .leading)
      accessory
    }
  }

  /// The progress of a job that is moving (not paused), when the status is a job at all.
  private var movingProgress: JobProgress? {
    switch status {
    case .job(_, let progress, false): progress ?? .preparing
    case .wine(let progress): progress ?? .preparing
    default: nil
    }
  }

  private var headline: LocalizedStringResource {
    switch status {
    case .none: ""
    case .job(let job, _, let paused): job.title(paused: paused)
    case .wine: "Preparing Wine"
    case .wineRequired: "Wine has to be set up first"
    case .updateAvailable(let version):
      version.map { "Version \($0) available" } ?? "Update available"
    case .preDownloadAvailable(let version):
      version.map { "Version \($0) can be pre-downloaded" } ?? "Pre-download available"
    case .error(let error): error.message
    case .offline: "Offline"
    case .hostsRequired: "Telemetry block required"
    case .launching: "Starting Wine…"
    case .running: "The game is running"
    }
  }

  private var detail: LocalizedStringResource? {
    guard let progress = movingProgress else { return nil }
    guard let counts = progress.counts else {
      if case .wine(let step) = progress { return step.label }
      return nil
    }
    let amount = "\(ByteFormat.iec(counts.done)) / \(ByteFormat.iec(counts.total))"
    guard let speed = meter.bytesPerSecond, speed > 0 else { return "\(amount)" }
    let rate = ByteFormat.iec(Int64(speed))
    if let remaining = meter.remaining {
      return "\(amount) · \(rate)/s · \(Format.duration(remaining)) left"
    }
    return "\(amount) · \(rate)/s"
  }

  @ViewBuilder private var accessory: some View {
    if canPreDownload {
      Button("Pre-download") { Task { await controller.preDownload() } }
        .buttonStyle(.glass)
        .controlSize(.large)
    }
    if case .error(let error) = status, let log = error.logURL {
      Button("Show Log") { NSWorkspace.shared.activateFileViewerSelecting([log]) }
        .buttonStyle(.glass)
        .controlSize(.large)
    }
  }
}
