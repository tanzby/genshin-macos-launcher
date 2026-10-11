import Foundation
import Wine

/// The seam between the launcher and the Wine runtime. `WineRuntime` is the production implementation;
/// tests use a Fake so the state machine never touches the disk or the network.
public protocol WinePreparing: Sendable {
  /// Whether the pinned Wine and DXMT are installed and intact. Looks at the disk (the version stamp).
  func status() async -> WineStatus
  /// Installs Wine, DXMT and the prefix when `status()` is not `.ready`. Must stop when its Task is
  /// cancelled; downloads resume from their `.part` files on the next call.
  func ensureInstalled(progress: @escaping @Sendable (WineInstallProgress) -> Void) async throws
  /// Installs unconditionally, replacing a Wine that `status()` still calls ready (used when launching found it broken).
  func reinstall(progress: @escaping @Sendable (WineInstallProgress) -> Void) async throws
}

/// The environment steps of ADR 0002's startup order that sit around Wine, behind a seam so the state machine
/// is testable. (Wiping old data and the hosts check happen before the model exists / in `OnboardingModel`.)
public struct StartupSteps: Sendable {
  /// Whether Rosetta 2 is installed. Checked before the 2 GB Wine download.
  public var rosettaInstalled: @Sendable () async -> Bool
  /// `GameSession.recover()`: kill what is left of the prefix, replay the journal of a crashed launch.
  public var recoverSession: @Sendable () async -> Void

  public init(
    rosettaInstalled: @escaping @Sendable () async -> Bool,
    recoverSession: @escaping @Sendable () async -> Void
  ) {
    self.rosettaInstalled = rosettaInstalled
    self.recoverSession = recoverSession
  }

  /// Rosetta's runtime library, present once `softwareupdate --install-rosetta` has run. (`share/rosetta/rosetta`
  /// is a 64-byte placeholder on macOS 27, so it says nothing.)
  public static let rosettaRuntime = URL(filePath: "/Library/Apple/usr/libexec/oah/libRosettaRuntime")

  public static func isRosettaInstalled(at runtime: URL = rosettaRuntime) -> Bool {
    FileManager.default.fileExists(atPath: runtime.path)
  }
}

extension WineRuntime: WinePreparing {}
