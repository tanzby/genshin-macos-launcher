import Foundation
import Testing

@testable import Sophon

// Install detection, version reading, the update decision and job events as the parity checklist words them
// (docs/parity/hk4e-cn.md). The cases of the same behaviour that carry a UPG/INS ID are in ClientStatusTests.

@Suite struct SophonClientParityStatusTests {
  // APP-011: a game folder counts as installed only while its version can be read.
  @Test func APP_011_noGameDirectoryMeansNotInstalled() async throws {
    let rig = SophonRig(main: .game("5.6.0"), withGameDirectory: false)

    #expect(try await rig.status().installedVersion == nil)
  }

  @Test func APP_011_aFolderWithAReadableVersionIsInstalled() async throws {
    let rig = SophonRig(main: .game("5.6.0"))
    rig.install(.game("5.6.0"))

    #expect(try await rig.status().installedVersion == "5.6.0")
  }

  @Test func APP_011_aFolderWhoseVersionFileIsGoneIsNotInstalledAndNothingIsDeleted() async throws {
    let rig = SophonRig(main: .game("5.6.0"))
    rig.install(.game("5.6.0"))
    try FileManager.default.removeItem(at: rig.url("YuanShen_Data/globalgamemanagers"))

    let status = try await rig.status()

    #expect(status.installedVersion == nil)
    #expect(rig.exists("YuanShen.exe"))
    #expect(rig.exists("config.ini"))
  }

  // APP-012: the version is the part before the first `_` of the build string in globalgamemanagers. The TS
  // launcher found it at a fixed offset behind `ic.app-category.`; the native reader matches the build string
  // itself (UPG-005), so a shifted layout cannot produce a wrong version, only "unreadable".
  @Test func APP_012_theVersionIsThePartOfTheBuildStringBeforeTheFirstUnderscore() async throws {
    let rig = SophonRig(main: .game("5.6.0"))
    rig.install(.game("5.5.0"))
    rig.write(
      "YuanShen_Data/globalgamemanagers",
      Data(("junk ic.app-category.games \0" + "5.5.0_31234567_31456789" + "\0 tail").utf8))

    #expect(try await rig.status().installedVersion == "5.5.0")
  }

  @Test func APP_012_aBuildStringWithoutTheTwoNumbersIsNotAVersion() async throws {
    let rig = SophonRig(main: .game("5.6.0"))
    rig.install(.game("5.5.0"))
    rig.write("YuanShen_Data/globalgamemanagers", Data(("\0" + "5.5.0" + "\0").utf8))

    await #expect(throws: SophonError.brokenInstallation) { try await rig.status() }
  }

  // APP-014: the TS launcher warned and went on with "0.0.0", which led to an "update" that reset the install.
  // An unreadable version is now a broken installation: reported, never turned into an update.
  @Test func APP_014_anUnreadableVersionIsReportedAsABrokenInstallationNotAsAnUpdate() async throws {
    let rig = SophonRig(main: .game("5.6.0"))
    rig.install(.game("5.5.0"))
    rig.write("YuanShen_Data/globalgamemanagers", Data("\0not a version\0".utf8))

    await #expect(throws: SophonError.brokenInstallation) { try await rig.status() }
  }

  @Test func APP_014_twoCandidatesAreAmbiguousAndAlsoReported() async throws {
    let rig = SophonRig(main: .game("5.6.0"))
    rig.install(.game("5.5.0"))
    rig.write("YuanShen_Data/globalgamemanagers", Data(("\0" + "5.5.0_1_2" + "\0x\0" + "5.6.0_3_4" + "\0").utf8))

    await #expect(throws: SophonError.brokenInstallation) { try await rig.status() }
  }

  // APP-016: an update is needed only while the installed version is older than the latest.
  @Test func APP_016_aNewerLatestVersionRequiresAnUpdate() async throws {
    let rig = SophonRig(main: .game("5.6.0", diffTags: ["5.5.0"]))
    rig.install(.game("5.5.0"))

    #expect(try await rig.status().canUpdate)
  }

  @Test func APP_016_theSameVersionAllowsLaunching() async throws {
    let rig = SophonRig(main: .game("5.6.0"))
    rig.install(.game("5.6.0"))

    #expect(try await rig.status().canUpdate == false)
  }

  @Test func APP_016_aHigherLocalVersionAllowsLaunching() async throws {
    let rig = SophonRig(main: .game("5.5.0"))
    rig.install(.game("5.6.0"))

    #expect(try await rig.status().canUpdate == false)
  }

  @Test func APP_016_aMinorVersionTenIsNewerThanNine() async throws {
    let rig = SophonRig(main: .game("5.10.0"))
    rig.install(.game("5.9.0"))

    #expect(try await rig.status().canUpdate)
  }
}
