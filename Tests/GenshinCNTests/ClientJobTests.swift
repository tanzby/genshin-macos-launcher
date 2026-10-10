import Foundation
import Launcher
import Sophon
import Testing

@testable import GenshinCN

// GenshinCNClient.run(_:) for install, repair, update and pre-download. Rule IDs refer to docs/parity/hk4e-cn.md.

private func isError(_ error: (any Error)?, _ expected: SophonError) -> Bool {
  (error as? SophonError) == expected
}

@Suite(.disabled("bisect")) struct ClientInstallTests {
  @Test func INS_003_installDownloadsEveryFileAndWritesTheVersionLast() async throws {
    let release = FakeRelease.game("5.6.0", extra: ["data/blob.bin": Data(repeating: 7, count: 300_000)])
    let rig = ClientRig(main: release)

    let result = await rig.run(.install)

    #expect(result.error == nil)
    for (path, content) in release.files { #expect(rig.read(path) == content) }
    #expect(rig.configText?.contains("game_version=5.6.0") == true)
    #expect(try await rig.client.status().localVersion == "5.6.0")
    #expect(result.progress.first == .preparing)
    #expect(result.progress.last == .finalizing)
  }

  @Test func INS_006_theVersionStaysAtZeroWhileFilesAreStillComing() async throws {
    let release = FakeRelease.game("5.6.0")
    let rig = ClientRig(main: release)
    rig.cdn.chunkDelay = .milliseconds(400)

    let task = Task { await rig.run(.install) }
    try await Task.sleep(for: .milliseconds(150))
    // Mid-install: the template is there, the real version is not, and the game does not count as installed.
    #expect(rig.configText?.contains("game_version=0.0.0") == true)
    #expect(try await rig.client.status().localVersion == nil)
    task.cancel()
    _ = await task.value
    #expect(rig.configText?.contains("game_version=0.0.0") == true)
  }

  @Test func INS_015_aCancelledInstallContinuesWhereItStoppedAndFinishes() async throws {
    let release = FakeRelease.game("5.6.0", extra: ["a.bin": Data(repeating: 1, count: 5000), "b.bin": Data(repeating: 2, count: 5000)])
    let rig = ClientRig(main: release)
    rig.cdn.chunkDelay = .milliseconds(150)
    let first = Task { await rig.run(.install) }
    try await Task.sleep(for: .milliseconds(200))
    first.cancel()
    _ = await first.value
    rig.cdn.chunkDelay = .zero

    let second = await rig.run(.install)

    #expect(second.error == nil)
    for (path, content) in release.files { #expect(rig.read(path) == content) }
    #expect(rig.configText?.contains("game_version=5.6.0") == true)
  }

  @Test func INS_005_installRefusesADirectoryThatHoldsAnotherInstallAndChangesNothing() async throws {
    let rig = ClientRig(main: .game("5.6.0"))
    rig.install(.game("5.5.0"))
    let before = rig.configText

    let result = await rig.run(.install)

    #expect(isError(result.error, .installDirectoryNotEmpty))
    #expect(rig.configText == before)
    #expect(rig.cdn.chunkRequests().isEmpty)
  }

  @Test func INS_003_installWithoutAGameDirectoryFailsBeforeAnyRequest() async throws {
    let rig = ClientRig(main: .game("5.6.0"), withGameDirectory: false)

    let result = await rig.run(.install)

    #expect((result.error as? GenshinCNClientError) == .noGameDirectory)
    #expect(rig.cdn.requests.isEmpty)
  }
}

@Suite(.disabled("bisect")) struct ClientRepairTests {
  @Test func REP_003_repairDownloadsOnlyTheDamagedFilesAndKeepsConfigIni() async throws {
    let release = FakeRelease.game("5.6.0", extra: ["data/blob.bin": Data(repeating: 7, count: 4000)])
    let rig = ClientRig(main: release)
    rig.install(release)
    let config = rig.configText
    try FileManager.default.removeItem(at: rig.url("pkg_version"))
    rig.write("data/blob.bin", Data(repeating: 9, count: 4000))  // right size, wrong MD5 (REP-004)

    let result = await rig.run(.repair)

    #expect(result.error == nil)
    #expect(rig.read("pkg_version") == release.files["pkg_version"])
    #expect(rig.read("data/blob.bin") == release.files["data/blob.bin"])
    #expect(rig.cdn.chunkRequests().count == 2)
    #expect(rig.configText == config)
  }

  @Test func REP_002_repairRefusesAnOutdatedInstall() async throws {
    let rig = ClientRig(main: .game("5.6.0"))
    rig.install(.game("5.5.0"))

    let result = await rig.run(.repair)

    #expect((result.error as? GenshinCNClientError) == .outdated(installed: "5.5.0", latest: "5.6.0"))
    #expect(rig.cdn.chunkRequests().isEmpty)
  }

  @Test func REP_001_repairOfAnEmptyDirectoryIsNotInstalled() async throws {
    let rig = ClientRig(main: .game("5.6.0"))

    let result = await rig.run(.repair)

    #expect((result.error as? GenshinCNClientError) == .notInstalled)
  }

  @Test func UPG_014_repairLeavesFilesOutsideTheManifestAlone() async throws {
    let release = FakeRelease.game("5.6.0")
    let rig = ClientRig(main: release)
    rig.install(release)
    rig.write("YuanShen_Data/StreamingAssets/AudioAssets/English(US)/voice.pck", Data("voice".utf8))

    let result = await rig.run(.repair)

    #expect(result.error == nil)
    #expect(rig.exists("YuanShen_Data/StreamingAssets/AudioAssets/English(US)/voice.pck"))
  }

  @Test func LCH_014_repairBringsBackAMovedAsideFileFromItsBackupInsteadOfDownloadingIt() async throws {
    let release = FakeRelease.game("5.6.0")
    let rig = ClientRig(main: release)
    rig.install(release)
    let crash = "YuanShen_Data/upload_crash.exe"
    try FileManager.default.moveItem(at: rig.url(crash), to: rig.url(crash + ".bak"))

    let result = await rig.run(.repair)

    #expect(result.error == nil)
    #expect(rig.read(crash) == release.files[crash])
    #expect(!rig.exists(crash + ".bak"))
    #expect(rig.cdn.chunkRequests().isEmpty)
  }

  @Test func LCH_014_aStaleBackupNextToTheLiveFileIsDropped() async throws {
    let release = FakeRelease.game("5.6.0")
    let rig = ClientRig(main: release)
    rig.install(release)
    let vulkan = "YuanShen_Data/Plugins/vulkan-1.dll"
    rig.write(vulkan + ".bak", Data("old".utf8))

    let result = await rig.run(.repair)

    #expect(result.error == nil)
    #expect(rig.read(vulkan) == release.files[vulkan])
    #expect(!rig.exists(vulkan + ".bak"))
  }

  @Test func INS_016_legacyTemporaryFoldersGoWhenAJobStarts() async throws {
    let release = FakeRelease.game("5.6.0")
    let rig = ClientRig(main: release)
    rig.install(release)
    rig.write(".tmp/getGameBranches.json", Data("{}".utf8))
    rig.write("ldiff/old.ldiff", Data("x".utf8))

    _ = await rig.run(.repair)

    #expect(!rig.exists(".tmp"))
    #expect(!rig.exists("ldiff"))
  }
}

@Suite(.disabled("bisect")) struct ClientRepairLaunchTests {
  @Test func REP_005_aRepairNeedsNoMarkerResetBecauseEveryLaunchPreparesTheGameAgain() async throws {
    let release = FakeRelease.game("5.6.0")
    let rig = ClientRig(main: release)
    rig.install(release)

    _ = await rig.run(.repair)
    _ = try await rig.client.launch(.init(gameDirectory: rig.game), onStarted: {})

    let recipe = try #require(rig.launcher.recipes.first)
    #expect(recipe.moveAside.count == 3)
    #expect(recipe.prefixCopies.count == 4)
  }
}

@Suite(.disabled("bisect")) struct ClientUpdateTests {
  private func updateRig() -> (ClientRig, FakeRelease, FakeRelease) {
    let old = FakeRelease.game("5.5.0", extra: ["gone.bin": Data("old only".utf8)])
    let new = FakeRelease.game("5.6.0", extra: ["fresh.bin": Data("fresh".utf8)], diffTags: ["5.5.0"])
    let rig = ClientRig(main: new)
    rig.cdn.setDeletions(from: "5.5.0", ["gone.bin": Data("old only".utf8)])
    rig.install(old)
    return (rig, old, new)
  }

  @Test func UPG_003_updateBringsTheGameToTheNewVersionAndRemovesOldFiles() async throws {
    let (rig, _, new) = updateRig()

    let result = await rig.run(.update)

    #expect(result.error == nil)
    for (path, content) in new.files { #expect(rig.read(path) == content) }
    #expect(!rig.exists("gone.bin"))
    #expect(try await rig.client.status().localVersion == "5.6.0")
  }

  @Test func UPG_011_updateWritesTheNewVersionIntoConfigIniOnlyAfterTheFilesAreIn() async throws {
    let (rig, _, _) = updateRig()
    rig.cdn.chunkDelay = .milliseconds(300)

    let task = Task { await rig.run(.update) }
    try await Task.sleep(for: .milliseconds(100))
    #expect(rig.configText?.contains("game_version=5.5.0") == true)
    rig.cdn.chunkDelay = .zero
    let result = await task.value

    #expect(result.error == nil)
    #expect(rig.configText?.contains("game_version=5.6.0") == true)
  }

  @Test func UPG_011_aConfigIniThatCannotBeRewrittenDoesNotFailTheUpdate() async throws {
    let (rig, _, new) = updateRig()
    rig.write("config.ini", Data("[General]\r\ngame_version=5.5.0\r\ngame_version=5.5.0\r\n".utf8))

    let result = await rig.run(.update)

    #expect(result.error == nil)
    #expect(rig.read("pkg_version") == new.files["pkg_version"])
    #expect(try await rig.client.status().localVersion == "5.6.0")
  }

  @Test func UPG_006_updateWhenAlreadyCurrentIsAnError() async throws {
    let rig = ClientRig(main: .game("5.6.0"))
    rig.install(.game("5.6.0"))

    let result = await rig.run(.update)

    #expect((result.error as? GenshinCNClientError) == .noUpdate)
  }

  @Test func INS_013_aVersionThePatchBuildDoesNotKnowIsSyncedFromTheChunkManifestInstead() async throws {
    let new = FakeRelease.game("5.6.0", extra: ["fresh.bin": Data("fresh".utf8)], diffTags: ["5.5.0"])
    let rig = ClientRig(main: new)
    rig.install(.game("5.0.0"))

    let result = await rig.run(.update)

    #expect(result.error == nil)
    for (path, content) in new.files { #expect(rig.read(path) == content) }
    #expect(rig.configText?.contains("game_version=5.6.0") == true)
    #expect(!rig.cdn.requests.contains { $0.contains("getPatchBuild") })
  }

  @Test func UPG_005_updateOfAnEmptyDirectoryIsNotInstalled() async throws {
    let rig = ClientRig(main: .game("5.6.0"))

    let result = await rig.run(.update)

    #expect((result.error as? GenshinCNClientError) == .notInstalled)
  }

  @Test func UPG_012_updateLeavesNoLdiffOrPreDownloadRecordBehind() async throws {
    let (rig, _, _) = updateRig()

    _ = await rig.run(.update)

    #expect(!rig.exists(".yaagl-tmp/predownload.json"))
  }
}

@Suite(.disabled("bisect")) struct ClientPreDownloadTests {
  private func rig() -> (ClientRig, FakeRelease) {
    var pre = FakeRelease.game("5.7.0", extra: ["fresh.bin": Data("fresh 5.7".utf8)], diffTags: ["5.6.0"])
    pre.files["pkg_version"] = Data("pkg 5.7".utf8)
    let rig = ClientRig(main: .game("5.6.0"), pre: pre)
    rig.cdn.setDeletions(from: "5.6.0", [:])
    rig.install(.game("5.6.0"))
    return (rig, pre)
  }

  @Test func PRE_002_preDownloadFetchesIntoTheTempFolderAndTouchesNothingElse() async throws {
    let (rig, _) = rig()
    let config = rig.configText
    let pkg = rig.read("pkg_version")

    let result = await rig.run(.preDownload)

    #expect(result.error == nil)
    #expect(rig.configText == config)
    #expect(rig.read("pkg_version") == pkg)
    #expect(!rig.exists("fresh.bin"))
    #expect(rig.exists(".yaagl-tmp"))
    #expect(try await rig.client.status().localVersion == "5.6.0")
  }

  @Test func PRE_001_afterAPreDownloadTheOfferIsGoneButTheVersionStaysKnown() async throws {
    let (rig, _) = rig()
    #expect(try await rig.client.status().canPreDownload)

    _ = await rig.run(.preDownload)

    let status = try await rig.client.status()
    #expect(!status.canPreDownload)
    #expect(status.preDownloadVersion == "5.7.0")
  }

  @Test func PRE_002_theUpdateAfterAPreDownloadNeedsNoChunksFromTheNetwork() async throws {
    let (rig, pre) = rig()
    // The pre-download branch becomes the main one on release day.
    _ = await rig.run(.preDownload)
    let fetchedByPreDownload = rig.cdn.chunkRequests().count
    #expect(fetchedByPreDownload > 0)
    rig.cdn.main = pre
    rig.cdn.pre = nil

    let result = await rig.run(.update)

    #expect(result.error == nil)
    #expect(rig.read("fresh.bin") == pre.files["fresh.bin"])
    #expect(rig.cdn.chunkRequests().count == fetchedByPreDownload)
    #expect(rig.configText?.contains("game_version=5.7.0") == true)
  }

  @Test func PRE_002_preDownloadWithoutAPreDownloadBranchIsAnError() async throws {
    let rig = ClientRig(main: .game("5.6.0"))
    rig.install(.game("5.6.0"))

    let result = await rig.run(.preDownload)

    #expect((result.error as? GenshinCNClientError) == .noPreDownload)
  }
}
