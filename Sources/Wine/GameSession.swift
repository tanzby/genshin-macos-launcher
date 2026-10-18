import Foundation
import Platform
import os

private let log = Logger(subsystem: "io.github.tanzby.genshin-launcher", category: "wine")

/// Executes a `LaunchRecipe`: launch mutations, run, wait, restore.
package struct GameSession: Sendable {
  /// Bundle id of `GenshinLauncherGame.app` (UPD-017). `codesign -i` must use the same id.
  package static let gameHostBundleIdentifier = "io.github.tanzby.genshin-launcher.game"
  static let keptGameLogs = 20

  let layout: WineLayout
  let runner: any ProcessRunning
  let processes: any ProcessTable
  let timing: LaunchTiming
  let commands: WinePrefixCommands
  let cleanup: PrefixCleanup
  let mutations: LaunchMutations
  let hostInstaller: GameHostInstaller

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
    self.timing = timing
    commands = WinePrefixCommands(layout: layout, runner: runner)
    cleanup = PrefixCleanup(commands: commands, processes: processes)
    mutations = LaunchMutations(commands: commands)
    hostInstaller = GameHostInstaller(layout: layout, runner: runner, launchServices: launchServices, helpers: helpers)
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
    await cleanup.shutdown()
    await mutations.restore()
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
      let hostEnvironment = await hostInstaller.prepare(for: recipe)
      try Task.checkCancellation()

      try await mutations.apply(recipe)
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
        await cleanup.shutdown()
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
      await cleanup.shutdown()
    } else {
      await waitForPrefixExit()
    }
    await mutations.restore()
  }

  /// `wineserver -w` raced against the grace period; on timeout the prefix is killed (LCH-036).
  private func waitForPrefixExit() async {
    let exited = await withTaskGroup(of: Bool.self) { group in
      group.addTask {
        _ = try? await commands.wineserver("-w")
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
      await cleanup.shutdown()
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

  // MARK: - Process helpers

  /// `layout.wineEnvironment` plus the game's own variables; empty values are dropped (LCH-035).
  private func launchEnvironment(for recipe: LaunchRecipe) -> [String: String] {
    layout.wineEnvironment.merging(recipe.environment.filter { !$0.value.isEmpty }) { _, new in new }
  }

  /// A Unix path as Wine sees it on the `Z:` drive.
  package static func windowsPath(_ url: URL) -> String {
    "Z:" + url.path.replacingOccurrences(of: "/", with: "\\")
  }
}
