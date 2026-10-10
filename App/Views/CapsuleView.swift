import AppKit
import Launcher
import SwiftUI

/// The single Liquid Glass capsule at the bottom: status area, primary button, "…" menu (#21).
struct CapsuleView: View {
  @Environment(MainController.self) private var controller
  @Environment(ProgressMeter.self) private var meter
  @Environment(\.openSettings) private var openSettings
  let chooseGameDirectory: () -> Bool

  var body: some View {
    let presentation = controller.presentation
    GlassEffectContainer {
      HStack(spacing: 12) {
        if presentation.status != .none {
          StatusArea(status: presentation.status, meter: meter, controller: controller)
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
  let status: StatusLine
  let meter: ProgressMeter
  let controller: MainController

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
        if let bar = progressBar {
          ProgressView(value: bar.fraction)
            .progressViewStyle(.linear)
        }
      }
      .frame(minWidth: 180, maxWidth: 360, alignment: .leading)
      accessory
    }
  }

  private var headline: LocalizedStringResource {
    switch status {
    case .none: ""
    case .job(let job, _, let paused): job.title(paused: paused)
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
    guard case .job(_, let progress, let paused) = status, !paused, let counts = progress?.counts else {
      return nil
    }
    let amount = "\(Format.bytes(counts.done)) / \(Format.bytes(counts.total))"
    guard let speed = meter.bytesPerSecond, speed > 0 else { return "\(amount)" }
    if let remaining = meter.remaining {
      return "\(amount) · \(Format.bytes(Int64(speed)))/s · \(Format.duration(remaining)) left"
    }
    return "\(amount) · \(Format.bytes(Int64(speed)))/s"
  }

  /// A bar only while a job is moving; `nil` fraction renders the indeterminate bar (PRG-005).
  private var progressBar: (fraction: Double?, show: Bool)? {
    guard case .job(_, let progress, let paused) = status, !paused else { return nil }
    return (progress?.fraction, true)
  }

  @ViewBuilder private var accessory: some View {
    switch status {
    case .preDownloadAvailable:
      Button("Pre-download") { Task { await controller.preDownload() } }
        .buttonStyle(.glass)
        .controlSize(.large)
    case .error(let error):
      if let log = error.logURL {
        Button("Show Log") { NSWorkspace.shared.activateFileViewerSelecting([log]) }
          .buttonStyle(.glass)
          .controlSize(.large)
      }
    default:
      EmptyView()
    }
  }
}
