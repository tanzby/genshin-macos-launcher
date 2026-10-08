import Foundation
import Platform

/// Everything a game needs from Wine for one launch, as plain values. The game module builds it;
/// `GameSession` only executes it, so this module stays game-agnostic.
public struct LaunchRecipe: Sendable, Equatable {
  public var environment: [String: String]
  public var registryFile: String
  public var batchFile: String

  public init(environment: [String: String] = [:], registryFile: String = "", batchFile: String = "") {
    self.environment = environment
    self.registryFile = registryFile
    self.batchFile = batchFile
  }
}

/// Owns the pinned Wine runtime and prefix.
public actor WineRuntime {
  /// The one Wine version the app installs (ADR 0001).
  public static let pinnedVersion = "11.0-1-crossover-signed-experimental"

  private let dataDirectory: DataDirectory

  public init(dataDirectory: DataDirectory) {
    self.dataDirectory = dataDirectory
  }

  public nonisolated var runtimeDirectory: URL {
    dataDirectory.root.appending(path: "wine", directoryHint: .isDirectory)
  }
}

/// Executes a `LaunchRecipe`: launch mutations, run, wait, restore.
public struct GameSession: Sendable {
  public init() {}
}
