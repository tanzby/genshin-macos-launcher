import Foundation
import Launcher
import Sophon
import Testing
import TestSupport
import Wine

@testable import GenshinCN

// GenshinCNClient.launch, the LaunchOptions mapping and the error mapping. Rule IDs refer to docs/parity/hk4e-cn.md.

private let noop: @Sendable () -> Void = {}

@Suite struct ClientLaunchTests {
  @Test func APP_019_recoverIsHandedToTheGameSession() async {
    let rig = ClientRig(distinctBackendLaunchers: true)

    await rig.client.recover(backend: .gptk4)
    await rig.client.recover(backend: .dxmt)

    #expect(rig.launcher.recoveries.withLock { $0 } == 1)
    #expect(rig.dxmtLauncher.recoveries.withLock { $0 } == 1)
  }

  @Test func WIN_022_commandPromptGetsTheLaunchEnvironmentAndTheGameDirectory() async throws {
    let rig = installedRig()

    await rig.client.openWineCommandPrompt(LaunchOptions(gameDirectory: rig.game, metalHUD: true))

    let prompt = try #require(rig.launcher.prompts.withLock { $0 }.first)
    #expect(prompt.gameDirectory == rig.game)
    #expect(prompt.recipe.environment["MTL_HUD_ENABLED"] == "1")
    #expect(prompt.recipe.environment["DXMT_LOG_PATH"] == nil)
    #expect(rig.launcher.recipes.isEmpty, "opening a prompt must not launch the game")
  }

  private func installedRig() -> ClientRig {
    let rig = ClientRig()
    rig.install("5.6.0")
    return rig
  }

  private func installedRig(distinctBackendLaunchers: Bool) -> ClientRig {
    let rig = ClientRig(distinctBackendLaunchers: distinctBackendLaunchers)
    rig.install("5.6.0")
    return rig
  }

  @Test func LCH_010_launchHandsTheRecipeOfTheGameDirectoryToTheSession() async throws {
    let rig = installedRig()

    let outcome = try await rig.client.launch(LaunchOptions(gameDirectory: rig.game), onStarted: noop)

    #expect(outcome == .exited)
    let recipe = try #require(rig.launcher.recipes.first)
    #expect(recipe.gameExecutableName == "YuanShen.exe")
    #expect(recipe.command.last?.contains(rig.game.path.replacingOccurrences(of: "/", with: "\\")) == true)
    #expect(recipe.environment["DXMT_LOG_PATH"] == nil)
    #expect(recipe.prefixCopies.allSatisfy { $0.source.path.hasPrefix(rig.protonExtras.path) })
  }

  @Test func GPTK4_isTheDefaultLaunchBackendAndDXMTRequiresAnExplicitSelection() async throws {
    let rig = installedRig(distinctBackendLaunchers: true)

    _ = try await rig.client.launch(LaunchOptions(gameDirectory: rig.game), onStarted: noop)
    _ = try await rig.client.launch(
      LaunchOptions(gameDirectory: rig.game, graphicsBackend: .dxmt), onStarted: noop)

    let gptkRecipe = try #require(rig.launcher.recipes.first)
    let dxmtRecipe = try #require(rig.dxmtLauncher.recipes.first)
    #expect(rig.launcher.recipes.count == 1)
    #expect(rig.dxmtLauncher.recipes.count == 1)
    #expect(gptkRecipe.environment["DXMT_CONFIG"] == nil)
    #expect(dxmtRecipe.environment["DXMT_CONFIG"] == "d3d11.preferredMaxFrameRate=60;")
  }

  @Test func LCH_032_steamPatchTimeoutFixAndGameModeAreOnWhateverTheOptionsAre() async throws {
    let rig = installedRig()

    _ = try await rig.client.launch(LaunchOptions(gameDirectory: rig.game), onStarted: noop)
    _ = try await rig.client.launch(
      LaunchOptions(gameDirectory: rig.game, retina: true, hdr: true, metalFX: true), onStarted: noop)

    for recipe in rig.launcher.recipes {
      #expect(recipe.environment["WINE_ENABLE_TIMEOUT_FIX"] == "1")
      #expect(recipe.command.first == #"C:\windows\system32\steam.exe"#)
      #expect(recipe.prefixCopies.count == 4)
      #expect(recipe.moveAside.count == 3)
    }
  }

  @Test func LCH_004_everySettingReachesTheRecipe() async throws {
    let rig = installedRig()
    let options = LaunchOptions(
      gameDirectory: rig.game, retina: true, leftCommandIsControl: true, metalHUD: true, hdr: true,
      metalFX: false, customResolution: .init(width: 1920, height: 1080), proxyHost: "127.0.0.1:7890")

    _ = try await rig.client.launch(options, onStarted: noop)

    let recipe = try #require(rig.launcher.recipes.first)
    #expect(recipe.environment["MTL_HUD_ENABLED"] == "1")
    #expect(recipe.environment["HTTP_PROXY"] == "127.0.0.1:7890")
    #expect(recipe.registry.contains { $0.name == "RetinaMode" && $0.action == .set(.string("y")) })
    #expect(recipe.registry.contains { $0.name == "LeftCommandIsCtrl" && $0.action == .set(.string("y")) })
    #expect(recipe.registry.contains { $0.name.hasPrefix("Screenmanager Resolution Width") && $0.action == .set(.dword(1920)) })
    #expect(recipe.registry.contains { $0.name == "WINDOWS_HDR_ON_h3132281285" && $0.action == .set(.dword(1)) })
  }

  @Test func REP_005_aRepairNeedsNoMarkerResetBecauseEveryLaunchPreparesTheGameAgain() async throws {
    let rig = installedRig()

    _ = try await rig.client.launch(.init(gameDirectory: rig.game), onStarted: noop)
    _ = try await rig.client.launch(.init(gameDirectory: rig.game), onStarted: noop)

    #expect(rig.launcher.recipes.count == 2)
    for recipe in rig.launcher.recipes {
      #expect(recipe.moveAside.count == 3)
      #expect(recipe.prefixCopies.count == 4)
    }
  }

  @Test func LCH_011_aGameDirectoryWithAQuoteIsRefusedBeforeAnythingRuns() async throws {
    let rig = installedRig()
    let bad = rig.root.appending(path: "Bad \"Dir\"", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: bad, withIntermediateDirectories: true)

    let outcome = try await rig.client.launch(LaunchOptions(gameDirectory: bad), onStarted: noop)

    #expect(outcome == .failedToLaunch)
    #expect(rig.launcher.recipes.isEmpty)
  }

  @Test func LCH_001_aDirectoryWithoutTheGameIsRefusedBeforeAnythingRuns() async throws {
    let rig = ClientRig()

    let outcome = try await rig.client.launch(LaunchOptions(gameDirectory: rig.game), onStarted: noop)

    #expect(outcome == .failedToLaunch)
    #expect(rig.launcher.recipes.isEmpty)
  }

  @Test func LCH_038_theSessionsResultsBecomeLaunchOutcomes() async throws {
    let rig = installedRig()
    let log = URL(filePath: "/tmp/game_1.log")

    rig.launcher.script(.result(.failedExit(code: 3, log: log)))
    #expect(try await rig.client.launch(.init(gameDirectory: rig.game), onStarted: noop) == .failedExit(code: 3, logPath: log))

    rig.launcher.script(.result(.startupTimedOut))
    #expect(try await rig.client.launch(.init(gameDirectory: rig.game), onStarted: noop) == .startupTimedOut)

    rig.launcher.script(.result(.failedToLaunch(reason: "reg add failed")))
    #expect(try await rig.client.launch(.init(gameDirectory: rig.game), onStarted: noop) == .failedToLaunch)
  }

  @Test func LCH_036_onStartedIsForwardedFromTheSession() async throws {
    let rig = installedRig()
    rig.launcher.script(.runUntilCancelled)
    let calls = Counter()

    let task = Task { try await rig.client.launch(.init(gameDirectory: rig.game), onStarted: { calls.increment() }) }
    #expect(await pollUntil { rig.launcher.started.withLock { $0 } > 0 })
    task.cancel()
    _ = await task.result

    #expect(calls.value == 1)
  }

  @Test func LCH_039_cancellingALaunchWaitsForTheSessionCleanupAndThenThrowsCancelled() async throws {
    let rig = installedRig()
    rig.launcher.script(.runUntilCancelled)

    let task = Task { try await rig.client.launch(.init(gameDirectory: rig.game), onStarted: noop) }
    #expect(await pollUntil { rig.launcher.started.withLock { $0 } > 0 })
    task.cancel()
    let result = await task.result

    // The session finished its restore before launch returned.
    #expect(rig.launcher.cleanupFinished)
    #expect(throws: CancellationError.self) { try result.get() }
  }
}

final class Counter: @unchecked Sendable {
  private let lock = NSLock()
  private var count = 0
  func increment() { lock.withLock { count += 1 } }
  var value: Int { lock.withLock { count } }
}

@Suite struct ClientErrorMappingTests {
  @Test func INS_005_theTemporaryFolderOfTheSophonGameIsTheOneTheLauncherRecordsItsJobIn() {
    #expect(GenshinCN.sophonGame.tempDirectoryName == ".genshin-launcher-tmp")
    #expect(GenshinCN.sophonGame.executableName == GenshinCN.executableName)
    let endpoints = GenshinCN.sophonGame.endpoints
    #expect(endpoints.hypConnectBase.absoluteString == "https://hyp-api.mihoyo.com/hyp/hyp-connect/api")
    #expect(endpoints.downloaderBase.absoluteString == "https://api-takumi.mihoyo.com/downloader/sophon_chunk/api")
    #expect(endpoints.gameID == "1Z8W5NHUQb" && endpoints.launcherID == "jGHBHlcOq1")
  }

  @Test func APP_013_networkProblemsBecomeNetworkErrors() {
    #expect(GenshinCNClient.map(SophonError.transport(code: -1009)) as? GameClientError == .network)
    #expect(GenshinCNClient.map(SophonError.http(status: 503)) as? GameClientError == .network)
    #expect(GenshinCNClient.map(URLError(.timedOut)) as? GameClientError == .network)
  }

  @Test func INS_008_corruptDataBecomesAVerificationFailure() {
    #expect(GenshinCNClient.map(SophonError.checksumMismatch(path: "a")) as? GameClientError == .verificationFailed)
    #expect(GenshinCNClient.map(SophonError.verificationFailed(path: "a")) as? GameClientError == .verificationFailed)
  }

  @Test func INS_004_aFullDiskBecomesInsufficientDiskSpace() {
    #expect(GenshinCNClient.map(CocoaError(.fileWriteOutOfSpace)) as? GameClientError == .insufficientDiskSpace)
    #expect(GenshinCNClient.map(POSIXError(.ENOSPC)) as? GameClientError == .insufficientDiskSpace)
  }

  @Test func APP_013_cancellationStaysCancellationAndOtherErrorsPassThrough() {
    #expect(GenshinCNClient.map(CancellationError()) is CancellationError)
    #expect(GenshinCNClient.map(URLError(.cancelled)) is CancellationError)
    #expect(GenshinCNClient.map(SophonError.installDirectoryNotEmpty) as? GameClientError == .installDirectoryNotEmpty)
    #expect(GenshinCNClient.map(SophonError.noUpdate) as? SophonError == .noUpdate)
  }
}

@Suite struct BundledHelpersTests {
  @Test func LCH_022_theHelpersAreFoundInContentsHelpersAndMissingOnesMeanNoGameMode() throws {
    let app = temporaryURL("Fake").appendingPathExtension("app")
    let helpers = app.appending(path: "Contents/Helpers")
    try FileManager.default.createDirectory(at: helpers, withIntermediateDirectories: true)

    #expect(GenshinCNClient.helpers(in: app) == nil)
    try Data("shim".utf8).write(to: helpers.appending(path: "genshin-launcher-wine-shim"))
    #expect(GenshinCNClient.helpers(in: app) == nil)
    try Data("dylib".utf8).write(to: helpers.appending(path: "genshin-launcher-gamehost.dylib"))
    let found = GameHostHelpers(
      shim: helpers.appending(path: "genshin-launcher-wine-shim"), dylib: helpers.appending(path: "genshin-launcher-gamehost.dylib"))
    #expect(GenshinCNClient.helpers(in: app) == found)

    let icon = app.appending(path: "Contents/Resources/AppIcon.icns")
    try FileManager.default.createDirectory(at: icon.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data("icns".utf8).write(to: icon)
    #expect(GenshinCNClient.helpers(in: app)?.icon == icon)
  }
}
