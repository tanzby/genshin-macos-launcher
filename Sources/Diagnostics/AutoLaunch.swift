import Foundation
import Launcher
import Platform

/// Command-line switches that let a script (`scripts/diag/genshin-launcher-diag`) drive the app without clicks (APP-020,
/// the replacement of the TS launcher's `GENSHIN_LAUNCHER_AUTOLAUNCH`). Each switch is a flag or an environment
/// variable, so `open --env KEY=VALUE App.app` works as well as `App --autolaunch`.
///
/// | Argument | Environment | Meaning |
/// |---|---|---|
/// | `--autolaunch` | `GENSHIN_LAUNCHER_AUTOLAUNCH=1` | prepare Wine, install the game if needed, launch, quit when the game exits |
/// | `--data-dir <path>` | `GENSHIN_LAUNCHER_DATA_DIR` | use this data directory instead of `~/Library/Application Support/Genshin Launcher` |
/// | `--game-dir <path>` | `GENSHIN_LAUNCHER_GAME_DIR` | use this game directory instead of the saved setting |
/// | `--allow-download` | `GENSHIN_LAUNCHER_ALLOW_DOWNLOAD=1` | install a missing game or update an old one (tens of GB); without it such a run fails |
public struct AutoLaunchOptions: Sendable, Equatable {
  public var enabled: Bool
  public var dataRoot: URL?
  public var gameDirectory: URL?
  public var allowDownload: Bool

  public init(enabled: Bool = false, dataRoot: URL? = nil, gameDirectory: URL? = nil, allowDownload: Bool = false) {
    self.enabled = enabled
    self.dataRoot = dataRoot
    self.gameDirectory = gameDirectory
    self.allowDownload = allowDownload
  }

  /// The data directory to use. An overridden root is a sandbox for a test run: the cleanup of the
  /// real Application Support leftovers outside it (WebKit caches of the TS app) must not run for it.
  public func prepareDataDirectory() throws -> DataDirectory {
    guard let dataRoot else { return try DataDirectory.prepare() }
    return try DataDirectory.prepare(root: dataRoot, externalResidue: [])
  }

  public static var current: AutoLaunchOptions {
    parse(arguments: CommandLine.arguments, environment: ProcessInfo.processInfo.environment)
  }

  public static func parse(arguments: [String], environment: [String: String]) -> AutoLaunchOptions {
    func value(_ flag: String, _ variable: String) -> URL? {
      let raw: String?
      if let index = arguments.firstIndex(of: flag), arguments.indices.contains(index + 1) {
        raw = arguments[index + 1]
      } else {
        raw = environment[variable]
      }
      guard let raw, !raw.isEmpty else { return nil }
      return URL(filePath: (raw as NSString).expandingTildeInPath, directoryHint: .isDirectory)
    }
    func isSet(_ flag: String, _ variable: String) -> Bool {
      arguments.contains(flag) || ["1", "true"].contains(environment[variable] ?? "")
    }
    return AutoLaunchOptions(
      enabled: isSet("--autolaunch", "GENSHIN_LAUNCHER_AUTOLAUNCH"),
      dataRoot: value("--data-dir", "GENSHIN_LAUNCHER_DATA_DIR"),
      gameDirectory: value("--game-dir", "GENSHIN_LAUNCHER_GAME_DIR"),
      allowDownload: isSet("--allow-download", "GENSHIN_LAUNCHER_ALLOW_DOWNLOAD"))
  }
}

/// Appends timestamped `key=value` lines to `<data>/logs/launcher.log`, the file the diag script reads.
public final class DiagLog: Sendable {
  public static let fileName = "launcher.log"
  public let file: URL
  private let lock = NSLock()

  public init(logsDirectory: URL) {
    file = logsDirectory.appending(path: Self.fileName, directoryHint: .notDirectory)
    try? FileManager.default.createDirectory(at: logsDirectory, withIntermediateDirectories: true)
  }

  /// Starts a fresh file, so a reader never sees lines of an earlier run.
  public func reset() {
    lock.withLock { try? Data().write(to: file) }
  }

  public func say(_ message: String) {
    let line = "\(ISO8601DateFormatter().string(from: Date())) \(message)\n"
    lock.withLock {
      guard let handle = try? FileHandle(forWritingTo: file) else {
        try? Data(line.utf8).write(to: file)
        return
      }
      defer { try? handle.close() }
      _ = try? handle.seekToEnd()
      try? handle.write(contentsOf: Data(line.utf8))
    }
  }
}

/// Runs the startup, optional install and launch of one session without a user, and reports each step in the
/// log. The last line is always `autolaunch: result=ok` or `autolaunch: result=failed reason=…`, so a
/// script can wait for a verdict instead of a timeout.
@MainActor
public struct AutoLaunch {
  public enum Result: Equatable, Sendable {
    case ok
    case failed(String)
  }

  private static var started = false

  let model: LauncherModel
  let log: DiagLog
  let pollInterval: Duration
  let progressInterval: Duration
  let allowDownload: Bool

  public init(
    model: LauncherModel, log: DiagLog, pollInterval: Duration = .milliseconds(200),
    progressInterval: Duration = .seconds(5), allowDownload: Bool = false
  ) {
    self.model = model
    self.log = log
    self.pollInterval = pollInterval
    self.progressInterval = progressInterval
    self.allowDownload = allowDownload
  }

  public func run() async -> Result {
    log.say("autolaunch: start")
    let watcher = Task { await watchPhase() }
    defer { watcher.cancel() }
    let result = await drive()
    switch result {
    case .ok: log.say("autolaunch: result=ok")
    case .failed(let reason): log.say("autolaunch: result=failed reason=\(reason)")
    }
    return result
  }

  private func drive() async -> Result {
    await model.bootstrap()
    await waitUntilIdle()
    if let error = model.lastError { return .failed("bootstrap \(error)") }
    log.say("autolaunch: ready wine=\(String(describing: model.wineStatus)) action=\(model.primaryAction)")

    // A missing game is installed, an old one updated: the diag also covers the download.
    // (An install can be followed by an update; more than two rounds means the status never settles.)
    for _ in 0..<2 where model.primaryAction == .install || model.primaryAction == .update {
      let job: GameJob = model.primaryAction == .install ? .install : .update
      // A diag run must never start a 100+ GB download (or rewrite a game folder) by accident.
      guard allowDownload else { return .failed("needs \(job.rawValue) (pass --allow-download)") }
      do { try await model.start(job) } catch { return .failed("\(job.rawValue) \(error)") }
      await waitUntilIdle()
      if let error = model.lastError { return .failed("\(job.rawValue) \(error)") }
      await model.refresh()
    }
    guard model.primaryAction == .launch else { return .failed("action=\(model.primaryAction)") }

    do { try await model.launch() } catch { return .failed("launch \(error)") }
    await waitUntilIdle()
    if let error = model.lastError { return .failed("game \(error)") }
    return .ok
  }

  private func waitUntilIdle() async {
    while model.phase != .idle {
      try? await Task.sleep(for: pollInterval)
    }
  }

  /// One line per phase change, and a progress line every `progressInterval` while a job runs.
  private func watchPhase() async {
    let model = model
    let progress = Task { @MainActor in
      while !Task.isCancelled {
        try? await Task.sleep(for: progressInterval)
        if model.phase != .idle, let value = model.progress {
          log.say("autolaunch: progress=\(String(String(describing: value).prefix(160)))")
        }
      }
    }
    defer { progress.cancel() }
    for await phase in Observations({ model.phase }) {
      log.say("autolaunch: phase=\(phase)")
    }
  }

  /// The verdict of a run that never started because the data directory could not be prepared. `genshin-launcher-diag`
  /// polls for the result line and the exit line, so the composition root writes them too when it stops early.
  public static func reportPrepareFailure(_ error: any Error, to log: DiagLog) {
    log.say("autolaunch: result=failed reason=data-dir \(error)")
    log.say("autolaunch: exit")
  }

  /// The app entry point: does nothing unless `--autolaunch` was given; otherwise runs and then asks the
  /// app to quit, also when it failed (a diag script must never wait for a window nobody closes).
  public static func runIfRequested(
    _ options: AutoLaunchOptions, model: LauncherModel, log: DiagLog, terminate: @MainActor () -> Void,
    forceExit: @MainActor () -> Void = { exit(0) }
  ) async {
    guard options.enabled, !started else { return }
    started = true  // the window's `.task` runs again when the window is recreated
    log.reset()
    // The composition root does this too; it is idempotent (the marker is written once).
    do { _ = try options.prepareDataDirectory() } catch {
      reportPrepareFailure(error, to: log)
      terminate()
      return
    }
    if let directory = options.gameDirectory { model.gameDirectory = directory }
    _ = await AutoLaunch(model: model, log: log, allowDownload: options.allowDownload).run()
    await model.shutdown()
    log.say("autolaunch: exit")
    terminate()
    // `terminate()` can still be refused (a modal alert is up); the run is over and its
    // state is restored, so a diag script must not wait on a window nobody closes.
    try? await Task.sleep(for: .seconds(3))
    forceExit()
  }
}
