import Foundation

package enum RegistryValue: Sendable, Equatable, Codable {
  case dword(UInt32)
  case string(String)
}

/// One registry change, applied with `wine reg` (argv, never a batch file: `cmd` reads batch files in the
/// OEM code page and would mangle non-ASCII keys such as `原神`).
package struct RegistryEdit: Sendable, Equatable {
  package enum Action: Sendable, Equatable {
    case set(RegistryValue)
    case delete
  }

  /// Key in `reg` syntax, e.g. `HKCU\Software\miHoYo\原神`.
  package var key: String
  package var name: String
  package var action: Action
  /// `true`: the original value (or its absence) is recorded in the journal and put back after the game.
  /// `false`: a persistent preference such as the Mac Driver keys.
  package var restoresOnExit: Bool

  package init(key: String, name: String, action: Action, restoresOnExit: Bool) {
    self.key = key
    self.name = name
    self.action = action
    self.restoresOnExit = restoresOnExit
  }
}

/// A file copied into `drive_c/windows/<destination>` of the prefix on every launch when it differs.
/// Never restored (LCH-018).
package struct PrefixCopy: Sendable, Equatable {
  package var source: URL
  /// Relative to `drive_c/windows`, e.g. `system32/steam.exe`.
  package var destination: String

  package init(source: URL, destination: String) {
    self.source = source
    self.destination = destination
  }
}

/// Everything a game needs from Wine for one launch, as plain values. The game module builds it;
/// `GameSession` only executes it, so this module stays game-agnostic.
package struct LaunchRecipe: Sendable, Equatable {
  /// Game environment on top of `WINEPREFIX`/`WINEDEBUG`. Empty values are dropped (LCH-035).
  package var environment: [String: String]
  package var registry: [RegistryEdit]
  /// Files renamed to `<name>.bak` before the game and renamed back afterwards (LCH-014).
  package var moveAside: [URL]
  package var prefixCopies: [PrefixCopy]
  /// The Wine arguments that start the game: `wine <command>` (LCH-010). Deliberately not a `cmd /c` batch file:
  /// with `cmd.exe` as the parent the game loads its anti-cheat driver, which fails on this Wine (#57).
  package var command: [String]
  /// File name of the game process, e.g. `YuanShen.exe`. Used for Game Mode and to see the game start.
  package var gameExecutableName: String
  package var gameDisplayName: String

  package init(
    environment: [String: String] = [:],
    registry: [RegistryEdit] = [],
    moveAside: [URL] = [],
    prefixCopies: [PrefixCopy] = [],
    command: [String] = [],
    gameExecutableName: String = "",
    gameDisplayName: String = ""
  ) {
    self.environment = environment
    self.registry = registry
    self.moveAside = moveAside
    self.prefixCopies = prefixCopies
    self.command = command
    self.gameExecutableName = gameExecutableName
    self.gameDisplayName = gameDisplayName
  }
}

package enum LaunchResult: Sendable, Equatable {
  /// The loader exited with 0.
  case exited
  case failedExit(code: Int32, log: URL)
  /// No game process appeared within the startup timeout (LCH-036 补充, #28 B15).
  case startupTimedOut
  /// Preparation failed before the game started.
  case failedToLaunch(reason: String)
  /// The calling task was cancelled (the launcher is quitting).
  case cancelled
}

package struct LaunchTiming: Sendable {
  package var startupTimeout: Duration
  package var pollInterval: Duration
  /// How long `wineserver -w` may take after the game exits before the prefix is killed (LCH-036).
  package var exitGrace: Duration
  package var sleep: @Sendable (Duration) async throws -> Void

  package init(
    startupTimeout: Duration = .seconds(120),
    pollInterval: Duration = .seconds(1),
    exitGrace: Duration = .seconds(15),
    sleep: @escaping @Sendable (Duration) async throws -> Void = LaunchTiming.defaultSleep
  ) {
    self.startupTimeout = startupTimeout
    self.pollInterval = pollInterval
    self.exitGrace = exitGrace
    self.sleep = sleep
  }

  /// Named, not a closure literal in the default argument: see `scripts/dev/check-async-closure-default` (issue #48).
  package static func defaultSleep(_ duration: Duration) async throws {
    try await Task.sleep(for: duration)
  }
}

/// The Game Mode helpers inside the app bundle (`Contents/Helpers/`), plus the launcher's icon for the game
/// bundle. Passed in so `Wine` never touches `Bundle.main`.
package struct GameHostHelpers: Sendable, Equatable {
  package var shim: URL
  package var dylib: URL
  /// `AppIcon.icns`, shown by the Game Mode notification. Missing or `nil` leaves the game bundle without an icon.
  package var icon: URL?

  package init(shim: URL, dylib: URL, icon: URL?) {
    self.shim = shim
    self.dylib = dylib
    self.icon = icon
  }
}

/// Registers an app bundle with LaunchServices. A seam so tests never touch the real database.
package protocol LaunchServicesRegistering: Sendable {
  func register(appAt url: URL) throws
}
