import Foundation
import Platform
import Testing

@testable import Wine

// GameSession.launch: order of steps, the game run itself, exit paths, startup watchdog and registry restore.
// Everything runs against fakes (LaunchTestSupport.swift); the legacy behaviour being pinned is in
// docs/research/hk4e-rules.md LCH-001..039 and docs/research/wine-launch-contract.md.

private let wineDebug = "fixme-all,err-unwind,+timestamp"

private func resolutionEdits(width: UInt32 = 2560, height: UInt32 = 1600) -> [RegistryEdit] {
  [
    RegistryEdit(
      key: LaunchRegistry.miHoYoKey, name: LaunchRegistry.fullscreenName, action: .set(.dword(0)),
      restoresOnExit: true),
    LaunchRegistry.widthEdit(width),
    LaunchRegistry.heightEdit(height),
  ]
}

/// The values a player had before the launch.
private func seedOriginalResolution(_ f: LaunchFixture) {
  f.runner.setRegistry(LaunchRegistry.miHoYoKey, LaunchRegistry.fullscreenName, .dword(1))
  f.runner.setRegistry(LaunchRegistry.miHoYoKey, LaunchRegistry.widthName, .dword(1280))
  f.runner.setRegistry(LaunchRegistry.miHoYoKey, LaunchRegistry.heightName, .dword(720))
}

private func seedCrashFiles(_ f: LaunchFixture) throws -> [URL] {
  let urls = [
    f.gameFile("YuanShen_Data/upload_crash.exe"), f.gameFile("YuanShen_Data/Plugins/crashreport.exe"),
    f.gameFile("YuanShen_Data/Plugins/vulkan-1.dll"),
  ]
  for (index, url) in urls.enumerated() { try launchWrite("ORIGINAL-FILE-\(index)", to: url) }
  return urls
}

private func expectFilesBack(_ urls: [URL], sourceLocation: SourceLocation = #_sourceLocation) {
  for (index, url) in urls.enumerated() {
    #expect(launchRead(url) == "ORIGINAL-FILE-\(index)", sourceLocation: sourceLocation)
    #expect(
      !FileManager.default.fileExists(atPath: url.path + ".bak"), sourceLocation: sourceLocation)
  }
}

// MARK: - Order of the steps

@Suite("GameSession launch order", .timeLimit(.minutes(1))) struct GameSessionOrderTests {
  @Test func LCH_001_launchRunsRecoverQueryMutateWaitRunWaitRestoreInThisOrder() async throws {
    try await withLaunchFixture { f in
      f.runner.setRegistry(LaunchRegistry.miHoYoKey, LaunchRegistry.widthName, .dword(1280))
      let recipe = makeLaunchRecipe(registry: [LaunchRegistry.retinaEdit("n"), LaunchRegistry.widthEdit(2560)])

      let result = await f.session.launch(recipe)

      #expect(result == .exited)
      let key = LaunchRegistry.miHoYoKey
      let width = LaunchRegistry.widthName
      // A trailing `wineserver -w` after the restore (letting the registry flush) is tolerated; the contract
      // does not name it, so it is not pinned either way.
      var trace = f.trace.all
      while trace.last == "wineserver -w" { trace.removeLast() }
      #expect(
        trace == [
          "wineserver -k",
          loaderLabel(regQueryArgs(key, width)),
          loaderLabel(regAddStringArgs(LaunchRegistry.macDriverKey, "RetinaMode", "n")),
          loaderLabel(regAddDwordArgs(key, width, 2560)),
          "wineserver -w",
          "GAME",
          "wineserver -w",
          loaderLabel(regAddDwordArgs(key, width, 1280)),
        ])
    }
  }

  @Test func LCH_003_launchStartsWithWineserverKillThenKillsTheOrphansBeforeTouchingTheRegistry() async throws {
    try await withLaunchFixture { f in
      f.table.sweepSnapshots.value = [[f.serverOrphan()]]
      f.runner.setRegistry(LaunchRegistry.miHoYoKey, LaunchRegistry.widthName, .dword(1280))

      let result = await f.session.launch(makeLaunchRecipe(registry: [LaunchRegistry.widthEdit(2560)]))

      #expect(result == .exited)
      #expect(Array(f.trace.all.prefix(2)) == ["wineserver -k", "kill 9001"])
      let firstReg = f.trace.all.firstIndex { $0.hasPrefix("wine reg") }
      #expect(firstReg != nil)
      #expect((firstReg ?? 0) > 1)
    }
  }

  @Test func LCH_009_everyRegistryWriteComesBeforeWineserverWaitWhichComesBeforeTheGameAndConfigBatch() async throws {
    try await withLaunchFixture { f in
      let recipe = makeLaunchRecipe(
        registry: [LaunchRegistry.retinaEdit("y")] + resolutionEdits(), batchScript: "@echo off\nrem LCH-009\n")
      let result = await f.session.launch(recipe)

      #expect(result == .exited)
      let calls = f.runner.calls
      let firstWait = try #require(calls.firstIndex { $0.kind == .wineserverWait })
      let gameIndex = try #require(calls.firstIndex { $0.kind == .game })
      let lastPrepWrite = try #require(
        calls.enumerated().last { $0.element.kind == .regAdd && $0.offset < gameIndex }?.offset)
      #expect(lastPrepWrite < firstWait)
      // the wait is the last thing before the game
      #expect(firstWait + 1 == gameIndex)
      #expect(calls[firstWait].configBatchExisted == false)
      #expect(calls[gameIndex].configBatchExisted == true)
    }
  }

  @Test func LCH_005_registryCallsCarryPrefixDebugEnvironmentAndRunInTheDataDirectory() async throws {
    try await withLaunchFixture { f in
      let result = await f.session.launch(makeLaunchRecipe(registry: [LaunchRegistry.retinaEdit("y")]))

      #expect(result == .exited)
      let add = try #require(f.runner.calls(.regAdd).first)
      #expect(add.arguments == regAddStringArgs(LaunchRegistry.macDriverKey, "RetinaMode", "y"))
      #expect(add.executable == f.layout.loader.path)
      #expect(add.environment == ["WINEPREFIX": f.layout.prefixDirectory.path, "WINEDEBUG": wineDebug])
      #expect(add.workingDirectory == f.layout.root.path)
      for call in f.runner.calls where call.kind == .wineserverKill || call.kind == .wineserverWait {
        #expect(call.environment["WINEPREFIX"] == f.layout.prefixDirectory.path)
      }
    }
  }
}

// MARK: - The game run

@Suite("GameSession game run", .timeLimit(.minutes(1))) struct GameSessionRunTests {
  @Test func LCH_010_gameRunIsOneCmdCallOnConfigBatchWithLogInTheLogsDirectory() async throws {
    try await withLaunchFixture { f in
      let script = "@echo off\r\ncd \"%~dp0\"\r\necho 原神\r\n"
      let result = await f.session.launch(makeLaunchRecipe(environment: ["MARK": "1"], batchScript: script))

      #expect(result == .exited)
      #expect(f.runner.gameCalls.count == 1)
      let game = try #require(f.runner.gameCall)
      #expect(game.executable == f.layout.loader.path)
      #expect(
        game.arguments == ["cmd", "/c", "Z:" + f.layout.configBatch.path.replacingOccurrences(of: "/", with: "\\")])
      #expect(game.workingDirectory == f.layout.root.path)
      #expect(game.environment["WINEPREFIX"] == f.layout.prefixDirectory.path)
      #expect(game.environment["WINEDEBUG"] == wineDebug)
      #expect(game.environment["MARK"] == "1")
      let logFile = try #require(game.logFile)
      #expect(URL(filePath: logFile).deletingLastPathComponent().path == f.layout.logsDirectory.path)
    }
  }

  @Test func LCH_010_configBatchHoldsTheRecipeScriptUtf8WhileTheGameRuns() async throws {
    try await withLaunchFixture { f in
      let script = "@echo off\ncd /d \"Z:\\Games\\原神 GI\"\n"
      let result = await f.session.launch(makeLaunchRecipe(batchScript: script))

      #expect(result == .exited)
      let snapshot = try #require(f.runner.snapshots.first)
      #expect(snapshot.configBatch == script)
    }
  }

  @Test func WIN_017_gameRunPassesConfigBatchAsZDrivePathWithBackslashesEvenForNonAsciiAndSpaces() async throws {
    var options = LaunchFixtureOptions()
    options.rootName = "Yaagl 数据 data"
    try await withLaunchFixture(options) { f in
      let result = await f.session.launch(makeLaunchRecipe())

      #expect(result == .exited)
      let game = try #require(f.runner.gameCall)
      let argument = try #require(game.arguments.last)
      #expect(argument.hasPrefix("Z:\\"))
      #expect(argument.hasSuffix("\\Yaagl 数据 data\\config.bat"))
      #expect(!argument.contains("/"))
      #expect(argument == "Z:" + f.layout.configBatch.path.replacingOccurrences(of: "/", with: "\\"))
    }
  }

  @Test func LCH_035_emptyEnvironmentValuesAreDroppedAndZeroIsKept() async throws {
    try await withLaunchFixture { f in
      let recipe = makeLaunchRecipe(environment: ["KEPT": "1", "ZERO": "0", "WINEDLLOVERRIDES": "", "MTL_HUD_ENABLED": ""])
      let result = await f.session.launch(recipe)

      #expect(result == .exited)
      let game = try #require(f.runner.gameCall)
      #expect(
        game.environment == [
          "WINEPREFIX": f.layout.prefixDirectory.path, "WINEDEBUG": wineDebug, "KEPT": "1", "ZERO": "0",
        ])
    }
  }

  @Test func LCH_039_configBatchIsDeletedAfterANormalExitAndLogsStay() async throws {
    try await withLaunchFixture { f in
      let result = await f.session.launch(makeLaunchRecipe())

      #expect(result == .exited)
      #expect(f.runner.snapshots.first?.configBatch != nil)
      f.expectNoLaunchResidue()
      #expect(f.gameLogs.count == 1)
    }
  }
}

// MARK: - Exit paths

@Suite("GameSession exit paths", .timeLimit(.minutes(1))) struct GameSessionExitTests {
  @Test func LCH_036_exitCodeZeroWaitsForWineserverAndDoesNotKillThePrefix() async throws {
    try await withLaunchFixture { f in
      f.table.sweepSnapshots.value = [[f.serverOrphan()]]
      let result = await f.session.launch(makeLaunchRecipe())

      #expect(result == .exited)
      // the only kill is recover()'s; the orphan is swept there, and no second shutdown follows the game
      #expect(f.runner.killCount == 1)
      #expect(f.table.sweepCount == 1)
      let gameIndex = try #require(f.runner.callIndex(.game))
      let waitAfterGame = f.runner.calls.enumerated().contains { $0.offset > gameIndex && $0.element.kind == .wineserverWait }
      #expect(waitAfterGame)
    }
  }

  @Test func LCH_036_wineserverStillRunningAfterTheGraceKillsThePrefixThenRestores() async throws {
    var options = LaunchFixtureOptions()
    options.graceElapses = true
    try await withLaunchFixture(options) { f in
      f.runner.hangingWaits.value = [2]  // the wait after the game never returns
      f.table.sweepSnapshots.value = [[], [f.serverOrphan()]]
      f.runner.setRegistry(LaunchRegistry.miHoYoKey, LaunchRegistry.widthName, .dword(1280))
      let result = await f.session.launch(makeLaunchRecipe(registry: [LaunchRegistry.widthEdit(2560)]))

      #expect(result == .exited)
      #expect(f.sleeper.durations.contains(.seconds(15)))
      #expect(f.runner.killCount == 2)
      #expect(f.table.killed == [9001])
      let trace = f.trace.all
      let game = try #require(trace.firstIndex(of: "GAME"))
      let kill = try #require(trace.lastIndex(of: "wineserver -k"))
      let sweep = try #require(trace.firstIndex(of: "kill 9001"))
      let restore = try #require(
        trace.lastIndex(of: loaderLabel(regAddDwordArgs(LaunchRegistry.miHoYoKey, LaunchRegistry.widthName, 1280))))
      #expect(game < kill)
      #expect(kill < sweep)
      #expect(sweep < restore)
      #expect(f.runner.registryValue(LaunchRegistry.miHoYoKey, LaunchRegistry.widthName) == .dword(1280))
      f.expectNoLaunchResidue()
    }
  }

  @Test func LCH_038_nonzeroExitReturnsFailedExitWithTheGameLogAndStillRestoresEverything() async throws {
    var options = LaunchFixtureOptions()
    options.game = .exit(3)
    try await withLaunchFixture(options) { f in
      seedOriginalResolution(f)
      let initial = f.runner.registrySnapshot
      let files = try seedCrashFiles(f)

      let result = await f.session.launch(makeLaunchRecipe(registry: resolutionEdits(), moveAside: files))

      guard case .failedExit(let code, let log) = result else {
        Issue.record("expected .failedExit, got \(result)")
        return
      }
      #expect(code == 3)
      #expect(log.path == f.runner.gameCall?.logFile)
      #expect(log.deletingLastPathComponent().path == f.layout.logsDirectory.path)
      #expect(wineExists(log))
      #expect(f.runner.killCount == 1)  // nonzero exit follows the same grace rule, no extra kill
      #expect(f.runner.snapshots.first?.registry[LaunchRegistry.regID(LaunchRegistry.miHoYoKey, LaunchRegistry.widthName)] == .dword(2560))
      #expect(f.runner.registrySnapshot == initial)
      expectFilesBack(files)
      f.expectNoLaunchResidue()
    }
  }

  @Test func LCH_038_errorThrownByTheGameRunReturnsFailedToLaunchAndStillRestores() async throws {
    var options = LaunchFixtureOptions()
    options.game = .fail(FakeFailure(message: "spawn failed"))
    try await withLaunchFixture(options) { f in
      seedOriginalResolution(f)
      let initial = f.runner.registrySnapshot
      let files = try seedCrashFiles(f)

      let result = await f.session.launch(makeLaunchRecipe(registry: resolutionEdits(), moveAside: files))

      #expect(result.isFailedToLaunch)
      #expect(f.runner.gameCalls.count == 1)
      #expect(f.runner.registrySnapshot == initial)
      expectFilesBack(files)
      f.expectNoLaunchResidue()
    }
  }

  @Test func LCH_038_registryErrorDuringPreparationReturnsFailedToLaunchWithoutRunningTheGameAndRestores() async throws {
    try await withLaunchFixture { f in
      seedOriginalResolution(f)
      let initial = f.runner.registrySnapshot
      let files = try seedCrashFiles(f)
      let adds = Locked(0)
      f.runner.responder.value = { call in
        guard call.kind == .regAdd else { return nil }
        if adds.mutate({ (n: inout Int) -> Int in n += 1; return n }) == 2 { throw FakeFailure(message: "reg crashed") }
        return nil
      }

      let result = await f.session.launch(makeLaunchRecipe(registry: resolutionEdits(), moveAside: files))

      #expect(result.isFailedToLaunch)
      #expect(adds.value >= 3)  // the second write threw; the restore still wrote the originals back
      #expect(f.runner.gameCalls.isEmpty)
      #expect(f.runner.registrySnapshot == initial)
      expectFilesBack(files)
      f.expectNoLaunchResidue()
    }
  }

  @Test func LCH_038_registryQueryErrorFailsBeforeAnyMutationAndLeavesNoJournal() async throws {
    try await withLaunchFixture { f in
      seedOriginalResolution(f)
      let initial = f.runner.registrySnapshot
      let files = try seedCrashFiles(f)
      f.runner.responder.value = { call in
        if call.kind == .regQuery { throw FakeFailure(message: "query crashed") }
        return nil
      }

      let result = await f.session.launch(makeLaunchRecipe(registry: resolutionEdits(), moveAside: files))

      #expect(result.isFailedToLaunch)
      #expect(f.runner.calls(.regQuery).count >= 1)
      #expect(f.runner.calls(.regAdd).isEmpty)
      #expect(f.runner.gameCalls.isEmpty)
      #expect(f.runner.registrySnapshot == initial)
      expectFilesBack(files)
      f.expectNoLaunchResidue()
    }
  }

  @Test func LCH_039_cancellingTheCallingTaskMidGameStillRestoresAndReturnsCancelled() async throws {
    var options = LaunchFixtureOptions()
    options.game = .hang
    try await withLaunchFixture(options) { f in
      seedOriginalResolution(f)
      let initial = f.runner.registrySnapshot
      let files = try seedCrashFiles(f)
      f.table.sweepSnapshots.value = [[], [f.serverOrphan()]]
      let session = f.session
      let recipe = makeLaunchRecipe(registry: resolutionEdits(), moveAside: files)

      let task = Task { await session.launch(recipe) }
      let started = await waitUntilGameRuns(f.runner)
      task.cancel()
      let result = await task.value

      #expect(started, "the game run was never entered")
      #expect(result == .cancelled)
      // restore argv were recorded although the calling task was cancelled
      let trace = f.trace.all
      #expect(trace.contains(loaderLabel(regAddDwordArgs(LaunchRegistry.miHoYoKey, LaunchRegistry.widthName, 1280))))
      #expect(trace.contains(loaderLabel(regAddDwordArgs(LaunchRegistry.miHoYoKey, LaunchRegistry.heightName, 720))))
      #expect(trace.contains(loaderLabel(regAddDwordArgs(LaunchRegistry.miHoYoKey, LaunchRegistry.fullscreenName, 1))))
      // cancellation shuts the prefix down at once, before the restore
      #expect(f.runner.killCount == 2)
      #expect(f.table.killed == [9001])
      #expect(f.runner.registrySnapshot == initial)
      expectFilesBack(files)
      f.expectNoLaunchResidue()
    }
  }

  @Test func LCH_039_cancellationRestoresRegistryValuesThatDidNotExistWithRegDelete() async throws {
    var options = LaunchFixtureOptions()
    options.game = .hang
    try await withLaunchFixture(options) { f in
      let session = f.session
      let recipe = makeLaunchRecipe(registry: [LaunchRegistry.widthEdit(2560)])

      let task = Task { await session.launch(recipe) }
      let started = await waitUntilGameRuns(f.runner)
      task.cancel()
      let result = await task.value

      #expect(started, "the game run was never entered")
      #expect(result == .cancelled)
      #expect(f.trace.all.contains(loaderLabel(regDeleteArgs(LaunchRegistry.miHoYoKey, LaunchRegistry.widthName))))
      #expect(f.runner.registryValue(LaunchRegistry.miHoYoKey, LaunchRegistry.widthName) == nil)
    }
  }
}

// MARK: - Startup watchdog

@Suite("GameSession startup watchdog", .timeLimit(.minutes(1))) struct GameSessionWatchdogTests {
  @Test func LCH_036_noGameProcessWithin120SecondsKillsThePrefixRestoresAndReturnsStartupTimedOut() async throws {
    var options = LaunchFixtureOptions()
    options.game = .hang
    options.gameAppears = false
    options.productionTiming = true
    try await withLaunchFixture(options) { f in
      seedOriginalResolution(f)
      let initial = f.runner.registrySnapshot
      let files = try seedCrashFiles(f)
      f.table.sweepSnapshots.value = [[], [f.serverOrphan()]]

      let result = await f.session.launch(makeLaunchRecipe(registry: resolutionEdits(), moveAside: files))

      #expect(result == .startupTimedOut)
      // one poll per simulated second, 120 simulated seconds
      #expect((118...122).contains(f.table.probeCount))
      #expect(f.sleeper.durations.filter { $0 == .seconds(1) }.count >= 118)
      #expect(f.runner.killCount == 2)
      #expect(f.table.killed == [9001])
      let trace = f.trace.all
      let game = try #require(trace.firstIndex(of: "GAME"))
      let sweep = try #require(trace.firstIndex(of: "kill 9001"))
      #expect(game < sweep)
      #expect(f.runner.registrySnapshot == initial)
      expectFilesBack(files)
      f.expectNoLaunchResidue()
    }
  }

  @Test func LCH_036_aGameProcessSeenByThePollStopsTheWatchdog() async throws {
    try await withLaunchFixture { f in
      f.table.probe.value = { number in number >= 3 ? [FakeProcessTable.gameRecord] : [] }
      let table = f.table
      f.runner.game.value = .custom { _ in
        let deadline = ContinuousClock.now + .seconds(5)
        while table.probeCount < 3 && ContinuousClock.now < deadline {
          try await Task.sleep(for: .milliseconds(1))
        }
        // far more instant polls than the 10 s timeout allows would happen here if the watchdog kept running
        try await Task.sleep(for: .milliseconds(40))
        return 0
      }

      let result = await f.makeSession(timing: f.sleeper.timing(startupTimeout: .seconds(10))).launch(makeLaunchRecipe())

      #expect(result == .exited)
      #expect(table.probeCount == 3)
      #expect(f.runner.killCount == 1)
    }
  }

  @Test func LCH_036_gameProbeMatchesTheSecondArgumentCaseInsensitively() async throws {
    try await withLaunchFixture { f in
      f.table.probe.value = { _ in
        [ProcessRecord(pid: 77, arguments: ["/fake/wine", #"Z:\GAMES\gi\YUANSHEN.EXE"#], workingDirectory: "/Games/GI")]
      }
      let table = f.table
      f.runner.game.value = .custom { _ in
        let deadline = ContinuousClock.now + .seconds(5)
        while table.probeCount < 1 && ContinuousClock.now < deadline {
          try await Task.sleep(for: .milliseconds(1))
        }
        try await Task.sleep(for: .milliseconds(40))
        return 0
      }

      let result = await f.makeSession(timing: f.sleeper.timing(startupTimeout: .seconds(10))).launch(makeLaunchRecipe())

      #expect(result == .exited)
      #expect(table.probeCount == 1)
    }
  }

  @Test func LCH_036_gameExecutableNameOnlyInTheFirstArgumentDoesNotCountAsStarted() async throws {
    var options = LaunchFixtureOptions()
    options.game = .hang
    try await withLaunchFixture(options) { f in
      f.table.probe.value = { _ in
        [
          ProcessRecord(pid: 78, arguments: ["YuanShen.exe"], workingDirectory: "/Games/GI"),
          ProcessRecord(pid: 79, arguments: ["YuanShen.exe", "explorer.exe"], workingDirectory: "/Games/GI"),
        ]
      }

      let result = await f.makeSession(timing: f.sleeper.timing(startupTimeout: .seconds(10))).launch(makeLaunchRecipe())

      #expect(result == .startupTimedOut)
      #expect((8...12).contains(f.table.probeCount))
    }
  }

  @Test func LCH_036_loaderThatExitsBeforeAnyGameProcessIsAFailedExitNotATimeout() async throws {
    var options = LaunchFixtureOptions()
    options.game = .exit(5)
    options.gameAppears = false
    try await withLaunchFixture(options) { f in
      let result = await f.session.launch(makeLaunchRecipe())

      guard case .failedExit(let code, _) = result else {
        Issue.record("expected .failedExit, got \(result)")
        return
      }
      #expect(code == 5)
      #expect(f.runner.killCount == 1)
    }
  }

  @Test func LCH_036_loaderThatExitsZeroBeforeAnyGameProcessIsANormalExit() async throws {
    var options = LaunchFixtureOptions()
    options.gameAppears = false
    try await withLaunchFixture(options) { f in
      let result = await f.session.launch(makeLaunchRecipe())

      #expect(result == .exited)
      #expect(f.runner.gameCalls.count == 1)
      #expect(f.runner.killCount == 1)
    }
  }
}

// MARK: - Registry restore (LCH-037 / LCH-038)

@Suite("GameSession registry restore", .timeLimit(.minutes(1))) struct GameSessionRegistryTests {
  @Test func LCH_037_restoresResolutionOriginalValuesAfterTheGameExits() async throws {
    try await withLaunchFixture { f in
      seedOriginalResolution(f)
      let initial = f.runner.registrySnapshot

      let result = await f.session.launch(makeLaunchRecipe(registry: resolutionEdits()))

      #expect(result == .exited)
      let duringGame = try #require(f.runner.snapshots.first).registry
      let key = LaunchRegistry.miHoYoKey
      #expect(duringGame[LaunchRegistry.regID(key, LaunchRegistry.widthName)] == .dword(2560))
      #expect(duringGame[LaunchRegistry.regID(key, LaunchRegistry.heightName)] == .dword(1600))
      #expect(duringGame[LaunchRegistry.regID(key, LaunchRegistry.fullscreenName)] == .dword(0))
      let trace = f.trace.all
      let game = try #require(trace.firstIndex(of: "GAME"))
      for (name, value) in [
        (LaunchRegistry.widthName, UInt32(1280)), (LaunchRegistry.heightName, 720), (LaunchRegistry.fullscreenName, 1),
      ] {
        let restore = trace.lastIndex(of: loaderLabel(regAddDwordArgs(key, name, value)))
        #expect(restore != nil)
        #expect((restore ?? 0) > game)
      }
      #expect(f.runner.registrySnapshot == initial)
    }
  }

  @Test func LCH_037_valuesThatDidNotExistAreDeletedWithRegDeleteAfterTheGame() async throws {
    try await withLaunchFixture { f in
      // nothing seeded: the player never had a custom resolution
      let result = await f.session.launch(makeLaunchRecipe(registry: resolutionEdits()))

      #expect(result == .exited)
      let key = LaunchRegistry.miHoYoKey
      let trace = f.trace.all
      let game = try #require(trace.firstIndex(of: "GAME"))
      for name in [LaunchRegistry.widthName, LaunchRegistry.heightName, LaunchRegistry.fullscreenName] {
        let restore = trace.lastIndex(of: loaderLabel(regDeleteArgs(key, name)))
        #expect(restore != nil)
        #expect((restore ?? 0) > game)
      }
      #expect(f.runner.registrySnapshot.isEmpty)
      #expect(f.runner.snapshots.first?.registry.count == 3)
    }
  }

  @Test func LCH_037_originalStringValueIsRestoredAsRegSz() async throws {
    try await withLaunchFixture { f in
      f.runner.setRegistry(LaunchRegistry.miHoYoKey, "SomeText", .string("player value"))
      let edit = RegistryEdit(
        key: LaunchRegistry.miHoYoKey, name: "SomeText", action: .set(.string("forced")), restoresOnExit: true)

      let result = await f.session.launch(makeLaunchRecipe(registry: [edit]))

      #expect(result == .exited)
      #expect(f.runner.snapshots.first?.registry[LaunchRegistry.regID(LaunchRegistry.miHoYoKey, "SomeText")] == .string("forced"))
      #expect(f.trace.all.contains(loaderLabel(regAddStringArgs(LaunchRegistry.miHoYoKey, "SomeText", "player value"))))
      #expect(f.runner.registryValue(LaunchRegistry.miHoYoKey, "SomeText") == .string("player value"))
    }
  }

  @Test func LCH_037_hdrValueIsRestoredToItsOriginalNotJustDeleted() async throws {
    try await withLaunchFixture { f in
      f.runner.setRegistry(LaunchRegistry.miHoYoKey, LaunchRegistry.hdrName, .dword(0))
      let edit = RegistryEdit(
        key: LaunchRegistry.miHoYoKey, name: LaunchRegistry.hdrName, action: .set(.dword(1)), restoresOnExit: true)

      let result = await f.session.launch(makeLaunchRecipe(registry: [edit]))

      #expect(result == .exited)
      #expect(f.runner.snapshots.first?.registry[LaunchRegistry.regID(LaunchRegistry.miHoYoKey, LaunchRegistry.hdrName)] == .dword(1))
      #expect(f.runner.registryValue(LaunchRegistry.miHoYoKey, LaunchRegistry.hdrName) == .dword(0))
    }
  }

  @Test func LCH_005_persistentEditsAreWrittenButNeverQueriedJournaledOrRestored() async throws {
    try await withLaunchFixture { f in
      f.runner.setRegistry(LaunchRegistry.macDriverKey, "RetinaMode", .string("y"))
      let hdrOff = RegistryEdit(
        key: LaunchRegistry.miHoYoKey, name: LaunchRegistry.hdrName, action: .delete, restoresOnExit: false)
      f.runner.setRegistry(LaunchRegistry.miHoYoKey, LaunchRegistry.hdrName, .dword(1))

      let result = await f.session.launch(
        makeLaunchRecipe(registry: [LaunchRegistry.retinaEdit("n"), hdrOff, LaunchRegistry.widthEdit(2560)]))

      #expect(result == .exited)
      // positive: the persistent write and the delete happened
      let adds = f.runner.calls(.regAdd).map(\.arguments)
      #expect(adds.contains(regAddStringArgs(LaunchRegistry.macDriverKey, "RetinaMode", "n")))
      #expect(f.runner.calls(.regDelete).map(\.arguments).contains(regDeleteArgs(LaunchRegistry.miHoYoKey, LaunchRegistry.hdrName)))
      // only the restoring edit is queried
      #expect(f.runner.calls(.regQuery).map(\.arguments) == [regQueryArgs(LaunchRegistry.miHoYoKey, LaunchRegistry.widthName)])
      // persistent values stay as written, the restoring one is put back
      #expect(f.runner.registryValue(LaunchRegistry.macDriverKey, "RetinaMode") == .string("n"))
      #expect(f.runner.registryValue(LaunchRegistry.miHoYoKey, LaunchRegistry.hdrName) == nil)
      #expect(adds.filter { $0 == regAddStringArgs(LaunchRegistry.macDriverKey, "RetinaMode", "n") }.count == 1)
      let journal = try #require(f.runner.snapshots.first?.journal)
      #expect(journal.registry.map(\.name) == [LaunchRegistry.widthName])
    }
  }

  @Test func LCH_005_recipeWithOnlyPersistentEditsQueriesAndRestoresNothing() async throws {
    try await withLaunchFixture { f in
      let result = await f.session.launch(makeLaunchRecipe(registry: [LaunchRegistry.retinaEdit("y")]))

      #expect(result == .exited)
      #expect(f.runner.calls(.regAdd).count == 1)
      #expect(f.runner.calls(.regQuery).isEmpty)
      f.expectNoLaunchResidue()
    }
  }
}
