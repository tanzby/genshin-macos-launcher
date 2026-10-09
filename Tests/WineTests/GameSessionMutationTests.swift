import Darwin
import Foundation
import Platform
import Testing

@testable import Wine

// Launch mutations (move-aside, prefix copies, logs), the journal, recover() and the orphan sweep.

private func crashFiles(_ f: LaunchFixture) -> [URL] {
  [
    f.gameFile("YuanShen_Data/upload_crash.exe"), f.gameFile("YuanShen_Data/Plugins/crashreport.exe"),
    f.gameFile("YuanShen_Data/Plugins/vulkan-1.dll"),
  ]
}

private func writeJournal(_ journal: LaunchJournal, for f: LaunchFixture) throws {
  try FileManager.default.createDirectory(at: f.layout.root, withIntermediateDirectories: true)
  try JSONEncoder().encode(journal).write(to: f.layout.launchJournal)
}

// MARK: - Move aside (LCH-012 / LCH-014)

@Suite("GameSession move-aside", .timeLimit(.minutes(1))) struct GameSessionMoveAsideTests {
  @Test func LCH_014_existingFilesAreRenamedToBakDuringTheGameAndRenamedBackAfterwards() async throws {
    try await withLaunchFixture { f in
      let files = crashFiles(f)
      for (index, url) in files.enumerated() { try launchWrite("ORIGINAL-FILE-\(index)", to: url) }
      f.runner.watch(files + files.map { URL(filePath: $0.path + ".bak") })

      let result = await f.session.launch(makeLaunchRecipe(moveAside: files))

      #expect(result == .exited)
      let during = try #require(f.runner.snapshots.first)
      for (index, url) in files.enumerated() {
        #expect(!during.exists(url))
        #expect(during.text(URL(filePath: url.path + ".bak")) == "ORIGINAL-FILE-\(index)")
        #expect(launchRead(url) == "ORIGINAL-FILE-\(index)")
        #expect(!FileManager.default.fileExists(atPath: url.path + ".bak"))
      }
      f.expectNoLaunchResidue()
    }
  }

  @Test func LCH_014_aFileThatDoesNotExistIsSkippedWithoutCreatingAnything() async throws {
    try await withLaunchFixture { f in
      let files = crashFiles(f)
      try launchWrite("ONLY-ONE", to: files[0])
      f.runner.watch(files + files.map { URL(filePath: $0.path + ".bak") })

      let result = await f.session.launch(makeLaunchRecipe(moveAside: files))

      #expect(result == .exited)
      let during = try #require(f.runner.snapshots.first)
      #expect(during.text(URL(filePath: files[0].path + ".bak")) == "ONLY-ONE")  // positive: the existing one moved
      for url in files.dropFirst() {
        #expect(!during.exists(url))
        #expect(!during.exists(URL(filePath: url.path + ".bak")))
        #expect(!FileManager.default.fileExists(atPath: url.path))
        #expect(!FileManager.default.fileExists(atPath: url.path + ".bak"))
      }
      #expect(launchRead(files[0]) == "ONLY-ONE")
    }
  }

  @Test func LCH_012_liveFileWinsOverAStaleBakAndTheStaleBakIsReplaced() async throws {
    try await withLaunchFixture { f in
      let file = f.gameFile("YuanShen_Data/Plugins/vulkan-1.dll")
      let bak = URL(filePath: file.path + ".bak")
      try launchWrite("LIVE-FILE", to: file)
      try launchWrite("STALE-BAK", to: bak)
      f.runner.watch([file, bak])

      let result = await f.session.launch(makeLaunchRecipe(moveAside: [file]))

      #expect(result == .exited)
      let during = try #require(f.runner.snapshots.first)
      #expect(!during.exists(file))
      #expect(during.text(bak) == "LIVE-FILE")
      #expect(launchRead(file) == "LIVE-FILE")
      #expect(!FileManager.default.fileExists(atPath: bak.path))
    }
  }

  @Test func LCH_012_aLoneBakIsLeftAloneAtLaunch() async throws {
    try await withLaunchFixture { f in
      let file = f.gameFile("YuanShen_Data/Plugins/vulkan-1.dll")
      let bak = URL(filePath: file.path + ".bak")
      try launchWrite("CLEAN-BACKUP", to: bak)
      f.runner.watch([file, bak])

      let result = await f.session.launch(makeLaunchRecipe(moveAside: [file]))

      #expect(result == .exited)
      let during = try #require(f.runner.snapshots.first)
      #expect(!during.exists(file))
      #expect(during.text(bak) == "CLEAN-BACKUP")
    }
  }

  @Test func LCH_014_restoreKeepsAFileTheGameSideRecreatedAndDropsTheBak() async throws {
    try await withLaunchFixture { f in
      let file = f.gameFile("YuanShen_Data/upload_crash.exe")
      let bak = URL(filePath: file.path + ".bak")
      try launchWrite("OLD-FILE", to: file)
      // a repair re-downloads the original while the launch is in flight
      f.runner.game.value = .custom { _ in
        try launchWrite("REPAIRED-FILE", to: file)
        return 0
      }

      let result = await f.session.launch(makeLaunchRecipe(moveAside: [file]))

      #expect(result == .exited)
      #expect(f.runner.snapshots.first != nil)
      #expect(launchRead(file) == "REPAIRED-FILE")
      #expect(!FileManager.default.fileExists(atPath: bak.path))
    }
  }

  @Test func LCH_014_filesAreMovedBeforeTheGameStartsAndTheirNamesAreInTheJournal() async throws {
    try await withLaunchFixture { f in
      let files = crashFiles(f)
      for url in files { try launchWrite("CONTENT", to: url) }

      let result = await f.session.launch(makeLaunchRecipe(moveAside: files))

      #expect(result == .exited)
      let journal = try #require(f.runner.snapshots.first?.journal)
      for url in files { #expect(journal.movedAside.contains(url.path)) }
    }
  }
}

// MARK: - Prefix copies (LCH-018)

@Suite("GameSession prefix copies", .timeLimit(.minutes(1))) struct GameSessionPrefixCopyTests {
  private func copies(_ f: LaunchFixture) -> [PrefixCopy] {
    [
      PrefixCopy(source: f.protonExtra("steam64.exe"), destination: "system32/steam.exe"),
      PrefixCopy(source: f.protonExtra("steam32.exe"), destination: "syswow64/steam.exe"),
      PrefixCopy(source: f.protonExtra("lsteamclient64.dll"), destination: "system32/lsteamclient.dll"),
      PrefixCopy(source: f.protonExtra("lsteamclient32.dll"), destination: "syswow64/lsteamclient.dll"),
    ]
  }

  @Test func LCH_018_copiesAreDeployedIntoThePrefixWindowsDirectoryCreatingMissingDirectories() async throws {
    try await withLaunchFixture { f in
      for name in ["steam64.exe", "steam32.exe", "lsteamclient64.dll", "lsteamclient32.dll"] {
        try launchWrite("PAYLOAD-\(name)", to: f.protonExtra(name))
      }
      let targets = copies(f).map { f.layout.prefixWindows.appending(path: $0.destination) }
      f.runner.watch(targets)
      #expect(!FileManager.default.fileExists(atPath: f.layout.prefixWindows.appending(path: "syswow64").path))

      let result = await f.session.launch(makeLaunchRecipe(prefixCopies: copies(f)))

      #expect(result == .exited)
      let during = try #require(f.runner.snapshots.first)
      #expect(during.text(targets[0]) == "PAYLOAD-steam64.exe")
      #expect(during.text(targets[1]) == "PAYLOAD-steam32.exe")
      #expect(during.text(targets[2]) == "PAYLOAD-lsteamclient64.dll")
      #expect(during.text(targets[3]) == "PAYLOAD-lsteamclient32.dll")
    }
  }

  @Test func LCH_018_copiesStayInThePrefixAfterTheGameExits() async throws {
    try await withLaunchFixture { f in
      try launchWrite("PAYLOAD-STEAM", to: f.protonExtra("steam64.exe"))
      let target = f.layout.prefixWindows.appending(path: "system32/steam.exe")
      let copy = PrefixCopy(source: f.protonExtra("steam64.exe"), destination: "system32/steam.exe")

      let result = await f.session.launch(makeLaunchRecipe(prefixCopies: [copy]))

      #expect(result == .exited)
      #expect(f.runner.gameCalls.count == 1)
      #expect(launchRead(target) == "PAYLOAD-STEAM")
    }
  }

  @Test func LCH_018_aDifferingFileInThePrefixIsOverwrittenButAnIdenticalOneIsNotRewritten() async throws {
    try await withLaunchFixture { f in
      try launchWrite("NEW-STEAM", to: f.protonExtra("steam64.exe"))
      try launchWrite("SAME-CLIENT", to: f.protonExtra("lsteamclient64.dll"))
      let differing = f.layout.prefixWindows.appending(path: "system32/steam.exe")
      let identical = f.layout.prefixWindows.appending(path: "system32/lsteamclient.dll")
      try launchWrite("OLD-STEAM", to: differing)
      try launchWrite("SAME-CLIENT", to: identical)
      let longAgo = Date(timeIntervalSince1970: 1_000_000_000)
      try launchSetModificationDate(longAgo, of: identical)

      let result = await f.session.launch(
        makeLaunchRecipe(prefixCopies: [
          PrefixCopy(source: f.protonExtra("steam64.exe"), destination: "system32/steam.exe"),
          PrefixCopy(source: f.protonExtra("lsteamclient64.dll"), destination: "system32/lsteamclient.dll"),
        ]))

      #expect(result == .exited)
      #expect(launchRead(differing) == "NEW-STEAM")  // positive: the copy ran
      #expect(launchRead(identical) == "SAME-CLIENT")
      #expect(launchModificationDate(identical) == longAgo)
    }
  }

  @Test func LCH_018_copiesAreNotPartOfTheJournal() async throws {
    try await withLaunchFixture { f in
      try launchWrite("PAYLOAD-STEAM", to: f.protonExtra("steam64.exe"))
      let copy = PrefixCopy(source: f.protonExtra("steam64.exe"), destination: "system32/steam.exe")
      f.runner.watch([f.layout.prefixWindows.appending(path: "system32/steam.exe")])

      let result = await f.session.launch(makeLaunchRecipe(registry: [LaunchRegistry.widthEdit(2560)], prefixCopies: [copy]))

      #expect(result == .exited)
      let during = try #require(f.runner.snapshots.first)
      #expect(during.text(f.layout.prefixWindows.appending(path: "system32/steam.exe")) == "PAYLOAD-STEAM")
      let journal = try #require(during.journal)
      #expect(journal.movedAside.isEmpty)
      #expect(journal.registry.count == 1)
    }
  }
}

// MARK: - Journal

@Suite("GameSession journal", .timeLimit(.minutes(1))) struct GameSessionJournalTests {
  @Test func LCH_038_journalExistsWhileTheGameRunsRecordsTheOriginalsAndIsGoneAfterwards() async throws {
    try await withLaunchFixture { f in
      f.runner.setRegistry(LaunchRegistry.miHoYoKey, LaunchRegistry.widthName, .dword(1280))
      f.runner.setRegistry(LaunchRegistry.miHoYoKey, "SomeText", .string("player value"))
      // heightName is absent: its original is "did not exist"
      let files = crashFiles(f)
      try launchWrite("CONTENT", to: files[1])
      let text = RegistryEdit(
        key: LaunchRegistry.miHoYoKey, name: "SomeText", action: .set(.string("forced")), restoresOnExit: true)

      let result = await f.session.launch(
        makeLaunchRecipe(
          registry: [LaunchRegistry.widthEdit(2560), LaunchRegistry.heightEdit(1600), text], moveAside: files))

      #expect(result == .exited)
      let during = try #require(f.runner.snapshots.first)
      #expect(during.journalExisted)
      let journal = try #require(during.journal)
      #expect(journal.schemaVersion == LaunchJournal.currentSchemaVersion)
      #expect(journal.movedAside.contains(files[1].path))
      let originals = Dictionary(uniqueKeysWithValues: journal.registry.map { ($0.name, $0.original) })
      #expect(journal.registry.count == 3)
      #expect(originals[LaunchRegistry.widthName] == .some(.dword(1280)))
      #expect(originals[LaunchRegistry.heightName] == .some(nil))
      #expect(originals["SomeText"] == .some(.string("player value")))
      #expect(journal.registry.allSatisfy { $0.key == LaunchRegistry.miHoYoKey })
      f.expectNoLaunchResidue()
    }
  }

  @Test func LCH_038_journalIsOnDiskBeforeTheFirstRegistryWriteAndAfterAllOriginalsWereRead() async throws {
    try await withLaunchFixture { f in
      f.runner.setRegistry(LaunchRegistry.miHoYoKey, LaunchRegistry.widthName, .dword(1280))
      let files = crashFiles(f)
      try launchWrite("CONTENT", to: files[0])

      let result = await f.session.launch(
        makeLaunchRecipe(registry: [LaunchRegistry.widthEdit(2560)], moveAside: files))

      #expect(result == .exited)
      let calls = f.runner.calls
      let firstAdd = try #require(calls.firstIndex { $0.kind == .regAdd })
      let lastQuery = try #require(calls.lastIndex { $0.kind == .regQuery })
      #expect(lastQuery < firstAdd)
      #expect(calls[firstAdd].journalExisted)
      // the restore's own write also happens while the journal still exists
      let lastAdd = try #require(calls.lastIndex { $0.kind == .regAdd })
      #expect(calls[lastAdd].journalExisted)
      #expect(lastAdd > firstAdd)
    }
  }

  @Test func LCH_038_aJournalLeftByACrashedSessionIsReplayedBeforeTheOriginalsAreRead() async throws {
    try await withLaunchFixture { f in
      // The crashed session forced 2560 / 1600; the player's real values were 1280 / (none).
      let key = LaunchRegistry.miHoYoKey
      f.runner.setRegistry(key, LaunchRegistry.widthName, .dword(2560))
      f.runner.setRegistry(key, LaunchRegistry.heightName, .dword(1600))
      try writeJournal(
        LaunchJournal(
          registry: [
            .init(key: key, name: LaunchRegistry.widthName, original: .dword(1280)),
            .init(key: key, name: LaunchRegistry.heightName, original: nil),
          ]), for: f)

      let result = await f.session.launch(
        makeLaunchRecipe(registry: [LaunchRegistry.widthEdit(3000), LaunchRegistry.heightEdit(2000)]))

      #expect(result == .exited)
      let trace = f.trace.all
      let replay = try #require(trace.firstIndex(of: loaderLabel(regAddDwordArgs(key, LaunchRegistry.widthName, 1280))))
      let firstQuery = try #require(trace.firstIndex(of: loaderLabel(regQueryArgs(key, LaunchRegistry.widthName))))
      #expect(replay < firstQuery)
      // the new journal saved the player's real values, not the forced ones
      let journal = try #require(f.runner.snapshots.first?.journal)
      let originals = Dictionary(uniqueKeysWithValues: journal.registry.map { ($0.name, $0.original) })
      #expect(originals[LaunchRegistry.widthName] == .some(.dword(1280)))
      #expect(originals[LaunchRegistry.heightName] == .some(nil))
      // after the launch the player's real values are back
      #expect(f.runner.registryValue(key, LaunchRegistry.widthName) == .dword(1280))
      #expect(f.runner.registryValue(key, LaunchRegistry.heightName) == nil)
      #expect(f.runner.snapshots.first?.registry[LaunchRegistry.regID(key, LaunchRegistry.widthName)] == .dword(3000))
      f.expectNoLaunchResidue()
    }
  }

  @Test func LCH_038_recoverReplaysAJournalRestoringRegistryOriginalsAndRenamingBakBack() async throws {
    try await withLaunchFixture { f in
      let key = LaunchRegistry.miHoYoKey
      f.runner.setRegistry(key, LaunchRegistry.widthName, .dword(2560))
      f.runner.setRegistry(key, LaunchRegistry.heightName, .dword(1600))
      f.runner.setRegistry(key, "SomeText", .string("forced"))
      let files = crashFiles(f)
      try launchWrite("MOVED-0", to: URL(filePath: files[0].path + ".bak"))
      try launchWrite("MOVED-2", to: URL(filePath: files[2].path + ".bak"))
      try writeJournal(
        LaunchJournal(
          movedAside: files.map(\.path),  // files[1] was never moved: nothing to rename, nothing to fail
          registry: [
            .init(key: key, name: LaunchRegistry.widthName, original: .dword(1280)),
            .init(key: key, name: LaunchRegistry.heightName, original: nil),
            .init(key: key, name: "SomeText", original: .string("player value")),
          ]), for: f)

      await f.session.recover()

      #expect(f.runner.registryValue(key, LaunchRegistry.widthName) == .dword(1280))
      #expect(f.runner.registryValue(key, LaunchRegistry.heightName) == nil)
      #expect(f.runner.registryValue(key, "SomeText") == .string("player value"))
      let trace = f.trace.all
      #expect(trace.contains(loaderLabel(regAddDwordArgs(key, LaunchRegistry.widthName, 1280))))
      #expect(trace.contains(loaderLabel(regDeleteArgs(key, LaunchRegistry.heightName))))
      #expect(trace.contains(loaderLabel(regAddStringArgs(key, "SomeText", "player value"))))
      #expect(launchRead(files[0]) == "MOVED-0")
      #expect(launchRead(files[2]) == "MOVED-2")
      #expect(!FileManager.default.fileExists(atPath: files[0].path + ".bak"))
      #expect(!FileManager.default.fileExists(atPath: files[1].path))
      #expect(!FileManager.default.fileExists(atPath: files[2].path + ".bak"))
      f.expectNoLaunchResidue()
    }
  }

  @Test func LCH_038_recoverKillsThePrefixBeforeReplayingTheJournal() async throws {
    try await withLaunchFixture { f in
      let key = LaunchRegistry.miHoYoKey
      f.table.sweepSnapshots.value = [[f.serverOrphan()]]
      f.runner.setRegistry(key, LaunchRegistry.widthName, .dword(2560))
      try writeJournal(
        LaunchJournal(registry: [.init(key: key, name: LaunchRegistry.widthName, original: .dword(1280))]), for: f)

      await f.session.recover()

      #expect(Array(f.trace.all.prefix(2)) == ["wineserver -k", "kill 9001"])
      let replay = try #require(f.trace.all.firstIndex(of: loaderLabel(regAddDwordArgs(key, LaunchRegistry.widthName, 1280))))
      #expect(replay > 1)
    }
  }

  @Test func LCH_038_recoverKeepsAnExistingOriginalAndDeletesTheBak() async throws {
    try await withLaunchFixture { f in
      let file = f.gameFile("YuanShen_Data/upload_crash.exe")
      let bak = URL(filePath: file.path + ".bak")
      try launchWrite("REPAIRED-ORIGINAL", to: file)
      try launchWrite("OLD-BACKUP", to: bak)
      try writeJournal(LaunchJournal(movedAside: [file.path]), for: f)

      await f.session.recover()

      #expect(launchRead(file) == "REPAIRED-ORIGINAL")
      #expect(!FileManager.default.fileExists(atPath: bak.path))
      f.expectNoLaunchResidue()
    }
  }

  @Test func LCH_038_recoverWithoutAJournalOnlyShutsThePrefixDown() async throws {
    try await withLaunchFixture { f in
      await f.session.recover()

      #expect(f.runner.killCount == 1)
      #expect(f.runner.calls.filter { $0.kind == .regAdd || $0.kind == .regDelete || $0.kind == .regQuery }.isEmpty)
      #expect(f.runner.gameCalls.isEmpty)
    }
  }
}

// MARK: - Shutdown sweep (LCH-003 / WIN-018)

@Suite("GameSession orphan sweep", .timeLimit(.minutes(1))) struct GameSessionSweepTests {
  @Test func WIN_018_recoverRunsWineserverKillWithThePrefixThenSweepsWithOpenPaths() async throws {
    try await withLaunchFixture { f in
      await f.session.recover()

      let kill = try #require(f.runner.calls(.wineserverKill).first)
      #expect(kill.executable == f.layout.wineserver.path)
      #expect(kill.arguments == ["-k"])
      #expect(kill.environment["WINEPREFIX"] == f.layout.prefixDirectory.path)
      #expect(f.table.sweepCount == 1)
    }
  }

  @Test func WIN_018_sweepKillsEveryProcessWithAnOpenFileInThePrefixServerDirectory() async throws {
    try await withLaunchFixture { f in
      let server = f.serverDirectory
      #expect(server.hasPrefix("/tmp/.wine-\(getuid())/server-"))
      f.table.sweepSnapshots.value = [
        [
          ProcessRecord(pid: 101, arguments: ["wineserver"], openPaths: ["/dev/null", server + "/socket"]),
          ProcessRecord(pid: 102, arguments: ["services.exe"], openPaths: [server + "/lock"]),
          // another prefix's server directory
          ProcessRecord(pid: 103, arguments: ["wineserver"], openPaths: ["/tmp/.wine-\(getuid())/server-ffff-ffff/socket"]),
          // a longer inode that merely starts with this one
          ProcessRecord(pid: 104, arguments: ["wineserver"], openPaths: [server + "c/socket"]),
          ProcessRecord(pid: 105, arguments: ["Finder"], openPaths: ["/Users/x/Documents/a.txt"]),
        ]
      ]

      await f.session.recover()

      #expect(Set(f.table.killed) == [101, 102])
    }
  }

  @Test func WIN_018_sweepKillsWindowsCommandLinesWhoseWorkingDirectoryIsInsideThePrefix() async throws {
    try await withLaunchFixture { f in
      let prefix = f.layout.prefixDirectory.path
      f.table.sweepSnapshots.value = [
        [
          ProcessRecord(
            pid: 201, arguments: [#"C:\windows\system32\winedevice.exe"#, "x"],
            workingDirectory: prefix + "/drive_c/windows/system32"),
          ProcessRecord(
            pid: 202, arguments: [#"Z:\Games\GI\YuanShen.exe"#], workingDirectory: prefix + "/drive_c"),
          // cwd outside the prefix
          ProcessRecord(pid: 203, arguments: [#"C:\windows\system32\cmd.exe"#], workingDirectory: "/Users/x"),
          // not a Windows command line
          ProcessRecord(pid: 204, arguments: ["/usr/bin/vim"], workingDirectory: prefix + "/drive_c"),
          // no working directory known
          ProcessRecord(pid: 205, arguments: [#"C:\windows\system32\cmd.exe"#], workingDirectory: nil),
          // a sibling directory that merely starts with the prefix path
          ProcessRecord(pid: 206, arguments: [#"C:\x.exe"#], workingDirectory: prefix + "2/drive_c"),
          ProcessRecord(pid: 207, arguments: [], workingDirectory: prefix + "/drive_c"),
        ]
      ]

      await f.session.recover()

      #expect(Set(f.table.killed) == [201, 202])
    }
  }

  @Test func WIN_018_sweepNeverKillsTheLauncherItselfEvenWhenItMatchesBothRules() async throws {
    try await withLaunchFixture { f in
      let own = ProcessInfo.processInfo.processIdentifier
      let prefix = f.layout.prefixDirectory.path
      f.table.sweepSnapshots.value = [
        [
          ProcessRecord(pid: own, arguments: [#"Z:\self.exe"#], workingDirectory: prefix + "/drive_c", openPaths: [f.serverDirectory + "/socket"]),
          f.serverOrphan(pid: 9001),
        ]
      ]

      await f.session.recover()

      #expect(f.table.killed == [9001])
    }
  }

  @Test func LCH_003_aFailingWineserverKillIsIgnoredAndTheSweepStillRuns() async throws {
    try await withLaunchFixture { f in
      f.table.sweepSnapshots.value = [[f.serverOrphan()]]
      f.runner.responder.value = { call in
        call.kind == .wineserverKill ? ProcessResult(exitCode: 1, output: "wineserver: not running") : nil
      }

      let result = await f.session.launch(makeLaunchRecipe())

      #expect(result == .exited)
      #expect(f.runner.killCount >= 1)
      #expect(f.table.killed == [9001])
    }
  }

  @Test func LCH_003_aThrowingWineserverKillIsIgnoredAndTheSweepStillRuns() async throws {
    try await withLaunchFixture { f in
      f.table.sweepSnapshots.value = [[f.serverOrphan()]]
      f.runner.responder.value = { call in
        if call.kind == .wineserverKill { throw FakeFailure(message: "spawn failed") }
        return nil
      }

      await f.session.recover()

      #expect(f.runner.killCount == 1)
      #expect(f.table.killed == [9001])
    }
  }
}

// MARK: - Logs and residue (LCH-019 / LCH-020)

@Suite("GameSession logs and residue", .timeLimit(.minutes(1))) struct GameSessionLogTests {
  @Test func LCH_020_gameLogIsNamedWithTheMillisecondTimestampInsideTheLogsDirectoryCreatedBeforeTheRun() async throws {
    try await withLaunchFixture { f in
      let before = Int64(Date().timeIntervalSince1970 * 1000)
      let result = await f.session.launch(makeLaunchRecipe())
      let after = Int64(Date().timeIntervalSince1970 * 1000)

      #expect(result == .exited)
      let snapshot = try #require(f.runner.snapshots.first)
      #expect(snapshot.logsDirectoryExists)
      let logFile = try #require(f.runner.gameCall?.logFile)
      let name = URL(filePath: logFile).lastPathComponent
      #expect(URL(filePath: logFile).deletingLastPathComponent().path == f.layout.logsDirectory.path)
      #expect(name.hasPrefix("game_") && name.hasSuffix(".log"))
      let digits = String(name.dropFirst("game_".count).dropLast(".log".count))
      let stamp = try #require(Int64(digits))
      #expect(stamp >= before - 1000 && stamp <= after + 1000)
      #expect(f.gameLogs == [name])
    }
  }

  @Test func LCH_020_onlyTheNewest20GameLogsAreKeptAndOtherFilesAreUntouched() async throws {
    try await withLaunchFixture { f in
      let logs = f.layout.logsDirectory
      for index in 1...25 {
        let url = logs.appending(path: String(format: "game_17000000000%02d.log", index))
        try launchWrite("old log \(index)", to: url)
        try launchSetModificationDate(Date(timeIntervalSince1970: 1_700_000_000 + Double(index)), of: url)
      }
      try launchWrite("gamehost", to: logs.appending(path: "gamehost.log"))
      try launchWrite("notes", to: logs.appending(path: "notes.txt"))

      let result = await f.session.launch(makeLaunchRecipe())

      #expect(result == .exited)
      let newLog = try #require(f.runner.gameCall?.logFile).split(separator: "/").last.map(String.init)
      let kept = f.gameLogs
      #expect(kept.count == 20)
      #expect(newLog.map(kept.contains) == true)
      for index in 7...25 { #expect(kept.contains(String(format: "game_17000000000%02d.log", index))) }
      for index in 1...6 { #expect(!kept.contains(String(format: "game_17000000000%02d.log", index))) }
      #expect(launchRead(logs.appending(path: "gamehost.log")) == "gamehost")
      #expect(launchRead(logs.appending(path: "notes.txt")) == "notes")
    }
  }

  @Test func LCH_019_noPatchedMarkerFileExistsBeforeDuringOrAfterALaunch() async throws {
    try await withLaunchFixture { f in
      let files = crashFiles(f)
      for url in files { try launchWrite("CONTENT", to: url) }
      let root = f.layout.root
      f.runner.game.value = .custom { _ in
        let during = wineRelativePaths(under: root).filter { $0.lowercased().contains("patched") }
        return during.isEmpty ? 0 : 9
      }

      let result = await f.session.launch(makeLaunchRecipe(registry: [LaunchRegistry.widthEdit(2560)], moveAside: files))

      #expect(result == .exited)  // exit code 9 would mean a marker existed while the game ran
      #expect(f.runner.gameCalls.count == 1)
      #expect(wineRelativePaths(under: f.directory).filter { $0.lowercased().contains("patched") }.isEmpty)
      f.expectNoLaunchResidue()
    }
  }
}

extension GameSessionJournalTests {
  @Test func LCH_038_aRestoreThatFailsKeepsTheItemInTheJournalForTheNextRecover() async throws {
    try await withLaunchFixture { f in
      let key = LaunchRegistry.miHoYoKey
      f.runner.setRegistry(key, LaunchRegistry.widthName, .dword(2560))
      try writeJournal(
        LaunchJournal(registry: [.init(key: key, name: LaunchRegistry.widthName, original: .dword(1280))]), for: f)
      f.runner.responder.value = { call in
        call.kind == .regAdd ? ProcessResult(exitCode: 1, output: "reg: failed") : nil
      }

      await f.session.recover()

      let data = try Data(contentsOf: f.layout.launchJournal)
      let kept = try JSONDecoder().decode(LaunchJournal.self, from: data)
      #expect(kept.registry.map(\.name) == [LaunchRegistry.widthName])
      #expect(kept.registry.first?.original == .dword(1280))

      f.runner.responder.value = nil
      await f.session.recover()

      #expect(f.runner.registryValue(key, LaunchRegistry.widthName) == .dword(1280))
      #expect(!FileManager.default.fileExists(atPath: f.layout.launchJournal.path))
    }
  }
}
