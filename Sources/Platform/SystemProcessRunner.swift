import Foundation

public enum ProcessRunnerError: Error, Equatable {
  case executableNotAllowed(String)
}

/// Production `ProcessRunning`. Only the system tools `codesign`, `tar`, `ditto` and executables
/// inside `allowedRoots` (the Wine runtime) may run (ADR 0002).
public struct SystemProcessRunner: ProcessRunning {
  public static let systemTools: Set<String> = ["/usr/bin/codesign", "/usr/bin/tar", "/usr/bin/ditto"]

  public init(allowedRoots: [URL] = []) {}

  public func run(
    _ executable: URL,
    arguments: [String],
    environment: [String: String],
    workingDirectory: URL?
  ) async throws -> ProcessResult {
    throw CocoaError(.featureUnsupported)
  }
}
