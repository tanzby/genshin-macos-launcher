import Foundation

/// The only entry to external processes: Wine and the allowlisted system tools
/// (`codesign`, `tar`, `ditto`). Tests substitute a recording implementation.
public protocol ProcessRunning: Sendable {
  func run(
    _ executable: URL,
    arguments: [String],
    environment: [String: String],
    workingDirectory: URL?
  ) async throws -> ProcessResult
}

public struct ProcessResult: Sendable, Equatable {
  public var exitCode: Int32
  public var output: String

  public init(exitCode: Int32, output: String) {
    self.exitCode = exitCode
    self.output = output
  }
}

/// Runs a shell command with administrator privileges. Its only caller is `HostsBlocklist`.
public protocol AdminPrivilege: Sendable {
  func run(shellCommand: String) async throws
}

/// `~/Library/Application Support/Yaagl`. First-launch cleanup (ADR 0001) lands in `prepare()`.
public struct DataDirectory: Sendable, Equatable {
  public static let name = "Yaagl"
  public static let nativeMarkerName = ".yaagl-native"

  public let root: URL

  public init(root: URL) {
    self.root = root
  }

  public static var defaultRoot: URL {
    URL.applicationSupportDirectory.appending(path: name, directoryHint: .isDirectory)
  }

  public var nativeMarker: URL {
    root.appending(path: Self.nativeMarkerName, directoryHint: .notDirectory)
  }
}
