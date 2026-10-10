import Foundation
import Launcher
import Sophon
import Testing
import Wine

@testable import GenshinCN

// GenshinCNClient.launch, the LaunchOptions mapping and the error mapping. Rule IDs refer to docs/parity/hk4e-cn.md.

private let noop: @Sendable () -> Void = {}

@Suite struct ClientLaunchTests {
  private func installedRig() -> ClientRig {
    let release = FakeRelease.game("5.6.0")
    let rig = ClientRig(main: release)
    rig.install(release)
    return rig
  }

  @Test func LCH_010_launchHandsTheRecipeOfTheGameDirectoryToTheSession() async throws {
    let rig = installedRig()

    let outcome = try await rig.client.launch(LaunchOptions(gameDirectory: rig.game), onStarted: noop)

    #expect(outcome == .exited)
    let recipe = try #require(rig.launcher.recipes.first)
    #expect(recipe.gameExecutableName == "YuanShen.exe")
    #expect(recipe.batchScript.contains(rig.game.path.replacingOccurrences(of: "/", with: "\\")))
    #expect(recipe.environment["DXMT_LOG_PATH"] == rig.data.path)
    #expect(recipe.prefixCopies.allSatisfy { $0.source.path.hasPrefix(rig.protonExtras.path) })
  }

  @Test func LCH_032_steamPatchTimeoutFixAndGameModeAreOnWhateverTheOptionsAre() async throws {
    let rig = installedRig()

    _ = try await rig.client.launch(LaunchOptions(gameDirectory: rig.game), onStarted: noop)
    _ = try await rig.client.launch(
      LaunchOptions(gameDirectory: rig.game, retina: true, hdr: true, metalFX: true), onStarted: noop)

    for recipe in rig.launcher.recipes {
      #expect(recipe.environment["WINE_ENABLE_TIMEOUT_FIX"] == "1")
      #expect(recipe.batchScript.contains("-platform_type CLOUD_THIRD_PARTY_PC -is_cloud 1"))
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

  @Test func LCH_011_aGameDirectoryWithAQuoteIsRefusedBeforeAnythingRuns() async throws {
    let rig = installedRig()
    let bad = rig.root.appending(path: "Bad \"Dir\"", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: bad, withIntermediateDirectories: true)

    let outcome = try await rig.client.launch(LaunchOptions(gameDirectory: bad), onStarted: noop)

    #expect(outcome == .failedToLaunch)
    #expect(rig.launcher.recipes.isEmpty)
  }

  @Test func LCH_001_aDirectoryWithoutTheGameIsRefusedBeforeAnythingRuns() async throws {
    let rig = ClientRig(main: .game("5.6.0"))

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
    #expect(try await rig.client.launch(.init(gameDirectory: rig.game), onStarted: noop) == .failedToLaunch)

    rig.launcher.script(.result(.failedToLaunch(reason: "reg add failed")))
    #expect(try await rig.client.launch(.init(gameDirectory: rig.game), onStarted: noop) == .failedToLaunch)
  }

  @Test func LCH_036_onStartedIsForwardedFromTheSession() async throws {
    let rig = installedRig()
    rig.launcher.script(.runUntilCancelled)
    let calls = Counter()

    let task = Task { try await rig.client.launch(.init(gameDirectory: rig.game), onStarted: { calls.increment() }) }
    while rig.launcher.started.withLock({ $0 }) == 0 { try await Task.sleep(for: .milliseconds(2)) }
    task.cancel()
    _ = await task.result

    #expect(calls.value == 1)
  }

  @Test func LCH_039_cancellingALaunchWaitsForTheSessionCleanupAndThenThrowsCancelled() async throws {
    let rig = installedRig()
    rig.launcher.script(.runUntilCancelled)

    let task = Task { try await rig.client.launch(.init(gameDirectory: rig.game), onStarted: noop) }
    while rig.launcher.started.withLock({ $0 }) == 0 { try await Task.sleep(for: .milliseconds(2)) }
    task.cancel()
    let result = await task.result

    // The session finished its restore before launch returned.
    #expect(rig.launcher.cleanupFinished)
    #expect(throws: CancellationError.self) { try result.get() }
  }

  @Test func LCH_014_aMovedAsideFileWithoutAJournalIsBroughtBackBeforeTheLaunch() async throws {
    let rig = installedRig()
    let crash = "YuanShen_Data/upload_crash.exe"
    try FileManager.default.moveItem(at: rig.url(crash), to: rig.url(crash + ".bak"))
    rig.launcher.watchedFiles.withLock { $0 = [rig.url(crash)] }

    _ = try await rig.client.launch(.init(gameDirectory: rig.game), onStarted: noop)

    #expect(rig.launcher.filesAtLaunch["upload_crash.exe"] == true)
    #expect(!rig.exists(crash + ".bak"))
  }
}

final class Counter: @unchecked Sendable {
  private let lock = NSLock()
  private var count = 0
  func increment() { lock.withLock { count += 1 } }
  var value: Int { lock.withLock { count } }
}

@Suite struct LaunchSettingsMappingTests {
  @Test func LCH_004_launchOptionsMapOneToOneOntoTheRecipeSettings() {
    let options = LaunchOptions(
      gameDirectory: URL(filePath: "/Games/GI"), retina: true, leftCommandIsControl: true, metalHUD: true, hdr: true,
      metalFX: true, customResolution: .init(width: 2560, height: 1440), proxyHost: "localhost:8080")

    let settings = GenshinLaunchSettings(options)

    #expect(
      settings
        == GenshinLaunchSettings(
          retina: true, leftCommandIsControl: true, metalHUD: true, hdr: true, metalFX: true,
          customResolution: .init(width: 2560, height: 1440), proxyHost: "localhost:8080"))
    #expect(GenshinLaunchSettings(LaunchOptions(gameDirectory: URL(filePath: "/g"))) == GenshinLaunchSettings())
  }
}

@Suite struct ClientErrorMappingTests {
  @Test func APP_013_networkProblemsBecomeNetworkErrors() {
    #expect(GenshinCNClient.map(SophonError.transport(code: -1009)) as? GameClientError == .network)
    #expect(GenshinCNClient.map(SophonError.http(status: 503)) as? GameClientError == .network)
    #expect(GenshinCNClient.map(URLError(.timedOut)) as? GameClientError == .network)
  }

  @Test func INS_012_onlyTransportFailuresAndServerErrorsCountAsOffline() {
    #expect(GenshinCNClient.isOffline(SophonError.transport(code: -1009)))
    #expect(GenshinCNClient.isOffline(SophonError.http(status: 502)))
    #expect(!GenshinCNClient.isOffline(SophonError.http(status: 403)))
    #expect(!GenshinCNClient.isOffline(SophonError.malformedResponse))
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
    #expect(GenshinCNClient.map(SophonError.installDirectoryNotEmpty) as? SophonError == .installDirectoryNotEmpty)
    #expect(GenshinCNClient.map(GenshinCNClientError.noUpdate) as? GenshinCNClientError == .noUpdate)
  }
}

@Suite struct JobSerializerTests {
  @Test func ADR0002_aNewJobStartsOnlyAfterTheCancelledOneHasReallyStopped() async throws {
    let serializer = JobSerializer()
    let log = Log()
    let first = serializer.enqueue {
      await log.add("first:start")
      // Stops late, like a download worker finishing its file.
      while !Task.isCancelled { try? await Task.sleep(for: .milliseconds(2)) }
      try? await Task.sleep(for: .milliseconds(60))
      await log.add("first:stopped")
    }
    try await Task.sleep(for: .milliseconds(20))
    first.cancel()
    let second = serializer.enqueue { await log.add("second:start") }

    await second.value

    #expect(await log.entries == ["first:start", "first:stopped", "second:start"])
  }
}

actor Log {
  private(set) var entries: [String] = []
  func add(_ entry: String) { entries.append(entry) }
}

@Suite struct BundledHelpersTests {
  @Test func LCH_022_theHelpersAreFoundInContentsHelpersAndMissingOnesMeanNoGameMode() throws {
    let app = FileManager.default.temporaryDirectory.appending(path: "Fake-\(UUID().uuidString).app")
    let helpers = app.appending(path: "Contents/Helpers")
    try FileManager.default.createDirectory(at: helpers, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: app) }

    #expect(GenshinCNClient.helpers(in: app) == nil)
    try Data("shim".utf8).write(to: helpers.appending(path: "yaagl-wine-shim"))
    #expect(GenshinCNClient.helpers(in: app) == nil)
    try Data("dylib".utf8).write(to: helpers.appending(path: "yaagl-gamehost"))
    #expect(
      GenshinCNClient.helpers(in: app)
        == GameHostHelpers(shim: helpers.appending(path: "yaagl-wine-shim"), dylib: helpers.appending(path: "yaagl-gamehost")))
  }
}
