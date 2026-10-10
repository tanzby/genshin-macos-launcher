import Foundation
import Launcher
import Sophon
import Testing

@testable import GenshinCN

// GenshinCNClient.status() and requiredDiskSpace(for:). Rule IDs refer to docs/parity/hk4e-cn.md.

@Suite(.disabled("bisect")) struct ClientStatusTests {
  @Test func INS_002_anEmptyDirectoryHasNoLocalVersionButKnowsTheRemoteOne() async throws {
    let rig = ClientRig(main: .game("5.6.0"))

    let status = try await rig.client.status()

    #expect(status == GameStatus(localVersion: nil, remoteVersion: "5.6.0", canUpdate: false, canPreDownload: false))
  }

  @Test func INS_014_anInstallAtTheLatestVersionOffersNothing() async throws {
    let rig = ClientRig(main: .game("5.6.0"))
    rig.install(.game("5.6.0"))

    let status = try await rig.client.status()

    #expect(status.localVersion == "5.6.0")
    #expect(status.remoteVersion == "5.6.0")
    #expect(!status.canUpdate && !status.canPreDownload)
  }

  @Test func UPG_001_anOlderInstallCanBeUpdated() async throws {
    let rig = ClientRig(main: .game("5.6.0", diffTags: ["5.5.0"]))
    rig.install(.game("5.5.0"))

    let status = try await rig.client.status()

    #expect(status.localVersion == "5.5.0")
    #expect(status.canUpdate)
  }

  @Test func UPG_001_versionsAreComparedNumerically() async throws {
    let rig = ClientRig(main: .game("5.10.0"))
    rig.install(.game("5.9.0"))

    #expect(try await rig.client.status().canUpdate)
  }

  @Test func UPG_005_anInstallNewerThanTheServerIsNotUpdated() async throws {
    let rig = ClientRig(main: .game("5.5.0"))
    rig.install(.game("5.6.0"))

    let status = try await rig.client.status()

    #expect(status.localVersion == "5.6.0")
    #expect(!status.canUpdate)
  }

  @Test func INS_012_offlineKeepsTheLocalVersionAndLeavesTheRemoteVersionEmpty() async throws {
    let rig = ClientRig(main: .game("5.6.0"))
    rig.install(.game("5.5.0"))
    rig.cdn.online = false

    let status = try await rig.client.status()

    #expect(status == GameStatus(localVersion: "5.5.0", remoteVersion: nil, canUpdate: false, canPreDownload: false))
  }

  @Test func INS_002_withoutAGameDirectoryOnlyTheRemoteSideIsKnown() async throws {
    let rig = ClientRig(main: .game("5.6.0"), withGameDirectory: false)

    let status = try await rig.client.status()

    #expect(status.localVersion == nil)
    #expect(status.remoteVersion == "5.6.0")
  }

  @Test func PRE_001_aNewerPreDownloadBranchIsOfferedOnceForTheInstalledVersion() async throws {
    var pre = FakeRelease.game("5.7.0", diffTags: ["5.6.0"])
    pre.files["new.bin"] = Data("new".utf8)
    let rig = ClientRig(main: .game("5.6.0"), pre: pre)
    rig.install(.game("5.6.0"))

    let status = try await rig.client.status()

    #expect(status.canPreDownload)
    #expect(!status.canUpdate)
    #expect(status.preDownloadVersion == "5.7.0")
  }

  @Test func PRE_001_noOfferWhenTheBranchCannotPatchTheInstalledVersionOrIsNotNewer() async throws {
    let unpatchable = ClientRig(main: .game("5.6.0"), pre: .game("5.7.0", diffTags: ["5.5.0"]))
    unpatchable.install(.game("5.6.0"))
    #expect(try await unpatchable.client.status().canPreDownload == false)

    let notNewer = ClientRig(main: .game("5.6.0"), pre: .game("5.6.0", diffTags: ["5.6.0"]))
    notNewer.install(.game("5.6.0"))
    let status = try await notNewer.client.status()
    #expect(!status.canPreDownload)
    #expect(status.preDownloadVersion == nil)

    let none = ClientRig(main: .game("5.6.0"))
    none.install(.game("5.6.0"))
    #expect(try await none.client.status().preDownloadVersion == nil)
  }

  @Test func PRE_001_canUpdateAndCanPreDownloadCanBothBeTrue() async throws {
    let rig = ClientRig(main: .game("5.6.0", diffTags: ["5.5.0"]), pre: .game("5.7.0", diffTags: ["5.5.0", "5.6.0"]))
    rig.install(.game("5.5.0"))

    let status = try await rig.client.status()

    #expect(status.canUpdate && status.canPreDownload)
    #expect(status.preDownloadVersion == "5.7.0")
  }

  @Test func PRE_003_statusAsksOnlyForTheBranchListNotForBuildsOrManifests() async throws {
    let rig = ClientRig(main: .game("5.6.0"))
    rig.install(.game("5.6.0"))

    _ = try await rig.client.status()

    #expect(rig.cdn.requests.count == 1)
    #expect(rig.cdn.requests[0].contains("getGameBranches"))
  }
}

@Suite(.disabled("bisect")) struct ClientDiskSpaceTests {
  @Test func INS_004_installNeedsTheUnpackedSizeOfTheGameCategory() async throws {
    let release = FakeRelease.game("5.6.0")
    let rig = ClientRig(main: release)

    #expect(try await rig.client.requiredDiskSpace(for: .install) == Int64(release.uncompressedSize))
  }

  @Test func INS_004_preDownloadNeedsTheDownloadSizeOfThePatchBuild() async throws {
    let pre = FakeRelease.game("5.7.0", diffTags: ["5.6.0"])
    let rig = ClientRig(main: .game("5.6.0"), pre: pre)
    rig.install(.game("5.6.0"))

    #expect(try await rig.client.requiredDiskSpace(for: .preDownload) == Int64(pre.compressedSize))
  }

  @Test func INS_004_updateNeedsTheDownloadPlusWhatLands() async throws {
    let main = FakeRelease.game("5.6.0", diffTags: ["5.5.0"])
    let rig = ClientRig(main: main)
    rig.install(.game("5.5.0"))

    #expect(try await rig.client.requiredDiskSpace(for: .update) == Int64(main.compressedSize + main.uncompressedSize))
  }

  @Test func INS_004_updateOfAnUnpatchableVersionNeedsAFullInstall() async throws {
    let main = FakeRelease.game("5.6.0", diffTags: ["5.5.0"])
    let rig = ClientRig(main: main)
    rig.install(.game("5.0.0"))

    #expect(try await rig.client.requiredDiskSpace(for: .update) == Int64(main.uncompressedSize))
  }

  @Test func INS_004_repairNeedsTheSizeOfTheFilesThatAreMissingOrWrong() async throws {
    let release = FakeRelease.game("5.6.0")
    let rig = ClientRig(main: release)
    rig.install(release)
    try FileManager.default.removeItem(at: rig.url("pkg_version"))
    rig.write("YuanShen.exe", Data("short".utf8))

    let needed = try await rig.client.requiredDiskSpace(for: .repair)

    #expect(needed == Int64(release.files["pkg_version"]!.count + release.files["YuanShen.exe"]!.count))
  }
}
