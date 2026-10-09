import Foundation

public enum ProcessRunnerError: Error, Equatable {
  case executableNotAllowed(String)
}

/// Production `ProcessRunning`. Only the system tools `codesign`, `tar`, `ditto` and executables
/// inside `allowedRoots` (the Wine runtime) may run (ADR 0002).
public struct SystemProcessRunner: ProcessRunning {
  public static let systemTools: Set<String> = ["/usr/bin/codesign", "/usr/bin/tar", "/usr/bin/ditto"]

  private let allowedRoots: [URL]
  /// How long a cancelled process gets after SIGTERM before it is killed.
  let terminationGrace: TimeInterval

  public init(allowedRoots: [URL] = []) {
    self.init(allowedRoots: allowedRoots, terminationGrace: 5)
  }

  init(allowedRoots: [URL], terminationGrace: TimeInterval) {
    self.allowedRoots = allowedRoots
    self.terminationGrace = terminationGrace
  }

  func isAllowed(_ executable: URL) -> Bool {
    let path = executable.standardizedFileURL.path
    if Self.systemTools.contains(path) { return true }
    // Resolve symlinks so `<root>/bin/wine -> /elsewhere` and `..` cannot escape the root.
    let resolved = executable.standardizedFileURL.resolvingSymlinksInPath().path
    // Roots are resolved per call: the Wine directory may not exist yet when the runner is created.
    return allowedRoots.contains { resolved.hasPrefix($0.standardizedFileURL.resolvingSymlinksInPath().path + "/") }
  }

  public func run(
    _ executable: URL,
    arguments: [String],
    environment: [String: String],
    workingDirectory: URL?
  ) async throws -> ProcessResult {
    guard isAllowed(executable) else {
      throw ProcessRunnerError.executableNotAllowed(executable.path)
    }
    let process = Process()
    process.executableURL = executable
    process.arguments = arguments
    process.environment = ProcessInfo.processInfo.environment.merging(environment) { _, new in new }
    process.currentDirectoryURL = workingDirectory
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = pipe
    process.standardInput = FileHandle.nullDevice

    return try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuation in
        // Drain the pipe on its own thread so a chatty child never blocks on a full buffer.
        let collected = LockedData()
        pipe.fileHandleForReading.readabilityHandler = { handle in
          let data = handle.availableData
          if data.isEmpty { handle.readabilityHandler = nil } else { collected.append(data) }
        }
        process.terminationHandler = { finished in
          pipe.fileHandleForReading.readabilityHandler = nil
          collected.append((try? pipe.fileHandleForReading.readToEnd()) ?? Data())
          continuation.resume(
            returning: ProcessResult(
              exitCode: finished.terminationStatus,
              output: String(decoding: collected.value, as: UTF8.self)))
        }
        do {
          try process.run()
          // Cancelled before the process existed: onCancel found nothing to stop, so do it (with the KILL fallback).
          if Task.isCancelled { Self.terminate(process, after: terminationGrace) }
        } catch {
          pipe.fileHandleForReading.readabilityHandler = nil
          continuation.resume(throwing: error)
        }
      }
    } onCancel: {
      Self.terminate(process, after: terminationGrace)
    }
  }

  public func runLogging(
    _ executable: URL,
    arguments: [String],
    environment: [String: String],
    workingDirectory: URL?,
    logFile: URL
  ) async throws -> Int32 {
    guard isAllowed(executable) else {
      throw ProcessRunnerError.executableNotAllowed(executable.path)
    }
    try Data().write(to: logFile)
    let handle = try FileHandle(forWritingTo: logFile)
    defer { try? handle.close() }
    let process = Process()
    process.executableURL = executable
    process.arguments = arguments
    process.environment = ProcessInfo.processInfo.environment.merging(environment) { _, new in new }
    process.currentDirectoryURL = workingDirectory
    process.standardOutput = handle
    process.standardError = handle
    process.standardInput = FileHandle.nullDevice

    return try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuation in
        process.terminationHandler = { continuation.resume(returning: $0.terminationStatus) }
        do {
          try process.run()
          // Cancelled before the process existed: onCancel found nothing to stop, so do it (with the KILL fallback).
          if Task.isCancelled { Self.terminate(process, after: terminationGrace) }
        } catch {
          continuation.resume(throwing: error)
        }
      }
    } onCancel: {
      Self.terminate(process, after: terminationGrace)
    }
  }

  /// SIGTERM, then SIGKILL if the process is still there after a grace period (Wine loaders can ignore TERM).
  static func terminate(_ process: Process, after grace: TimeInterval = 5) {
    guard process.isRunning else { return }
    process.terminate()
    DispatchQueue.global().asyncAfter(deadline: .now() + grace) {
      if process.isRunning { kill(process.processIdentifier, SIGKILL) }
    }
  }
}

private final class LockedData: @unchecked Sendable {
  private let lock = NSLock()
  private var data = Data()

  func append(_ more: Data) {
    lock.lock()
    data.append(more)
    lock.unlock()
  }

  var value: Data {
    lock.lock()
    defer { lock.unlock() }
    return data
  }
}
