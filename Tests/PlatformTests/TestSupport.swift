import Foundation

@testable import Platform

/// A fresh directory under the system temp dir, removed by `cleanup()`.
struct TempDir {
  let url: URL

  init() throws {
    url = FileManager.default.temporaryDirectory
      .appending(path: "yaagl-platform-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
  }

  func cleanup() { try? FileManager.default.removeItem(at: url) }

  func path(_ components: String...) -> URL {
    components.reduce(url) { $0.appending(path: $1) }
  }

  func makeFile(_ relative: String, contents: String = "x") throws {
    let file = url.appending(path: relative)
    try FileManager.default.createDirectory(
      at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
    try contents.write(to: file, atomically: true, encoding: .utf8)
  }

  func exists(_ relative: String) -> Bool {
    FileManager.default.fileExists(atPath: url.appending(path: relative).path)
  }
}

/// Stands in for `NSAppleScript`: runs the command with /bin/sh as the current user, so tests
/// against a temporary hosts file exercise the real quoting without a password prompt.
final class ShellAdmin: AdminPrivilege, @unchecked Sendable {
  private(set) var commands: [String] = []
  var failure: (any Error)?

  func run(shellCommand: String) async throws {
    commands.append(shellCommand)
    if let failure { throw failure }
    let process = Process()
    process.executableURL = URL(filePath: "/bin/sh")
    process.arguments = ["-c", shellCommand]
    try process.run()
    process.waitUntilExit()
    if process.terminationStatus != 0 {
      throw AdminPrivilegeError.failed("exit \(process.terminationStatus)")
    }
  }
}
