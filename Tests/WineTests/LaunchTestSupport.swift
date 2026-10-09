import Darwin
import Foundation
import Platform
import Testing

@testable import Wine

// Fakes and fixtures for the GameSession tests (ticket #11). Everything is a fake process runner, a fake
// process table and a temporary directory; no real Wine, no real process, no network. All byte payloads are
// short marker strings; nothing here is a secret.

// MARK: - Small helpers

final class Locked<Value>: @unchecked Sendable {
  private let lock = NSLock()
  private var _value: Value
  init(_ value: Value) { _value = value }
  var value: Value {
    get { lock.withLock { _value } }
    set { lock.withLock { _value = newValue } }
  }
  func mutate<R>(_ body: (inout Value) -> R) -> R { lock.withLock { body(&_value) } }
}

/// One ordered log shared by every fake, so tests can assert cross-fake ordering (`-k` then kills then restore).
final class LaunchTrace: @unchecked Sendable {
  private let events = Locked<[String]>([])
  func append(_ event: String) { events.mutate { $0.append(event) } }
  var all: [String] { events.value }
  func firstIndex(where predicate: (String) -> Bool) -> Int? { all.firstIndex(where: predicate) }
  func lastIndex(where predicate: (String) -> Bool) -> Int? { all.lastIndex(where: predicate) }
}

struct FakeFailure: Error, Equatable { var message = "fake failure" }

extension LaunchResult {
  var isFailedToLaunch: Bool {
    if case .failedToLaunch = self { return true }
    return false
  }
}

func launchWrite(_ text: String, to url: URL) throws {
  try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
  try Data(text.utf8).write(to: url)
}

func launchRead(_ url: URL) -> String? {
  (try? Data(contentsOf: url)).map { String(decoding: $0, as: UTF8.self) }
}

func launchModificationDate(_ url: URL) -> Date? {
  (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
}

func launchSetModificationDate(_ date: Date, of url: URL) throws {
  try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
}

// MARK: - Registry constants and argv builders

enum LaunchRegistry {
  static let miHoYoKey = #"HKCU\Software\miHoYo\原神"#
  static let macDriverKey = #"HKCU\Software\Wine\Mac Driver"#
  static let widthName = "Screenmanager Resolution Width_h182942802"
  static let heightName = "Screenmanager Resolution Height_h2627697771"
  static let fullscreenName = "Screenmanager Is Fullscreen mode_h3981298716"
  static let hdrName = "WINDOWS_HDR_ON_h3132281285"

  static func regID(_ key: String, _ name: String) -> String { key + " :: " + name }

  static func widthEdit(_ value: UInt32, restores: Bool = true) -> RegistryEdit {
    RegistryEdit(key: miHoYoKey, name: widthName, action: .set(.dword(value)), restoresOnExit: restores)
  }
  static func heightEdit(_ value: UInt32, restores: Bool = true) -> RegistryEdit {
    RegistryEdit(key: miHoYoKey, name: heightName, action: .set(.dword(value)), restoresOnExit: restores)
  }
  static func retinaEdit(_ value: String) -> RegistryEdit {
    RegistryEdit(key: macDriverKey, name: "RetinaMode", action: .set(.string(value)), restoresOnExit: false)
  }
}

func regAddDwordArgs(_ key: String, _ name: String, _ value: UInt32) -> [String] {
  ["reg", "add", key, "/v", name, "/t", "REG_DWORD", "/d", String(value), "/f"]
}
func regAddStringArgs(_ key: String, _ name: String, _ value: String) -> [String] {
  ["reg", "add", key, "/v", name, "/t", "REG_SZ", "/d", value, "/f"]
}
func regDeleteArgs(_ key: String, _ name: String) -> [String] { ["reg", "delete", key, "/v", name, "/f"] }
func regQueryArgs(_ key: String, _ name: String) -> [String] { ["reg", "query", key, "/v", name] }

/// The label the runner appends to the trace for a loader call.
func loaderLabel(_ args: [String]) -> String { "wine " + args.joined(separator: " ") }

// MARK: - Recorded call

enum FakeCallKind: Sendable, Equatable {
  case wineserverKill, wineserverWait, regQuery, regAdd, regDelete, game, codesign, other
}

struct FakeCall: Sendable, Equatable {
  var executable: String
  var arguments: [String]
  var environment: [String: String]
  var workingDirectory: String?
  /// Non-nil only for `runLogging` (the game).
  var logFile: String?
  var kind: FakeCallKind
  /// Disk state at the moment of the call.
  var journalExisted: Bool
  var configBatchExisted: Bool
}

/// What the world looked like the moment the game started.
struct GameSnapshot: Sendable {
  var journal: LaunchJournal?
  var journalExisted: Bool
  var configBatch: String?
  var registry: [String: RegistryValue]
  /// Watched file path -> text (only for files that exist).
  var files: [String: String]
  var logsDirectoryExists: Bool
  var existing: Set<String>

  func text(_ url: URL) -> String? { files[url.path] }
  func exists(_ url: URL) -> Bool { existing.contains(url.path) }
}

enum FakeGameBehavior: Sendable {
  case exit(Int32)
  /// Runs until the task is cancelled (throws `CancellationError`) or until a `wineserver -k` is recorded
  /// after the game started (returns 137, as a killed loader would).
  case hang
  case fail(any Error)
  case custom(@Sendable (FakeCall) async throws -> Int32)
}

// MARK: - Fake process runner

/// Records every call. Registry calls run against an in-memory registry so tests can assert the final state.
/// Like the real runner it throws `CancellationError` when called from a cancelled task, so a test that
/// cancels `launch` proves the cleanup runs outside the cancelled context.
final class FakeProcessRunner: ProcessRunning, @unchecked Sendable {
  struct State {
    var calls: [FakeCall] = []
    var registry: [String: RegistryValue] = [:]
    var snapshots: [GameSnapshot] = []
    var waitCount = 0
    var watched: [URL] = []
  }

  let layout: WineLayout
  let trace: LaunchTrace
  private let state = Locked(State())
  let game = Locked<FakeGameBehavior>(.exit(0))
  /// 1-based indices among `wineserver -w` calls that never return (until cancelled).
  let hangingWaits = Locked<Set<Int>>([])
  /// Runs first for every non-game call; return nil to fall through to the built-in behaviour.
  let responder = Locked<(@Sendable (FakeCall) async throws -> ProcessResult?)?>(nil)

  init(layout: WineLayout, trace: LaunchTrace) {
    self.layout = layout
    self.trace = trace
  }

  // Inspection

  var calls: [FakeCall] { state.value.calls }
  var snapshots: [GameSnapshot] { state.value.snapshots }
  var gameCalls: [FakeCall] { calls.filter { $0.kind == .game } }
  var gameCall: FakeCall? { gameCalls.first }
  func calls(_ kind: FakeCallKind) -> [FakeCall] { calls.filter { $0.kind == kind } }
  var killCount: Int { calls(.wineserverKill).count }
  func registryValue(_ key: String, _ name: String) -> RegistryValue? {
    state.value.registry[LaunchRegistry.regID(key, name)]
  }
  func setRegistry(_ key: String, _ name: String, _ value: RegistryValue?) {
    state.mutate { $0.registry[LaunchRegistry.regID(key, name)] = value }
  }
  var registrySnapshot: [String: RegistryValue] { state.value.registry }
  func watch(_ urls: [URL]) { state.mutate { $0.watched = urls } }
  /// Index of the n-th (0-based) call of `kind` in `calls`.
  func callIndex(_ kind: FakeCallKind, nth: Int = 0) -> Int? {
    var seen = 0
    for (index, call) in calls.enumerated() where call.kind == kind {
      if seen == nth { return index }
      seen += 1
    }
    return nil
  }

  // ProcessRunning

  func run(
    _ executable: URL, arguments: [String], environment: [String: String], workingDirectory: URL?
  ) async throws -> ProcessResult {
    try Task.checkCancellation()
    let call = record(executable, arguments, environment, workingDirectory, logFile: nil)
    if let responder = responder.value, let result = try await responder(call) { return result }
    switch call.kind {
    case .wineserverWait:
      let index = state.mutate { state -> Int in
        state.waitCount += 1
        return state.waitCount
      }
      if hangingWaits.value.contains(index) {
        while true { try await Task.sleep(for: .milliseconds(2)) }
      }
      return ProcessResult(exitCode: 0, output: "")
    case .regAdd:
      guard arguments.count == 10, arguments[3] == "/v", arguments[5] == "/t", arguments[7] == "/d", arguments[9] == "/f"
      else { return ProcessResult(exitCode: 1, output: "malformed reg add") }
      let value: RegistryValue
      switch arguments[6] {
      case "REG_DWORD":
        guard let number = UInt32(arguments[8]) else { return ProcessResult(exitCode: 1, output: "bad dword") }
        value = .dword(number)
      case "REG_SZ": value = .string(arguments[8])
      default: return ProcessResult(exitCode: 1, output: "bad type")
      }
      state.mutate { $0.registry[LaunchRegistry.regID(arguments[2], arguments[4])] = value }
      return ProcessResult(exitCode: 0, output: "")
    case .regDelete:
      guard arguments.count == 6, arguments[3] == "/v", arguments[5] == "/f" else {
        return ProcessResult(exitCode: 1, output: "malformed reg delete")
      }
      let existed = state.mutate { $0.registry.removeValue(forKey: LaunchRegistry.regID(arguments[2], arguments[4])) }
      return ProcessResult(exitCode: existed == nil ? 1 : 0, output: "")
    case .regQuery:
      guard arguments.count == 5, arguments[3] == "/v" else {
        return ProcessResult(exitCode: 1, output: "malformed reg query")
      }
      guard let value = state.value.registry[LaunchRegistry.regID(arguments[2], arguments[4])] else {
        return ProcessResult(exitCode: 1, output: "ERROR: The system was unable to find the specified registry key or value.")
      }
      switch value {
      case .dword(let number):
        return ProcessResult(
          exitCode: 0, output: "\n    \(arguments[4])    REG_DWORD    0x\(String(number, radix: 16))\n")
      case .string(let text):
        return ProcessResult(exitCode: 0, output: "\n    \(arguments[4])    REG_SZ    \(text)\n")
      }
    default:
      return ProcessResult(exitCode: 0, output: "")
    }
  }

  func runLogging(
    _ executable: URL, arguments: [String], environment: [String: String], workingDirectory: URL?,
    logFile: URL
  ) async throws -> Int32 {
    try Task.checkCancellation()
    let call = record(executable, arguments, environment, workingDirectory, logFile: logFile)
    takeSnapshot()
    // Like SystemProcessRunner: create the log with Data().write, no mkdir, so a missing logs dir surfaces.
    try Data().write(to: logFile)
    switch game.value {
    case .exit(let code): return code
    case .fail(let error): throw error
    case .custom(let body): return try await body(call)
    case .hang:
      let killsAtStart = killCount
      while true {
        try Task.checkCancellation()
        if killCount > killsAtStart { return 137 }
        try await Task.sleep(for: .milliseconds(2))
      }
    }
  }

  // Internals

  private func classify(_ executable: URL, _ arguments: [String], isGame: Bool) -> FakeCallKind {
    if isGame { return .game }
    if executable.path == layout.wineserver.path {
      if arguments == ["-k"] { return .wineserverKill }
      if arguments == ["-w"] { return .wineserverWait }
      return .other
    }
    if executable.path == "/usr/bin/codesign" { return .codesign }
    if executable.path == layout.loader.path {
      switch (arguments.first, arguments.dropFirst().first) {
      case ("reg", "query"): return .regQuery
      case ("reg", "add"): return .regAdd
      case ("reg", "delete"): return .regDelete
      default: return .other
      }
    }
    return .other
  }

  private func record(
    _ executable: URL, _ arguments: [String], _ environment: [String: String], _ cwd: URL?, logFile: URL?
  ) -> FakeCall {
    let call = FakeCall(
      executable: executable.path, arguments: arguments, environment: environment,
      workingDirectory: cwd?.path, logFile: logFile?.path,
      kind: classify(executable, arguments, isGame: logFile != nil),
      journalExisted: FileManager.default.fileExists(atPath: layout.launchJournal.path),
      configBatchExisted: FileManager.default.fileExists(atPath: layout.configBatch.path))
    state.mutate { $0.calls.append(call) }
    switch call.kind {
    case .wineserverKill: trace.append("wineserver -k")
    case .wineserverWait: trace.append("wineserver -w")
    case .game: trace.append("GAME")
    case .codesign: trace.append("codesign")
    default: trace.append(URL(filePath: executable.path).lastPathComponent + " " + arguments.joined(separator: " "))
    }
    return call
  }

  private func takeSnapshot() {
    let fm = FileManager.default
    let watched = state.value.watched
    var files: [String: String] = [:]
    var existing: Set<String> = []
    for url in watched where fm.fileExists(atPath: url.path) {
      existing.insert(url.path)
      if let text = launchRead(url) { files[url.path] = text }
    }
    let journalData = try? Data(contentsOf: layout.launchJournal)
    let snapshot = GameSnapshot(
      journal: journalData.flatMap { try? JSONDecoder().decode(LaunchJournal.self, from: $0) },
      journalExisted: journalData != nil,
      configBatch: launchRead(layout.configBatch),
      registry: state.value.registry,
      files: files,
      logsDirectoryExists: fm.fileExists(atPath: layout.logsDirectory.path),
      existing: existing)
    state.mutate { $0.snapshots.append(snapshot) }
  }
}

// MARK: - Fake process table

final class FakeProcessTable: ProcessTable, @unchecked Sendable {
  /// The game as the startup probe sees it: argv[1] holds the game executable, argv[0] and cwd are chosen so the
  /// orphan sweep can never match it.
  static let gameRecord = ProcessRecord(
    pid: 4242, arguments: ["/fake/wine", #"Z:\Games\GI\YuanShen.exe"#], workingDirectory: "/Games/GI")

  let trace: LaunchTrace
  /// Answers to `processes(includeOpenPaths: true)` in call order; the last entry repeats.
  let sweepSnapshots = Locked<[[ProcessRecord]]>([[]])
  /// Answers to `processes(includeOpenPaths: false)` by 1-based probe number.
  let probe = Locked<@Sendable (Int) -> [ProcessRecord]>({ _ in [FakeProcessTable.gameRecord] })
  private let log = Locked<(sweeps: Int, probes: Int, killed: [Int32])>((0, 0, []))

  init(trace: LaunchTrace) { self.trace = trace }

  var sweepCount: Int { log.value.sweeps }
  var probeCount: Int { log.value.probes }
  var killed: [Int32] { log.value.killed }

  func processes(includeOpenPaths: Bool) -> [ProcessRecord] {
    if includeOpenPaths {
      let index = log.mutate { state -> Int in
        state.sweeps += 1
        return state.sweeps - 1
      }
      let snapshots = sweepSnapshots.value
      return snapshots.isEmpty ? [] : snapshots[min(index, snapshots.count - 1)]
    }
    let number = log.mutate { state -> Int in
      state.probes += 1
      return state.probes
    }
    return probe.value(number)
  }

  func kill(_ pid: Int32) {
    log.mutate { $0.killed.append(pid) }
    trace.append("kill \(pid)")
  }
}

// MARK: - Fake LaunchServices

final class FakeLaunchServices: LaunchServicesRegistering, @unchecked Sendable {
  let trace: LaunchTrace
  let failure = Locked<(any Error)?>(nil)
  private let urls = Locked<[String]>([])
  init(trace: LaunchTrace) { self.trace = trace }
  var registered: [String] { urls.value }
  func register(appAt url: URL) throws {
    urls.mutate { $0.append(url.path) }
    trace.append("register")
    if let failure = failure.value { throw failure }
  }
}

// MARK: - Fake sleep

/// Poll-interval sleeps return after a yield. The exit-grace sleep (the one whose duration equals `exitGrace`)
/// suspends until cancelled, unless `graceElapses`, in which case it returns at once. Keep the two durations
/// distinct.
final class FakeSleeper: @unchecked Sendable {
  let graceElapses: Bool
  private let recorded = Locked<[Duration]>([])
  init(graceElapses: Bool = false) { self.graceElapses = graceElapses }
  var durations: [Duration] { recorded.value }

  func timing(
    startupTimeout: Duration = .seconds(1_000_000_000), pollInterval: Duration = .seconds(1),
    exitGrace: Duration = .seconds(15)
  ) -> LaunchTiming {
    LaunchTiming(
      startupTimeout: startupTimeout, pollInterval: pollInterval, exitGrace: exitGrace,
      sleep: { [self] duration in
        recorded.mutate { $0.append(duration) }
        try Task.checkCancellation()
        if duration == exitGrace {
          if graceElapses {
            await Task.yield()
            return
          }
          while true { try await Task.sleep(for: .milliseconds(2)) }
        }
        await Task.yield()
      })
  }

  /// The production defaults (120 s startup timeout, 1 s poll, 15 s grace) with this sleeper.
  func defaultTiming() -> LaunchTiming {
    let defaults = LaunchTiming()
    return timing(
      startupTimeout: defaults.startupTimeout, pollInterval: defaults.pollInterval, exitGrace: defaults.exitGrace)
  }
}

// MARK: - Fixture

enum LaunchBytes {
  static let shim = "FAKE-SHIM-BINARY"
  static let dylib = "FAKE-GAMEHOST-DYLIB"
  static let wine = "FAKE-WINE-LOADER"
  static let host = "FAKE-WINE-HOST"
}

enum LaunchHostState {
  /// `wine` is the stock loader and `wine-host` exists too (what the install fixtures ship).
  case normal
  /// `wine` is the stock loader, `wine-host` is missing: the first run renames it.
  case freshNoHost
  /// `wine` is already the shim and `wine-host` is missing: must degrade, never rename the shim.
  case shimInstalledNoHost
}

struct LaunchFixtureOptions {
  var rootName = "data"
  var helpers = false
  var hostState = LaunchHostState.normal
  var game = FakeGameBehavior.exit(0)
  /// `false`: the startup probe never sees the game.
  var gameAppears = true
  var graceElapses = false
  /// `true`: 120 s startup timeout / 1 s poll / 15 s grace (the production defaults).
  var productionTiming = false
}

struct LaunchFixture {
  var directory: URL
  var layout: WineLayout
  var runner: FakeProcessRunner
  var table: FakeProcessTable
  var services: FakeLaunchServices
  var sleeper: FakeSleeper
  var trace: LaunchTrace
  var helpers: GameHostHelpers?
  var timing: LaunchTiming

  var session: GameSession { makeSession() }

  func makeSession(helpers: GameHostHelpers?? = nil, timing: LaunchTiming? = nil) -> GameSession {
    GameSession(
      layout: layout, runner: runner, processes: table, launchServices: services,
      helpers: helpers ?? self.helpers, timing: timing ?? self.timing)
  }

  // Paths

  var macOSWine: URL { layout.gameHostApp.appending(path: "Contents/MacOS/wine") }
  var macOSDotWineHost: URL { layout.gameHostApp.appending(path: "Contents/MacOS/.wine-host") }
  var infoPlist: URL { layout.gameHostApp.appending(path: "Contents/Info.plist") }

  /// `/tmp/.wine-<uid>/server-<dev hex>-<inode hex>` for this prefix, exactly as the sweep must derive it.
  var serverDirectory: String {
    var info = stat()
    _ = stat(layout.prefixDirectory.path, &info)
    return "/tmp/.wine-\(getuid())/server-\(String(UInt32(bitPattern: info.st_dev), radix: 16))-\(String(info.st_ino, radix: 16))"
  }

  /// An orphan the sweep must kill: it holds the server socket of this prefix open.
  func serverOrphan(pid: Int32 = 9001) -> ProcessRecord {
    ProcessRecord(
      pid: pid, arguments: ["wineserver"], workingDirectory: "/", openPaths: [serverDirectory + "/socket"])
  }

  var gameLogs: [String] {
    ((try? FileManager.default.contentsOfDirectory(atPath: layout.logsDirectory.path)) ?? [])
      .filter { $0.hasPrefix("game_") && $0.hasSuffix(".log") }.sorted()
  }

  /// A file below the game directory (created lazily by tests).
  func gameFile(_ relative: String) -> URL {
    directory.appending(path: "game", directoryHint: .isDirectory).appending(path: relative)
  }

  func protonExtra(_ name: String) -> URL {
    directory.appending(path: "protonextras", directoryHint: .isDirectory).appending(path: name)
  }

  /// Asserts nothing of a launch is left behind.
  func expectNoLaunchResidue(sourceLocation: SourceLocation = #_sourceLocation) {
    #expect(!FileManager.default.fileExists(atPath: layout.launchJournal.path), sourceLocation: sourceLocation)
    #expect(!FileManager.default.fileExists(atPath: layout.configBatch.path), sourceLocation: sourceLocation)
  }
}

func withLaunchFixture<T>(
  _ options: LaunchFixtureOptions = .init(), _ body: (LaunchFixture) async throws -> T
) async throws -> T {
  try await withWineTempDirectory { dir in
    let root = dir.appending(path: options.rootName, directoryHint: .isDirectory)
    let layout = WineLayout(root: root)
    try launchWrite("LOADER", to: layout.runtimeDirectory.appending(path: "bin/wine"))
    try launchWrite("SERVER", to: layout.wineserver)
    switch options.hostState {
    case .normal:
      try launchWrite(LaunchBytes.wine, to: layout.unixWine)
      try launchWrite(LaunchBytes.host, to: layout.unixWineHost)
    case .freshNoHost:
      try launchWrite(LaunchBytes.wine, to: layout.unixWine)
    case .shimInstalledNoHost:
      try launchWrite(LaunchBytes.shim, to: layout.unixWine)
    }
    try FileManager.default.createDirectory(at: layout.prefixSystem32, withIntermediateDirectories: true)

    var helpers: GameHostHelpers?
    if options.helpers {
      let shim = dir.appending(path: "helpers/yaagl-wine-shim")
      let dylib = dir.appending(path: "helpers/yaagl-gamehost.dylib")
      try launchWrite(LaunchBytes.shim, to: shim)
      try launchWrite(LaunchBytes.dylib, to: dylib)
      helpers = GameHostHelpers(shim: shim, dylib: dylib)
    }

    let trace = LaunchTrace()
    let runner = FakeProcessRunner(layout: layout, trace: trace)
    runner.game.value = options.game
    let table = FakeProcessTable(trace: trace)
    if !options.gameAppears { table.probe.value = { _ in [] } }
    let sleeper = FakeSleeper(graceElapses: options.graceElapses)
    let fixture = LaunchFixture(
      directory: dir, layout: layout, runner: runner, table: table,
      services: FakeLaunchServices(trace: trace), sleeper: sleeper, trace: trace, helpers: helpers,
      timing: options.productionTiming ? sleeper.defaultTiming() : sleeper.timing())
    return try await body(fixture)
  }
}

/// A recipe with sensible defaults; tests override what they exercise.
func makeLaunchRecipe(
  environment: [String: String] = [:], registry: [RegistryEdit] = [], moveAside: [URL] = [],
  prefixCopies: [PrefixCopy] = [], batchScript: String = "@echo off\necho test-script\n"
) -> LaunchRecipe {
  LaunchRecipe(
    environment: environment, registry: registry, moveAside: moveAside, prefixCopies: prefixCopies,
    batchScript: batchScript, gameExecutableName: "YuanShen.exe", gameDisplayName: "原神")
}

/// Starts `body` on a task, waits (bounded) until the game run has been entered, returns the task.
func waitUntilGameRuns(_ runner: FakeProcessRunner, timeout: Duration = .seconds(5)) async -> Bool {
  let deadline = ContinuousClock.now + timeout
  while runner.gameCalls.isEmpty {
    if ContinuousClock.now > deadline { return false }
    try? await Task.sleep(for: .milliseconds(1))
  }
  return true
}
