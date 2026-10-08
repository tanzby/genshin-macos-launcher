import Foundation
import Testing

@testable import Platform

private func runnerTempDirectory() throws -> URL {
  let dir = FileManager.default.temporaryDirectory
    .appending(path: "yaagl-runner-test-\(UUID().uuidString)", directoryHint: .isDirectory)
    .resolvingSymlinksInPath()
  try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
  return dir
}

private func writeScript(_ body: String, named name: String = "tool.sh", in dir: URL) throws -> URL {
  let url = dir.appending(path: name)
  try Data("#!/bin/sh\n\(body)\n".utf8).write(to: url)
  try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
  return url
}

@Suite("WIN-008/012 SystemProcessRunner") struct SystemProcessRunnerTests {
  @Test("WIN-008 runs /usr/bin/tar without any allowed root")
  func runsTar() async throws {
    let result = try await SystemProcessRunner().run(
      URL(filePath: "/usr/bin/tar"), arguments: ["--version"], environment: [:], workingDirectory: nil)
    #expect(result.exitCode == 0)
    #expect(result.output.contains("bsdtar"))
  }

  @Test("WIN-008 runs /usr/bin/ditto")
  func runsDitto() async throws {
    let dir = try runnerTempDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let source = dir.appending(path: "a.txt")
    try Data("hello".utf8).write(to: source)
    let target = dir.appending(path: "b.txt")
    let result = try await SystemProcessRunner().run(
      URL(filePath: "/usr/bin/ditto"), arguments: [source.path, target.path], environment: [:],
      workingDirectory: nil)
    #expect(result.exitCode == 0)
    #expect(try Data(contentsOf: target) == Data("hello".utf8))
  }

  @Test("WIN-008 allows /usr/bin/codesign (a failing invocation is returned, not rejected)")
  func runsCodesign() async throws {
    let result = try await SystemProcessRunner().run(
      URL(filePath: "/usr/bin/codesign"), arguments: ["-dv", "/nonexistent/yaagl-test"], environment: [:],
      workingDirectory: nil)
    #expect(result.exitCode != 0)
  }

  @Test("WIN-008 an allowed root that does not exist yet still admits its executables once created")
  func rootCreatedAfterRunner() async throws {
    let base = try runnerTempDirectory()
    defer { try? FileManager.default.removeItem(at: base) }
    // Spelled with the /private prefix, as a data directory under /tmp or /var is when only the runtime
    // folder is missing at construction time.
    let root = URL(filePath: "/private" + base.path, directoryHint: .isDirectory).appending(path: "wine")
    let runner = SystemProcessRunner(allowedRoots: [root])
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let script = try writeScript("echo ok", in: root)
    let result = try await runner.run(script, arguments: [], environment: [:], workingDirectory: nil)
    #expect(result.exitCode == 0)
  }

  @Test("WIN-008 rejects executables outside the allow-list", arguments: ["/bin/echo", "/usr/bin/env", "/bin/sh"])
  func rejectsOthers(path: String) async throws {
    await #expect(throws: ProcessRunnerError.executableNotAllowed(path)) {
      _ = try await SystemProcessRunner().run(
        URL(filePath: path), arguments: ["x"], environment: [:], workingDirectory: nil)
    }
  }

  @Test("WIN-008 rejects an executable below a path that merely shares an allowed root's prefix")
  func rejectsSiblingPrefix() async throws {
    let dir = try runnerTempDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let root = dir.appending(path: "wine", directoryHint: .isDirectory)
    let evil = dir.appending(path: "wine-evil", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: evil, withIntermediateDirectories: true)
    let script = try writeScript("echo hi", in: evil)
    await #expect(throws: ProcessRunnerError.self) {
      _ = try await SystemProcessRunner(allowedRoots: [root]).run(
        script, arguments: [], environment: [:], workingDirectory: nil)
    }
  }

  @Test("WIN-008 rejects a path that escapes the allowed root with ..")
  func rejectsTraversal() async throws {
    let dir = try runnerTempDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let root = dir.appending(path: "wine", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let escape = URL(filePath: root.path + "/../../../../../../bin/echo")
    await #expect(throws: ProcessRunnerError.self) {
      _ = try await SystemProcessRunner(allowedRoots: [root]).run(
        escape, arguments: ["x"], environment: [:], workingDirectory: nil)
    }
  }

  @Test("WIN-012 runs a script below an allowed root with arguments and returns combined output")
  func runsScriptWithArguments() async throws {
    let dir = try runnerTempDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let script = try writeScript("echo \"args:$1,$2\"; echo oops >&2", in: dir)
    let result = try await SystemProcessRunner(allowedRoots: [dir]).run(
      script, arguments: ["one", "two words"], environment: [:], workingDirectory: nil)
    #expect(result.exitCode == 0)
    #expect(result.output.contains("args:one,two words"))
    #expect(result.output.contains("oops"))
  }

  @Test("WIN-012 non-zero exit code is returned, not thrown")
  func nonZeroExit() async throws {
    let dir = try runnerTempDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let script = try writeScript("echo failing; exit 3", in: dir)
    let result = try await SystemProcessRunner(allowedRoots: [dir]).run(
      script, arguments: [], environment: [:], workingDirectory: nil)
    #expect(result == ProcessResult(exitCode: 3, output: result.output))
    #expect(result.output.contains("failing"))
  }

  @Test("WIN-012 provided environment variables are visible and inherited ones are kept")
  func environmentMerged() async throws {
    let dir = try runnerTempDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let script = try writeScript("echo \"WINEPREFIX=$WINEPREFIX\"; echo \"HOME=$HOME\"", in: dir)
    let result = try await SystemProcessRunner(allowedRoots: [dir]).run(
      script, arguments: [], environment: ["WINEPREFIX": "/fake/prefix"], workingDirectory: nil)
    #expect(result.output.contains("WINEPREFIX=/fake/prefix"))
    let home = try #require(ProcessInfo.processInfo.environment["HOME"])
    #expect(result.output.contains("HOME=\(home)"))
  }

  @Test("WIN-012 provided environment overrides the inherited value")
  func environmentOverrides() async throws {
    let dir = try runnerTempDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let script = try writeScript("echo \"HOME=$HOME\"", in: dir)
    let result = try await SystemProcessRunner(allowedRoots: [dir]).run(
      script, arguments: [], environment: ["HOME": "/override/home"], workingDirectory: nil)
    #expect(result.output.contains("HOME=/override/home"))
  }

  @Test("WIN-012 runs in the given working directory")
  func workingDirectory() async throws {
    let dir = try runnerTempDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let cwd = dir.appending(path: "cwd", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: cwd, withIntermediateDirectories: true)
    let script = try writeScript("pwd", in: dir)
    let result = try await SystemProcessRunner(allowedRoots: [dir]).run(
      script, arguments: [], environment: [:], workingDirectory: cwd)
    let printed = URL(filePath: result.output.trimmingCharacters(in: .whitespacesAndNewlines))
    #expect(printed.resolvingSymlinksInPath().path == cwd.resolvingSymlinksInPath().path)
  }

  @Test("WIN-012 cancelling the task terminates the child promptly")
  func cancellationKillsChild() async throws {
    let dir = try runnerTempDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let pidFile = dir.appending(path: "pid")
    // exec so the recorded pid is the sleeping process itself and no orphan keeps the pipe open.
    let script = try writeScript("echo $$ > \"$1\"\nexec sleep 30", in: dir)
    let runner = SystemProcessRunner(allowedRoots: [dir])
    let started = ContinuousClock.now
    let task = Task { try await runner.run(script, arguments: [pidFile.path], environment: [:], workingDirectory: nil) }
    for _ in 0..<100 where !FileManager.default.fileExists(atPath: pidFile.path) {
      try await Task.sleep(for: .milliseconds(50))
    }
    let pidText = try String(contentsOf: pidFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
    let pid = try #require(Int32(pidText))
    task.cancel()
    _ = await task.result
    #expect(ContinuousClock.now - started < .seconds(15))
    var alive = true
    for _ in 0..<50 where alive {
      alive = kill(pid, 0) == 0
      if alive { try await Task.sleep(for: .milliseconds(100)) }
    }
    #expect(!alive, "child \(pid) still running after cancel")
    if alive { kill(pid, SIGKILL) }
  }
}
