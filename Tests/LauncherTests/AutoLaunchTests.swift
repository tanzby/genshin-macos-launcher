import Foundation
import Platform
import Testing
import TestSupport
import Wine

@testable import Launcher

// APP-020: command-line auto launch for yaagl-diag. The driver talks to the real `LauncherModel` with the
// Fake client and Fake Wine; what it must produce is a verdict line in `logs/launcher.log`.

@MainActor
private final class Harness {
  let wine: FakeWinePreparer
  let fake: FakeGameClient
  let model: LauncherModel
  let logs: URL
  let log: DiagLog

  init(wine wineStatus: WineStatus = .ready, game: GameStatus = GameStatus(localVersion: "5.0.0", remoteVersion: "5.0.0")) {
    wine = FakeWinePreparer(status: wineStatus)
    fake = FakeGameClient(status: game)
    let directory = temporaryURL("AutoLaunchTests")
    logs = directory.appending(path: "logs")
    log = DiagLog(logsDirectory: logs)
    model = LauncherModel(client: fake, wine: wine, gameDirectory: directory, chunkTempMargin: 0)
  }

  var lines: [String] {
    ((try? String(contentsOf: log.file, encoding: .utf8)) ?? "").split(separator: "\n").map { String($0.dropFirst(21)) }
  }

  /// The phase watcher logs asynchronously; wait for its line instead of assuming it already ran.
  func waitForLine(_ line: String) async -> Bool {
    await pollUntil { lines.contains(line) }
  }

  func autoLaunch(allowDownload: Bool = true) -> AutoLaunch {
    AutoLaunch(
      model: model, log: log, pollInterval: .milliseconds(5), progressInterval: .milliseconds(5), allowDownload: allowDownload)
  }
}

@MainActor @Suite struct APP_020_AutoLaunchTests {
  @Test func APP_020_aDataDirectoryThatCannotBePreparedLeavesAFailedVerdictAndAnExitLine() {
    let harness = Harness()
    AutoLaunch.reportPrepareFailure(DataDirectory.PrepareError.unsupportedSchemaVersion(9), to: harness.log)
    #expect(harness.lines.count == 2)
    #expect(harness.lines.first?.hasPrefix("autolaunch: result=failed reason=data-dir") == true)
    #expect(harness.lines.last == "autolaunch: exit")
  }

  @Test func APP_020_parsesFlagsAndEnvironment() {
    let flags = AutoLaunchOptions.parse(
      arguments: ["App", "--autolaunch", "--data-dir", "/tmp/data", "--game-dir", "/tmp/game", "--allow-download"], environment: [:])
    #expect(flags.enabled)
    #expect(flags.allowDownload)
    #expect(flags.dataRoot?.path == "/tmp/data")
    #expect(flags.gameDirectory?.path == "/tmp/game")

    let env = AutoLaunchOptions.parse(
      arguments: ["App"], environment: ["YAAGL_AUTOLAUNCH": "1", "YAAGL_DATA_DIR": "/tmp/env"])
    #expect(env.enabled)
    #expect(env.dataRoot?.path == "/tmp/env")
    #expect(env.gameDirectory == nil)

    #expect(AutoLaunchOptions.parse(arguments: ["App"], environment: [:]) == AutoLaunchOptions())
    // A trailing flag without a value is ignored, not a crash.
    #expect(AutoLaunchOptions.parse(arguments: ["App", "--data-dir"], environment: [:]).dataRoot == nil)
  }

  @Test func APP_020_overriddenDataRootLeavesTheRealLeftoversAlone() throws {
    let base = temporaryURL("AutoLaunchData")
    let root = base.appending(path: "data")
    try FileManager.default.createDirectory(at: root.appending(path: "wineprefix"), withIntermediateDirectories: true)
    let directory = try AutoLaunchOptions(enabled: true, dataRoot: root).prepareDataDirectory()
    #expect(directory.root == root)
    #expect(FileManager.default.fileExists(atPath: directory.nativeMarker.path))
    #expect(!FileManager.default.fileExists(atPath: directory.winePrefix.path))
  }

  @Test func APP_020_entryPointPreparesTheDataRootAppliesTheGameDirectoryAndQuits() async throws {
    let h = Harness(wine: .needsInstall(.notInstalled))
    let root = h.logs.deletingLastPathComponent().appending(path: "data")
    let game = h.logs.deletingLastPathComponent().appending(path: "game")
    var terminated = 0
    let wine = h.wine
    let failer = Task {  // the entry point runs a real session; end it with a failed Wine install
      let install = try await wine.nextInstall()
      wine.fail(install: install, throwing: WineInstallError.extractionFailed(tool: "tar", exitCode: 1, output: ""))
    }
    await AutoLaunch.runIfRequested(
      AutoLaunchOptions(enabled: true, dataRoot: root, gameDirectory: game), model: h.model, log: h.log
    ) { terminated += 1 } forceExit: {}
    try await failer.value
    #expect(terminated == 1)
    #expect(h.model.gameDirectory == game)
    #expect(FileManager.default.fileExists(atPath: root.appending(path: DataDirectory.nativeMarkerName).path))
    #expect(h.lines.last == "autolaunch: exit")
  }

  @Test func APP_020_launchesAndReportsOkWhenTheGameExits() async throws {
    let h = Harness()
    let driver = h.autoLaunch()
    let run = Task { @MainActor in await driver.run() }
    try await h.fake.nextLaunch()
    h.fake.fireStarted()
    #expect(await h.waitForLine("autolaunch: phase=running"))
    h.fake.finishLaunch(.exited)
    #expect(await run.value == .ok)
    #expect(h.lines.first == "autolaunch: start")
    #expect(h.lines.last == "autolaunch: result=ok")
  }

  @Test func APP_020_failedLaunchReportsTheReason() async throws {
    let h = Harness()
    let driver = h.autoLaunch()
    let run = Task { @MainActor in await driver.run() }
    try await h.fake.nextLaunch()
    h.fake.fireStarted()
    h.fake.finishLaunch(.failedToLaunch)
    let result = await run.value
    #expect(result == .failed("game failedToLaunch"))
    #expect(h.lines.last == "autolaunch: result=failed reason=game failedToLaunch")
  }

  @Test func APP_020_preparesWineBeforeLaunching() async throws {
    let h = Harness(wine: .needsInstall(.notInstalled))
    let driver = h.autoLaunch()
    let run = Task { @MainActor in await driver.run() }
    let install = try await h.wine.nextInstall()
    #expect(await h.waitForLine("autolaunch: phase=preparingWine"))
    h.wine.finish(install: install)
    try await h.fake.nextLaunch()
    h.fake.fireStarted()
    h.fake.finishLaunch(.exited)
    #expect(await run.value == .ok)
  }

  @Test func APP_020_wineInstallFailureEndsWithAVerdict() async throws {
    let h = Harness(wine: .needsInstall(.notInstalled))
    let driver = h.autoLaunch()
    let run = Task { @MainActor in await driver.run() }
    let install = try await h.wine.nextInstall()
    h.wine.fail(install: install, throwing: WineInstallError.extractionFailed(tool: "tar", exitCode: 1, output: ""))
    let result = await run.value
    guard case .failed(let reason) = result else { Issue.record("expected a failure"); return }
    #expect(reason.hasPrefix("bootstrap "))
    #expect(h.lines.last?.hasPrefix("autolaunch: result=failed") == true)
  }

  @Test func APP_020_withoutAllowDownloadAMissingGameFailsInsteadOfDownloading() async {
    let h = Harness(game: GameStatus(localVersion: nil, remoteVersion: "5.0.0"))
    let result = await h.autoLaunch(allowDownload: false).run()
    #expect(result == .failed("needs install (pass --allow-download)"))
    #expect(h.fake.runs.isEmpty)
  }

  @Test func APP_020_installsAMissingGameFirst() async throws {
    let h = Harness(game: GameStatus(localVersion: nil, remoteVersion: "5.0.0"))
    let driver = h.autoLaunch()
    let run = Task { @MainActor in await driver.run() }
    let index = try await h.fake.nextRun()
    h.fake.setStatus(GameStatus(localVersion: "5.0.0", remoteVersion: "5.0.0"))
    h.fake.finish(run: index)
    try await h.fake.nextLaunch()
    h.fake.fireStarted()
    h.fake.finishLaunch(.exited)
    #expect(await run.value == .ok)
    #expect(h.fake.runs == [.install])
  }
}

@Suite struct RosettaDetectionTests {
  @Test func APP_001_rosettaIsDetectedByItsRuntimeLibraryNotAnExecutableFlag() throws {
    let file = temporaryURL("libRosettaRuntime")
    #expect(!StartupSteps.isRosettaInstalled(at: file))
    try Data("x".utf8).write(to: file)  // not executable, like the real library
    #expect(StartupSteps.isRosettaInstalled(at: file))
  }
}
