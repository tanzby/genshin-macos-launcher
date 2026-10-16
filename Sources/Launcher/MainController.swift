import Foundation
import Observation

/// Glue between the main window and the models: routes button taps. Everything with a decision in it lives here or in
/// `MainPresentation`, so the SwiftUI views stay plain.
@MainActor @Observable
public final class MainController {
  public let launcher: LauncherModel
  public let settings: SettingsModel
  public let onboarding: OnboardingModel

  /// Set once the first status query has returned, so "offline" is only claimed after a real attempt.
  package private(set) var hasLoaded = false

  public init(launcher: LauncherModel, settings: SettingsModel, onboarding: OnboardingModel) {
    self.launcher = launcher
    self.settings = settings
    self.onboarding = onboarding
  }

  public var presentation: MainPresentation {
    .derive(
      MainSnapshot(
        phase: launcher.phase, isPreDownloading: launcher.isPreDownloading, isPausing: launcher.isPausing,
        progress: launcher.progress, pendingJob: launcher.pendingJob, lastError: launcher.lastError,
        status: launcher.status, isOnline: launcher.isOnline,
        launchRefusal: launcher.refusal(for: .launch), installRefusal: launcher.refusal(for: .start(.install)),
        updateRefusal: launcher.refusal(for: .start(.update)), resumeRefusal: launcher.refusal(for: .resume),
        repairRefusal: launcher.refusal(for: .start(.repair)),
        preDownloadRefusal: launcher.refusal(for: .start(.preDownload)), hasLoaded: hasLoaded,
        wineNotReady: launcher.isWineNotReady))
  }

  /// Re-reads everything the window shows. The first call runs the launcher's startup sequence (Wine, then the
  /// game status); later ones only re-read, so coming back to the window never restarts a Wine download.
  public func refresh() async {
    onboarding.refresh()
    await reload()
  }

  /// For window activation: re-reads everything unless a job or the game is active, so coming back after the
  /// network returned clears a stale "offline" without disturbing a running job.
  public func refreshWhenIdle() async {
    onboarding.refresh()
    guard launcher.phase == .idle else { return }
    await reload()
  }

  private func reload() async {
    // Until the startup sequence has got past the Rosetta check, every reload runs it again.
    if launcher.hasBootstrapped {
      await launcher.refreshWine()
      await launcher.refresh()
    } else {
      await launcher.bootstrap()
    }
    hasLoaded = true
  }

  /// Installing needs a directory first; the view shows the picker when this is true.
  public func needsGameDirectory(for button: PrimaryButton) -> Bool {
    button == .install && !onboarding.hasUsableGameDirectory
  }

  public func perform(_ button: PrimaryButton) async {
    await run {
      switch button {
      case .prepareWine: try await self.launcher.prepareWine()
      case .install: try await self.launcher.start(.install)
      case .update: try await self.launcher.start(.update)
      case .launch: try await self.launcher.launch()
      case .pause: await self.launcher.pause()
      case .resume, .retry: try await self.launcher.resume()
      case .pausing, .launching, .running: break
      }
    }
  }

  public var canOpenWineCommandPrompt: Bool { launcher.canOpenWineCommandPrompt }

  /// Returns once the prompt window is closed, so callers run it in a `Task`.
  public func openWineCommandPrompt() async {
    await launcher.openWineCommandPrompt()
  }

  public func preDownload() async {
    await run { try await self.launcher.start(.preDownload) }
  }

  public func repair() async {
    await run { try await self.launcher.start(.repair) }
  }

  /// Hands job events and newly announced versions to `notifier` until the calling Task is cancelled.
  public func deliverNotifications(to notifier: EventNotifier) async {
    async let events: Void = forwardEvents(to: notifier)
    await forwardStatus(to: notifier)
    await events
  }

  private func forwardEvents(to notifier: EventNotifier) async {
    for await event in launcher.events { await notifier.handle(event) }
  }

  private func forwardStatus(to notifier: EventNotifier) async {
    for await status in Observations({ self.launcher.status }) { await notifier.observe(status: status) }
  }

  /// Asks for the administrator password, then has the launcher look at `/etc/hosts` again.
  public func applyHosts() async {
    await onboarding.applyHosts()
    launcher.refreshHosts()
  }

  /// A refusal is already in `launcher.lastError`; the window reads it from there.
  private func run(_ work: () async throws -> Void) async {
    try? await work()
  }
}
