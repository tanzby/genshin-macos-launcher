import Foundation
import Observation
import Platform

/// `HostsBlocklist` behind a seam, so onboarding is testable without `/etc/hosts` or a password dialog.
public protocol HostsBlocking: Sendable {
  func status() throws -> HostsBlocklist.Status
  func apply() async throws
}

extension HostsBlocklist: HostsBlocking {}

/// First-run guidance: the hosts blocklist is a required step (the game never starts without it), then the
/// game directory. The blocklist stays watched afterwards because `/etc/hosts` can change under us.
@MainActor @Observable
public final class OnboardingModel {
  public enum Step: Sendable, Equatable { case hosts, gameDirectory, done }

  package private(set) var hostsStatus: HostsBlocklist.Status?
  public private(set) var hostsError: String?
  public private(set) var isApplyingHosts = false
  /// The saved game folder still exists. A folder on an unmounted or renamed volume sends the user back to
  /// the picker instead of failing every install and launch against a dead path.
  package private(set) var gameDirectoryUsable = true

  private let hosts: any HostsBlocking
  private let settings: SettingsModel

  public init(hosts: any HostsBlocking, settings: SettingsModel) {
    self.hosts = hosts
    self.settings = settings
  }

  public var allowsLaunch: Bool { hostsStatus?.allowsLaunch ?? false }

  /// A game folder is chosen and still exists.
  public var hasUsableGameDirectory: Bool { settings.gameDirectory != nil && gameDirectoryUsable }

  public var step: Step {
    if !allowsLaunch { return .hosts }
    return hasUsableGameDirectory ? .done : .gameDirectory
  }

  package var isComplete: Bool { step == .done }

  /// Whether the first-run sheet is up. An unattended run (the diag's `--autolaunch`, APP-020) has its game folder
  /// from the command line and no one to choose one: only the hosts step, the one a person can still do, is offered;
  /// the picker would write the real preferences while the game already runs.
  public func showsSheet(unattended: Bool) -> Bool {
    unattended ? step == .hosts : !isComplete
  }

  /// Re-reads `/etc/hosts` (no privileges needed). An unreadable file counts as "not in place".
  public func refresh() {
    hostsError = readStatus()
    checkGameDirectory()
  }

  private func checkGameDirectory() {
    // No folder chosen yet is not a problem to report here.
    gameDirectoryUsable = settings.gameDirectory.map(GameDirectoryValidator.isUsable) ?? true
  }

  /// Returns the read error's description, nil on success.
  private func readStatus() -> String? {
    do {
      hostsStatus = try hosts.status()
      return nil
    } catch {
      hostsStatus = nil
      return String(describing: error)
    }
  }

  /// Asks for the administrator password (inside `apply()`). A cancelled dialog leaves the step unchanged.
  public func applyHosts() async {
    guard !isApplyingHosts else { return }
    isApplyingHosts = true
    hostsError = nil
    var applyError: String?
    do {
      try await hosts.apply()
    } catch {
      applyError = String(describing: error)
    }
    isApplyingHosts = false
    let readError = readStatus()
    hostsError = applyError ?? readError
  }

  public func useGameDirectory(_ url: URL) {
    settings.gameDirectory = url
    checkGameDirectory()
  }
}
