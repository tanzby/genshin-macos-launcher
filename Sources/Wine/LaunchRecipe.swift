import Foundation

public enum RegistryValue: Sendable, Equatable, Codable {
  case dword(UInt32)
  case string(String)
}

/// One registry change, applied with `wine reg` (argv, never a batch file: `cmd` reads batch files in the
/// OEM code page and would mangle non-ASCII keys such as `原神`).
public struct RegistryEdit: Sendable, Equatable {
  public enum Action: Sendable, Equatable {
    case set(RegistryValue)
    case delete
  }

  /// Key in `reg` syntax, e.g. `HKCU\Software\miHoYo\原神`.
  public var key: String
  public var name: String
  public var action: Action
  /// `true`: the original value (or its absence) is recorded in the journal and put back after the game.
  /// `false`: a persistent preference such as the Mac Driver keys.
  public var restoresOnExit: Bool

  public init(key: String, name: String, action: Action, restoresOnExit: Bool) {
    self.key = key
    self.name = name
    self.action = action
    self.restoresOnExit = restoresOnExit
  }
}

/// A file copied into `drive_c/windows/<destination>` of the prefix on every launch when it differs.
/// Never restored (LCH-018).
public struct PrefixCopy: Sendable, Equatable {
  public var source: URL
  /// Relative to `drive_c/windows`, e.g. `system32/steam.exe`.
  public var destination: String

  public init(source: URL, destination: String) {
    self.source = source
    self.destination = destination
  }
}

/// Everything a game needs from Wine for one launch, as plain values. The game module builds it;
/// `GameSession` only executes it, so this module stays game-agnostic.
public struct LaunchRecipe: Sendable, Equatable {
  /// Game environment on top of `WINEPREFIX`/`WINEDEBUG`. Empty values are dropped (LCH-035).
  public var environment: [String: String]
  public var registry: [RegistryEdit]
  /// Files renamed to `<name>.bak` before the game and renamed back afterwards (LCH-014).
  public var moveAside: [URL]
  public var prefixCopies: [PrefixCopy]
  /// Contents of `config.bat`, run as `wine cmd /c config.bat` (LCH-010).
  public var batchScript: String
  /// File name of the game process, e.g. `YuanShen.exe`. Used for Game Mode and to see the game start.
  public var gameExecutableName: String
  public var gameDisplayName: String

  public init(
    environment: [String: String] = [:],
    registry: [RegistryEdit] = [],
    moveAside: [URL] = [],
    prefixCopies: [PrefixCopy] = [],
    batchScript: String = "",
    gameExecutableName: String = "",
    gameDisplayName: String = ""
  ) {
    self.environment = environment
    self.registry = registry
    self.moveAside = moveAside
    self.prefixCopies = prefixCopies
    self.batchScript = batchScript
    self.gameExecutableName = gameExecutableName
    self.gameDisplayName = gameDisplayName
  }
}

public enum LaunchResult: Sendable, Equatable {
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

public struct LaunchTiming: Sendable {
  public var startupTimeout: Duration
  public var pollInterval: Duration
  /// How long `wineserver -w` may take after the game exits before the prefix is killed (LCH-036).
  public var exitGrace: Duration
  public var sleep: @Sendable (Duration) async throws -> Void

  public init(
    startupTimeout: Duration = .seconds(120),
    pollInterval: Duration = .seconds(1),
    exitGrace: Duration = .seconds(15),
    sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
  ) {
    self.startupTimeout = startupTimeout
    self.pollInterval = pollInterval
    self.exitGrace = exitGrace
    self.sleep = sleep
  }
}

/// The Game Mode helpers inside the app bundle (`Contents/Helpers/`). Passed in so `Wine` never touches
/// `Bundle.main`.
public struct GameHostHelpers: Sendable, Equatable {
  public var shim: URL
  public var dylib: URL

  public init(shim: URL, dylib: URL) {
    self.shim = shim
    self.dylib = dylib
  }
}

/// Registers an app bundle with LaunchServices. A seam so tests never touch the real database.
public protocol LaunchServicesRegistering: Sendable {
  func register(appAt url: URL) throws
}
