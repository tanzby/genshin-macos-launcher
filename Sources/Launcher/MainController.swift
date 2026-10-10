import Foundation
import Observation

/// Glue between the main window and the models: routes button taps, remembers refused starts, and keeps
/// the launcher's game directory in step with the settings. Everything with a decision in it lives here or in
/// `MainPresentation`, so the SwiftUI views stay plain.
@MainActor @Observable
public final class MainController {
  public let launcher: LauncherModel
  public let settings: SettingsModel
  public let onboarding: OnboardingModel

  /// A start the launcher refused (no space, busy, offline…). Job failures live in `launcher.lastError`.
  public private(set) var actionError: LauncherError?

  public init(launcher: LauncherModel, settings: SettingsModel, onboarding: OnboardingModel) {
    self.launcher = launcher
    self.settings = settings
    self.onboarding = onboarding
  }

  public var presentation: MainPresentation {
    var snapshot = MainSnapshot(
      phase: launcher.phase, isPreDownloading: launcher.isPreDownloading, isPausing: launcher.isPausing,
      progress: launcher.progress, pendingJob: launcher.pendingJob, lastError: launcher.lastError,
      status: launcher.status, isOnline: launcher.isOnline, hostsAllowLaunch: onboarding.allowsLaunch)
    if let actionError { snapshot.lastError = actionError }
    return .derive(snapshot)
  }

  /// Re-reads everything the window shows. Safe to call whenever the window becomes active.
  public func refresh() async {
    onboarding.refresh()
    if launcher.gameDirectory != settings.gameDirectory { launcher.gameDirectory = settings.gameDirectory }
    await launcher.refresh()
  }

  /// Installing needs a directory first; the view shows the picker when this is true.
  public func needsGameDirectory(for button: PrimaryButton) -> Bool {
    button == .install && (settings.gameDirectory == nil || !onboarding.gameDirectoryUsable)
  }

  public func dismissActionError() { actionError = nil }

  public func perform(_ button: PrimaryButton) async {
    actionError = nil
    await run {
      switch button {
      case .install: try await self.launcher.start(.install)
      case .update: try await self.launcher.start(.update)
      case .launch:
        guard self.onboarding.allowsLaunch else { return }
        try await self.launcher.launch()
      case .pause: await self.launcher.pause()
      case .resume, .retry: try await self.launcher.resume()
      case .pausing, .repairing, .launching, .running: break
      }
    }
  }

  public func preDownload() async {
    actionError = nil
    await run { try await self.launcher.start(.preDownload) }
  }

  public func repair() async {
    actionError = nil
    await run { try await self.launcher.start(.repair) }
  }

  private func run(_ work: () async throws -> Void) async {
    do {
      try await work()
    } catch let error as LauncherError {
      actionError = error
    } catch {
      actionError = .unexpected(String(describing: error))
    }
  }
}
