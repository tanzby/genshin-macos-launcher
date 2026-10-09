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

  /// Like `run`, but stdout and stderr stream into `logFile` instead of memory. For the game, which can run
  /// for hours with timestamped Wine debug output. Returns the exit code.
  func runLogging(
    _ executable: URL,
    arguments: [String],
    environment: [String: String],
    workingDirectory: URL?,
    logFile: URL
  ) async throws -> Int32
}

extension ProcessRunning {
  /// For test doubles: buffers through `run` and writes the log at the end.
  public func runLogging(
    _ executable: URL,
    arguments: [String],
    environment: [String: String],
    workingDirectory: URL?,
    logFile: URL
  ) async throws -> Int32 {
    let result = try await run(
      executable, arguments: arguments, environment: environment, workingDirectory: workingDirectory)
    try result.output.write(to: logFile, atomically: true, encoding: .utf8)
    return result.exitCode
  }
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
