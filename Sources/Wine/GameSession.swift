import Foundation
import Platform
import os

private let log = Logger(subsystem: "io.github.tanzby.yaagl", category: "wine")

/// Executes a `LaunchRecipe`: launch mutations, run, wait, restore.
package struct GameSession: Sendable {
  /// Bundle id of `YaaglGame.app` (UPD-017). `codesign -i` must use the same id.
  package static let gameHostBundleIdentifier = "io.github.tanzby.yaagl.game"
  static let keptGameLogs = 20

  let layout: WineLayout
  let runner: any ProcessRunning
  let processes: any ProcessTable
  let launchServices: any LaunchServicesRegistering
  let helpers: GameHostHelpers?
  let timing: LaunchTiming

  package init(
    layout: WineLayout,
    runner: any ProcessRunning,
    processes: any ProcessTable = SystemProcessTable(),
    launchServices: any LaunchServicesRegistering,
    helpers: GameHostHelpers?,
    timing: LaunchTiming = LaunchTiming()
  ) {
    self.layout = layout
    self.runner = runner
    self.processes = processes
    self.launchServices = launchServices
    self.helpers = helpers
    self.timing = timing
  }

  /// Runs the game and restores everything afterwards. Never throws: the outcome is the result.
  /// `onStarted` is called at most once, from the startup watchdog, when the game process is first seen.
  package func launch(_ recipe: LaunchRecipe, onStarted: @escaping @Sendable () -> Void = {}) async -> LaunchResult {
    let timedOut = OSAllocatedUnfairLock(initialState: false)
    let work = Task { await run(recipe) }
    let watchdog = Task { await watchStartup(recipe, timedOut: timedOut, work: work, onStarted: onStarted) }
    let result = await withTaskCancellationHandler {
      await work.value
    } onCancel: {
      work.cancel()
    }
    watchdog.cancel()
    let didTimeOut = timedOut.withLock { $0 }
    let cancelled = Task.isCancelled
    // Cleanup is async (wineserver, reg) and must also run when this task is cancelled. A new unstructured
    // Task does not inherit the cancellation, so its child awaits are not cut short.
    await Task { await finish(killNow: didTimeOut || cancelled || result == .cancelled) }.value
    if didTimeOut { return .startupTimedOut }
    if cancelled { return .cancelled }
    return result
  }

  /// Kills what is left of the prefix and replays the journal of a crashed launch (ADR 0002).
  package func recover() async {
    await shutdownPrefix()
    await restoreFromJournal()
  }

  /// `start /wait` gives `cmd` its own console window: the runner hands Wine `/dev/null` as stdin, so a bare
  /// `wine cmd` would read EOF and exit at once. Needs a check on a real Mac (#15 diag).
  static let commandPromptArguments = ["start", "/wait", "cmd"]

  /// Opens an interactive `wine cmd` in the game's prefix (CFG-032, WIN-022): same loader, `WINEPREFIX`,
  /// `WINEDEBUG` and recipe environment as a launch, plus `WINEPATH` pointing at the game directory.
  /// Touches neither the registry nor the journal. Returns the exit code once the prompt is
  /// closed, or `nil` if Wine could not be started.
  package func openCommandPrompt(_ recipe: LaunchRecipe, gameDirectory: URL?) async -> Int32? {
    var environment = launchEnvironment(for: recipe)
    if let gameDirectory { environment["WINEPATH"] = Self.windowsPath(gameDirectory) }
    do {
      return try await runner.run(
        layout.loader, arguments: Self.commandPromptArguments, environment: environment, workingDirectory: layout.root
      ).exitCode
    } catch {
      log.error("wine cmd failed: \(String(describing: error), privacy: .public)")
      return nil
    }
  }

  // MARK: - Launch

  private func run(_ recipe: LaunchRecipe) async -> LaunchResult {
    do {
      // A journal left by a crash holds the player's real registry values. Replay it before reading
      // "originals", or the forced values of the crashed session would be saved as the originals.
      // Run it uncancellable: a half-done restore in a cancelled task would still delete the journal.
      await Task { await recover() }.value
      try Task.checkCancellation()
      let hostEnvironment = await GameHostInstaller(
        layout: layout, runner: runner, launchServices: launchServices, helpers: helpers
      ).prepare(for: recipe)
      try Task.checkCancellation()

      // Items a previous restore could not finish stay in the journal with their real originals; the
      // values on disk now are not the player's.
      var journal = readJournal() ?? LaunchJournal()
      for path in recipe.moveAside.map(\.path) where !journal.movedAside.contains(path) {
        journal.movedAside.append(path)
      }
      for edit in recipe.registry where edit.restoresOnExit {
        if journal.registry.contains(where: { $0.key == edit.key && $0.name == edit.name }) { continue }
        journal.registry.append(
          .init(key: edit.key, name: edit.name, original: try await queryRegistry(key: edit.key, name: edit.name)))
      }
      try writeJournal(journal)

      for file in recipe.moveAside { try moveAside(file) }
      try applyPrefixCopies(recipe.prefixCopies)
      for edit in recipe.registry { try await apply(edit) }
      _ = try? await wineserver("-w")  // let the registry settle (LCH-009)
      try Task.checkCancellation()

      let fileManager = FileManager.default
      try fileManager.createDirectory(at: layout.logsDirectory, withIntermediateDirectories: true)
      let logFile = layout.logsDirectory.appending(
        path: "game_\(Int(Date().timeIntervalSince1970 * 1000)).log", directoryHint: .notDirectory)
      pruneGameLogs(keeping: logFile)

      let environment = launchEnvironment(for: recipe).merging(hostEnvironment) { _, new in new }
      let code = try await runner.runLogging(
        layout.loader, arguments: recipe.command, environment: environment,
        workingDirectory: layout.root, logFile: logFile)
      if Task.isCancelled { return .cancelled }
      return code == 0 ? .exited : .failedExit(code: code, log: logFile)
    } catch is CancellationError {
      return .cancelled
    } catch {
      if Task.isCancelled { return .cancelled }
      log.error("launch failed: \(String(describing: error), privacy: .public)")
      return .failedToLaunch(reason: String(describing: error))
    }
  }

  /// Counts poll intervals instead of reading a clock, so tests run in milliseconds. The clock starts with
  /// the launch, which also bounds preparation (`wineserver -w` has no timeout of its own, LCH-009).
  private func watchStartup(
    _ recipe: LaunchRecipe, timedOut: OSAllocatedUnfairLock<Bool>, work: Task<LaunchResult, Never>, onStarted: @Sendable () -> Void
  ) async {
    var elapsed = Duration.zero
    while !Task.isCancelled {
      do { try await timing.sleep(timing.pollInterval) } catch { return }
      elapsed += timing.pollInterval
      if gameIsRunning(recipe) {
        onStarted()
        return
      }
      if elapsed >= timing.startupTimeout {
        timedOut.withLock { $0 = true }
        work.cancel()
        // A loader that ignores SIGTERM must not hold the timeout hostage: close the prefix from here too.
        await shutdownPrefix()
        return
      }
    }
  }

  /// Mirrors the shim: a Windows process whose first argument contains the game executable.
  private func gameIsRunning(_ recipe: LaunchRecipe) -> Bool {
    guard !recipe.gameExecutableName.isEmpty else { return false }
    return processes.processes(includeOpenPaths: false).contains {
      $0.arguments.count > 1 && $0.arguments[1].range(of: recipe.gameExecutableName, options: .caseInsensitive) != nil
    }
  }

  // MARK: - Finish

  private func finish(killNow: Bool) async {
    if killNow {
      await shutdownPrefix()
    } else {
      await waitForPrefixExit()
    }
    await restoreFromJournal()
  }

  /// `wineserver -w` raced against the grace period; on timeout the prefix is killed (LCH-036).
  private func waitForPrefixExit() async {
    let exited = await withTaskGroup(of: Bool.self) { group in
      group.addTask {
        _ = try? await wineserver("-w")
        return true
      }
      group.addTask {
        try? await timing.sleep(timing.exitGrace)
        return false
      }
      let first = await group.next() ?? false
      group.cancelAll()
      return first
    }
    if !exited {
      log.error("Wine did not exit within the grace period, shutting it down")
      await shutdownPrefix()
    }
  }

  /// `wineserver -k`, then SIGKILL for what is left: processes holding the prefix's server directory, and
  /// orphans whose Windows command line starts at `C:\` or `Z:\` with the prefix as working directory.
  func shutdownPrefix() async {
    _ = try? await wineserver("-k")
    let serverDirectory = Self.serverDirectory(for: layout.prefixDirectory)
    let prefixPath = layout.prefixDirectory.resolvingSymlinksInPath().path
    let own = ProcessInfo.processInfo.processIdentifier
    for process in processes.processes(includeOpenPaths: true) where process.pid != own {
      // `/tmp` is a symlink to `/private/tmp`, and libproc reports the resolved path.
      let holdsServer =
        serverDirectory.map { directory in
          process.openPaths.contains { $0.hasPrefix(directory + "/") || $0.hasPrefix("/private" + directory + "/") }
        } ?? false
      let orphan =
        (process.arguments.first.map { $0.hasPrefix("C:\\") || $0.hasPrefix("Z:\\") } ?? false)
        && (process.workingDirectory.map { Self.isInside($0, directory: prefixPath) } ?? false)
      if holdsServer || orphan { processes.kill(process.pid) }
    }
  }

  static func serverDirectory(for prefix: URL) -> String? {
    var info = stat()
    guard stat(prefix.path, &info) == 0 else { return nil }
    let device = String(UInt64(bitPattern: Int64(info.st_dev)), radix: 16)
    let inode = String(info.st_ino, radix: 16)
    return "/tmp/.wine-\(getuid())/server-\(device)-\(inode)"
  }

  private static func isInside(_ path: String, directory: String) -> Bool {
    let resolved = URL(filePath: path).resolvingSymlinksInPath().path
    return resolved == directory || resolved.hasPrefix(directory + "/")
  }

  // MARK: - Mutations

  private func moveAside(_ file: URL) throws {
    let fileManager = FileManager.default
    let backup = URL(filePath: file.path + ".bak")
    guard fileManager.fileExists(atPath: file.path) else { return }  // already aside, or never there
    // The live file wins over a stale .bak (a repair re-downloads the original).
    if fileManager.fileExists(atPath: backup.path) { try fileManager.removeItem(at: backup) }
    try fileManager.moveItem(at: file, to: backup)
  }

  private func applyPrefixCopies(_ copies: [PrefixCopy]) throws {
    let fileManager = FileManager.default
    for copy in copies {
      let destination = layout.prefixWindows.appending(path: copy.destination, directoryHint: .notDirectory)
      if fileManager.fileExists(atPath: destination.path),
        fileManager.contentsEqual(atPath: copy.source.path, andPath: destination.path)
      {
        continue
      }
      try fileManager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
      if fileManager.fileExists(atPath: destination.path) { try fileManager.removeItem(at: destination) }
      try fileManager.copyItem(at: copy.source, to: destination)
    }
  }

  private func pruneGameLogs(keeping current: URL) {
    let fileManager = FileManager.default
    guard let names = try? fileManager.contentsOfDirectory(atPath: layout.logsDirectory.path) else { return }
    // The new log does not exist yet; keep one slot for it.
    let logs = names.filter { $0.hasPrefix("game_") && $0.hasSuffix(".log") }.sorted().reversed()
    for name in logs.dropFirst(Self.keptGameLogs - 1) {
      try? fileManager.removeItem(at: layout.logsDirectory.appending(path: name))
    }
  }

  // MARK: - Journal

  private func writeJournal(_ journal: LaunchJournal) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try encoder.encode(journal).write(to: layout.launchJournal, options: .atomic)
  }

  private func readJournal() -> LaunchJournal? {
    guard let data = try? Data(contentsOf: layout.launchJournal) else { return nil }
    if let journal = try? JSONDecoder().decode(LaunchJournal.self, from: data) { return journal }
    log.error("unreadable launch journal, set aside for inspection")
    let aside = layout.launchJournal.deletingLastPathComponent().appending(path: "launch-journal.corrupt.json")
    try? FileManager.default.removeItem(at: aside)
    try? FileManager.default.moveItem(at: layout.launchJournal, to: aside)
    return nil
  }

  /// Puts everything the journal records back, item by item against the disk's actual state. Items that
  /// fail stay in the journal for the next `recover()`; it is deleted only when nothing is left.
  private func restoreFromJournal() async {
    let fileManager = FileManager.default
    guard let journal = readJournal() else { return }
    var remaining = LaunchJournal()
    for path in journal.movedAside {
      let backup = path + ".bak"
      guard fileManager.fileExists(atPath: backup) else { continue }
      do {
        if fileManager.fileExists(atPath: path) {
          try fileManager.removeItem(atPath: backup)  // the live file wins
        } else {
          try fileManager.moveItem(atPath: backup, toPath: path)
        }
      } catch {
        log.error("could not restore \(path, privacy: .public): \(String(describing: error), privacy: .public)")
        remaining.movedAside.append(path)
      }
    }
    for entry in journal.registry {
      let restored =
        if let original = entry.original {
          (try? await regSet(entry.key, entry.name, original))?.exitCode == 0
        } else {
          // Deleting a value that is not there exits non-zero; only a launch failure counts as not restored.
          (try? await regDelete(entry.key, entry.name)) != nil
        }
      if !restored { remaining.registry.append(entry) }
    }
    if !journal.registry.isEmpty { _ = try? await wineserver("-w") }
    if remaining.movedAside.isEmpty && remaining.registry.isEmpty {
      try? fileManager.removeItem(at: layout.launchJournal)
    } else {
      try? writeJournal(remaining)
    }
  }

  // MARK: - Registry

  private func apply(_ edit: RegistryEdit) async throws {
    switch edit.action {
    case .set(let value):
      let result = try await regSet(edit.key, edit.name, value)
      guard result.exitCode == 0 else { throw LaunchError.registryWriteFailed(key: edit.key, name: edit.name) }
    case .delete:
      _ = try await regDelete(edit.key, edit.name)  // deleting a value that is not there exits non-zero and is fine
    }
  }

  static func registryArguments(_ value: RegistryValue) -> [String] {
    switch value {
    case .dword(let number): ["/t", "REG_DWORD", "/d", String(number)]
    case .string(let text): ["/t", "REG_SZ", "/d", text]
    }
  }

  func queryRegistry(key: String, name: String) async throws -> RegistryValue? {
    let result = try await reg(["query", key, "/v", name])
    guard result.exitCode == 0 else { return nil }
    return Self.parseRegistryQuery(result.output, name: name)
  }

  /// Parses `reg query` output: `    <name>    REG_DWORD    0xa00` or `    <name>    REG_SZ    text`.
  static func parseRegistryQuery(_ output: String, name: String) -> RegistryValue? {
    for line in output.components(separatedBy: .newlines) {
      let trimmed = line.trimmingCharacters(in: .whitespaces)
      guard trimmed.hasPrefix(name) else { continue }
      let rest = trimmed.dropFirst(name.count)
      guard rest.first?.isWhitespace == true else { continue }
      let parts = rest.split(maxSplits: 1, whereSeparator: \.isWhitespace)
      guard parts.count == 2 else { continue }
      let data = parts[1].trimmingCharacters(in: .whitespaces)
      switch parts[0] {
      case "REG_DWORD":
        let digits = data.lowercased().hasPrefix("0x") ? String(data.dropFirst(2)) : data
        return UInt32(digits, radix: 16).map(RegistryValue.dword)
      case "REG_SZ":
        return .string(data)
      default:
        return nil
      }
    }
    return nil
  }

  // MARK: - Process helpers

  /// `layout.wineEnvironment` plus the game's own variables; empty values are dropped (LCH-035).
  private func launchEnvironment(for recipe: LaunchRecipe) -> [String: String] {
    layout.wineEnvironment.merging(recipe.environment.filter { !$0.value.isEmpty }) { _, new in new }
  }

  private func regSet(_ key: String, _ name: String, _ value: RegistryValue) async throws -> ProcessResult {
    try await reg(["add", key, "/v", name] + Self.registryArguments(value) + ["/f"])
  }

  private func regDelete(_ key: String, _ name: String) async throws -> ProcessResult {
    try await reg(["delete", key, "/v", name, "/f"])
  }

  private func reg(_ arguments: [String]) async throws -> ProcessResult {
    try await runner.run(
      layout.loader, arguments: ["reg"] + arguments, environment: layout.wineEnvironment, workingDirectory: layout.root)
  }

  private func wineserver(_ flag: String) async throws -> ProcessResult {
    try await runner.run(
      layout.wineserver, arguments: [flag], environment: ["WINEPREFIX": layout.prefixDirectory.path],
      workingDirectory: layout.root)
  }

  /// A Unix path as Wine sees it on the `Z:` drive.
  package static func windowsPath(_ url: URL) -> String {
    "Z:" + url.path.replacingOccurrences(of: "/", with: "\\")
  }
}

enum LaunchError: Error, Equatable {
  case registryWriteFailed(key: String, name: String)
}
