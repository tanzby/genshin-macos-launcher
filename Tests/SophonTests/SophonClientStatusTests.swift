import Foundation
import Testing

@testable import Sophon

// SophonClient.status() and requiredDiskSpace(for:). Rule IDs refer to docs/parity/hk4e-cn.md.

@Suite struct SophonClientStatusTests {
  @Test func INS_002_anEmptyDirectoryHasNoLocalVersionButKnowsTheRemoteOne() async throws {
    let rig = SophonRig(main: .game("5.6.0"))

    let status = try await rig.status()

    #expect(status == SophonStatus(installedVersion: nil, remoteVersion: "5.6.0"))
  }

  @Test func UPG_005_aBrokenInstallationIsReportedNotTakenForNoInstall() async throws {
    let rig = SophonRig(main: .game("5.6.0"))
    rig.install(.game("5.5.0"))
    rig.write("YuanShen_Data/Plugins/PCGameSDK.dll", Data("sdk".utf8))

    await #expect(throws: SophonError.brokenInstallation) { try await rig.status() }
  }

  @Test func UPG_005_anInstallThatLostItsExecutableIsStillAnInstallThatRepairCanFix() async throws {
    let rig = SophonRig(main: .game("5.6.0"))
    rig.install(.game("5.6.0"))
    try FileManager.default.removeItem(at: rig.url("YuanShen.exe"))

    let status = try await rig.status()

    #expect(status.installedVersion == "5.6.0")
  }

  @Test func APP_010_onlyTransportAndServerFaultsCountAsOffline() {
    #expect(SophonError.isOffline(SophonError.transport(code: -1009)))
    #expect(SophonError.isOffline(SophonError.http(status: 502)))
    #expect(SophonError.isOffline(URLError(.timedOut)))
    #expect(!SophonError.isOffline(SophonError.http(status: 403)))
    #expect(!SophonError.isOffline(SophonError.malformedResponse))
  }

  @Test func INS_014_anInstallAtTheLatestVersionOffersNothing() async throws {
    let rig = SophonRig(main: .game("5.6.0"))
    rig.install(.game("5.6.0"))

    let status = try await rig.status()

    #expect(status.installedVersion == "5.6.0")
    #expect(status.remoteVersion == "5.6.0")
    #expect(!status.canUpdate && !status.canPreDownload)
  }

  @Test func UPG_001_anOlderInstallCanBeUpdated() async throws {
    let rig = SophonRig(main: .game("5.6.0", diffTags: ["5.5.0"]))
    rig.install(.game("5.5.0"))

    let status = try await rig.status()

    #expect(status.installedVersion == "5.5.0")
    #expect(status.canUpdate)
  }

  @Test func UPG_001_versionsAreComparedNumerically() async throws {
    let rig = SophonRig(main: .game("5.10.0"))
    rig.install(.game("5.9.0"))

    #expect(try await rig.status().canUpdate)
  }

  @Test func UPG_005_anInstallNewerThanTheServerIsNotUpdated() async throws {
    let rig = SophonRig(main: .game("5.5.0"))
    rig.install(.game("5.6.0"))

    let status = try await rig.status()

    #expect(status.installedVersion == "5.6.0")
    #expect(!status.canUpdate)
  }

  @Test func INS_012_offlineKeepsTheLocalVersionAndLeavesTheRemoteVersionEmpty() async throws {
    let rig = SophonRig(main: .game("5.6.0"))
    rig.install(.game("5.5.0"))
    rig.cdn.online = false

    let status = try await rig.status()

    #expect(status == SophonStatus(installedVersion: "5.5.0", remoteVersion: nil))
  }

  @Test func INS_002_withoutAGameDirectoryOnlyTheRemoteSideIsKnown() async throws {
    let rig = SophonRig(main: .game("5.6.0"), withGameDirectory: false)

    let status = try await rig.status()

    #expect(status.installedVersion == nil)
    #expect(status.remoteVersion == "5.6.0")
  }

  @Test func PRE_001_aNewerPreDownloadBranchIsOfferedOnceForTheInstalledVersion() async throws {
    var pre = FakeRelease.game("5.7.0", diffTags: ["5.6.0"])
    pre.files["new.bin"] = Data("new".utf8)
    let rig = SophonRig(main: .game("5.6.0"), pre: pre)
    rig.install(.game("5.6.0"))

    let status = try await rig.status()

    #expect(status.canPreDownload)
    #expect(!status.canUpdate)
    #expect(status.preDownloadVersion == "5.7.0")
  }

  @Test func PRE_001_noOfferWhenTheBranchCannotPatchTheInstalledVersionOrIsNotNewer() async throws {
    let unpatchable = SophonRig(main: .game("5.6.0"), pre: .game("5.7.0", diffTags: ["5.5.0"]))
    unpatchable.install(.game("5.6.0"))
    #expect(try await unpatchable.status().canPreDownload == false)

    let notNewer = SophonRig(main: .game("5.6.0"), pre: .game("5.6.0", diffTags: ["5.6.0"]))
    notNewer.install(.game("5.6.0"))
    let status = try await notNewer.status()
    #expect(!status.canPreDownload)
    #expect(status.preDownloadVersion == nil)

    let none = SophonRig(main: .game("5.6.0"))
    none.install(.game("5.6.0"))
    #expect(try await none.status().preDownloadVersion == nil)
  }

  @Test func PRE_001_canUpdateAndCanPreDownloadCanBothBeTrue() async throws {
    let rig = SophonRig(main: .game("5.6.0", diffTags: ["5.5.0"]), pre: .game("5.7.0", diffTags: ["5.5.0", "5.6.0"]))
    rig.install(.game("5.5.0"))

    let status = try await rig.status()

    #expect(status.canUpdate && status.canPreDownload)
    #expect(status.preDownloadVersion == "5.7.0")
  }

  @Test func PRE_003_statusAsksOnlyForTheBranchListNotForBuildsOrManifests() async throws {
    let rig = SophonRig(main: .game("5.6.0"))
    rig.install(.game("5.6.0"))

    _ = try await rig.status()

    #expect(rig.cdn.requests.count == 1)
    #expect(rig.cdn.requests[0].contains("getGameBranches"))
  }
}

@Suite struct SophonClientDiskSpaceTests {
  @Test func INS_005_theInstallDiskCheckRefusesAFolderTheInstallCouldNotUseAndTouchesNothing() async throws {
    let rig = SophonRig(main: .game("5.6.0"))
    rig.install(.game("5.5.0"))
    rig.write("photos.zip", Data("mine".utf8))
    let before = try FileManager.default.contentsOfDirectory(atPath: rig.game.path).sorted()

    await #expect(throws: SophonError.installDirectoryNotEmpty) {
      try await rig.requiredDiskSpace(for: .install)
    }

    #expect(try FileManager.default.contentsOfDirectory(atPath: rig.game.path).sorted() == before)
    #expect(rig.cdn.requests.isEmpty)
  }

  @Test func INS_004_installNeedsTheUnpackedSizeOfTheGameCategory() async throws {
    let release = FakeRelease.game("5.6.0")
    let rig = SophonRig(main: release)

    #expect(try await rig.requiredDiskSpace(for: .install) == Int64(release.uncompressedSize))
  }

  @Test func INS_004_preDownloadNeedsTheDownloadSizeOfThePatchBuild() async throws {
    let pre = FakeRelease.game("5.7.0", diffTags: ["5.6.0"])
    let rig = SophonRig(main: .game("5.6.0"), pre: pre)
    rig.install(.game("5.6.0"))

    #expect(try await rig.requiredDiskSpace(for: .preDownload) == Int64(pre.compressedSize))
  }

  @Test func INS_004_updateNeedsTheDownloadPlusWhatLands() async throws {
    let main = FakeRelease.game("5.6.0", diffTags: ["5.5.0"])
    let rig = SophonRig(main: main)
    rig.install(.game("5.5.0"))

    #expect(try await rig.requiredDiskSpace(for: .update) == Int64(main.compressedSize + main.uncompressedSize))
  }

  @Test func INS_004_aPatchableUpdateDiskCheckReadsOnlyThePatchBuild() async throws {
    let main = FakeRelease.game("5.6.0", diffTags: ["5.5.0"])
    let rig = SophonRig(main: main)
    rig.install(.game("5.5.0"))

    _ = try await rig.requiredDiskSpace(for: .update)

    #expect(rig.cdn.requests.contains { $0.contains("getPatchBuild") })
    #expect(!rig.cdn.requests.contains { $0.contains("getBuild") })
  }

  @Test func INS_004_updateOfAnUnpatchableVersionNeedsAFullInstall() async throws {
    let main = FakeRelease.game("5.6.0", diffTags: ["5.5.0"])
    let rig = SophonRig(main: main)
    rig.install(.game("5.0.0"))

    #expect(try await rig.requiredDiskSpace(for: .update) == Int64(main.uncompressedSize))
  }

  @Test func INS_004_repairNeedsTheSizeOfTheFilesThatAreMissingOrWrong() async throws {
    let release = FakeRelease.game("5.6.0")
    let rig = SophonRig(main: release)
    rig.install(release)
    try FileManager.default.removeItem(at: rig.url("pkg_version"))
    rig.write("YuanShen.exe", Data("short".utf8))

    let needed = try await rig.requiredDiskSpace(for: .repair)

    #expect(needed == Int64(release.files["pkg_version"]!.count + release.files["YuanShen.exe"]!.count))
  }

  @Test func INS_004_aCdnWithoutSizeStatsIsAContractBreakNotZeroBytes() async throws {
    var full = FakeRelease.game("5.6.0")
    full.omitsStats = true
    let install = SophonRig(main: full)
    await #expect(throws: SophonError.malformedResponse) { try await install.requiredDiskSpace(for: .install) }

    var main = FakeRelease.game("5.6.0", diffTags: ["5.5.0"])
    main.omitsStats = true
    let update = SophonRig(main: main)
    update.install(.game("5.5.0"))
    await #expect(throws: SophonError.malformedResponse) { try await update.requiredDiskSpace(for: .update) }

    var pre = FakeRelease.game("5.7.0", diffTags: ["5.6.0"])
    pre.omitsStats = true
    let preDownload = SophonRig(main: .game("5.6.0"), pre: pre)
    preDownload.install(.game("5.6.0"))
    await #expect(throws: SophonError.malformedResponse) {
      try await preDownload.requiredDiskSpace(for: .preDownload)
    }
  }
}
