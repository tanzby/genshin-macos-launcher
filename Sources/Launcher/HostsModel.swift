import Foundation
import Observation
import Platform

/// `HostsBlocklist` behind a seam, so onboarding and the launcher are testable without `/etc/hosts` or a password dialog.
public protocol HostsBlocking: Sendable {
  func status() throws -> HostsBlocklist.Status
  func apply() async throws
}

extension HostsBlocklist: HostsBlocking {}

/// The one owner of what `/etc/hosts` looks like. Onboarding guides the user through it and the launcher refuses to
/// start the game without it; both read this one instance.
@MainActor @Observable
public final class HostsModel {
  /// What the blocklist looked like at the last read; nil = unread or unreadable.
  package private(set) var status: HostsBlocklist.Status?
  /// Why the last read or apply failed, nil on success.
  public private(set) var error: String?
  public private(set) var isApplying = false

  @ObservationIgnored private let blocklist: any HostsBlocking

  public init(_ blocklist: any HostsBlocking) {
    self.blocklist = blocklist
  }

  /// An unread or unreadable file counts as "not in place".
  public var allowsLaunch: Bool { status?.allowsLaunch ?? false }

  /// Re-reads `/etc/hosts` (no privileges needed).
  public func refresh() {
    error = read()
  }

  /// Asks for the administrator password (inside `apply()`), then reads the file again. A cancelled dialog changes nothing.
  public func apply() async {
    guard !isApplying else { return }
    isApplying = true
    error = nil
    var applyError: String?
    do {
      try await blocklist.apply()
    } catch {
      applyError = String(describing: error)
    }
    isApplying = false
    let readError = read()
    error = applyError ?? readError
  }

  /// Returns the read error's description, nil on success.
  private func read() -> String? {
    do {
      status = try blocklist.status()
      return nil
    } catch {
      status = nil
      return String(describing: error)
    }
  }
}
