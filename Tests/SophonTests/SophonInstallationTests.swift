import Foundation
import Testing
import TestSupport

@testable import Sophon

// Installed-version detection, config.ini and the install-directory rules (UPG-005, INS-005/006, UPG-011, INS-016).
// Rule IDs refer to docs/parity/hk4e-cn.md.

private let installation = SophonInstallation(game: FakeGameCDN.game())

private func makeGame(
  ggm: String? = "\0" + "5.6.0_100_200" + "\0", config: String? = nil, executable: Bool = true, pcGameSDK: Bool = false
) throws -> URL {
  let root = temporaryURL("genshin-launcher-inst")
  let data = root.appending(path: "YuanShen_Data")
  try FileManager.default.createDirectory(at: data.appending(path: "Plugins"), withIntermediateDirectories: true)
  if executable { try Data("MZ".utf8).write(to: root.appending(path: "YuanShen.exe")) }
  if pcGameSDK { try Data().write(to: data.appending(path: "Plugins/PCGameSDK.dll")) }
  if let ggm { try Data(ggm.utf8).write(to: data.appending(path: "globalgamemanagers")) }
  if let config { try Data(config.utf8).write(to: root.appending(path: "config.ini")) }
  return root
}

private func iniWith(_ version: String) -> String {
  "[General]\r\nchannel=1\r\ncps=mihoyo\r\ngame_version=\(version)\r\nsdk_version=\r\nsub_channel=1\r\n"
}

@Suite struct SophonInstallationVersionTests {
  @Test func UPG_005_versionComesFromGlobalGameManagersWhenConfigIsMissing() throws {
    let game = try makeGame()
    #expect(try installation.installedVersion(in: game) == "5.6.0")
  }

  @Test func UPG_005_theSmallerOfGlobalGameManagersAndConfigWins() throws {
    let game = try makeGame(config: iniWith("5.5.0"))
    #expect(try installation.installedVersion(in: game) == "5.5.0")

    let newer = try makeGame(config: iniWith("5.7.0"))
    #expect(try installation.installedVersion(in: newer) == "5.6.0")
  }

  @Test func UPG_005_versionsAreComparedNumericallyNotAsText() throws {
    let game = try makeGame(ggm: "\0" + "5.10.0_1_2" + "\0", config: iniWith("5.9.0"))
    #expect(try installation.installedVersion(in: game) == "5.9.0")
    #expect(SophonVersion.isOlder("5.9.0", than: "5.10.0"))
    #expect(!SophonVersion.isOlder("5.10.0", than: "5.9.0"))
    #expect(!SophonVersion.isOlder("5.6.0", than: "5.6.0"))
  }

  @Test func UPG_005_missingOrMalformedConfigOnlyFallsBackToGlobalGameManagers() throws {
    let game = try makeGame(config: "[General]\r\nnothing here\r\n")
    #expect(try installation.installedVersion(in: game) == "5.6.0")
  }

  @Test func UPG_005_theVersionPatternMustMatchExactlyOnce() throws {
    let none = try makeGame(ggm: "no version in here")
    #expect(throws: SophonError.brokenInstallation) { try installation.installedVersion(in: none) }

    let two = try makeGame(ggm: "\0" + "5.6.0_1_2" + "\0x\0" + "5.5.0_3_4" + "\0")
    #expect(throws: SophonError.brokenInstallation) { try installation.installedVersion(in: two) }
  }

  @Test func UPG_005_onlyTheChinaReleaseIsRecognised() throws {
    // The global release keeps its data in GenshinImpact_Data, so nothing is found under YuanShen_Data.
    let global = temporaryURL("genshin-launcher-inst")
    try FileManager.default.createDirectory(
      at: global.appending(path: "GenshinImpact_Data"), withIntermediateDirectories: true)
    #expect(try installation.installedVersion(in: global) == nil)

    // A China install that only lost its executable still has a version, so repair can bring the file back.
    let noExecutable = try makeGame(executable: false)
    #expect(try installation.installedVersion(in: noExecutable) == "5.6.0")

    let bilibili = try makeGame(pcGameSDK: true)
    #expect(throws: SophonError.brokenInstallation) { try installation.installedVersion(in: bilibili) }
  }

  @Test func INS_005_anEmptyOrHalfInstalledDirectoryIsNotInstalled() throws {
    let empty = makeTemporaryDirectory("genshin-launcher-inst")
    #expect(try installation.installedVersion(in: empty) == nil)

    // An interrupted install: the template still says 0.0.0, so the install can be continued.
    let half = try makeGame(config: iniWith("0.0.0"))
    #expect(try installation.installedVersion(in: half) == nil)
  }
}

@Suite struct SophonInstallationConfigTests {
  @Test func INS_005_prepareWritesTheChinaTemplateWithCRLFAndCreatesTheTempDirectory() throws {
    let root = temporaryURL("genshin-launcher-inst")

    try installation.prepareForInstall(in: root)

    let text = try String(contentsOf: root.appending(path: "config.ini"), encoding: .utf8)
    #expect(text == "[General]\r\nchannel=1\r\ncps=mihoyo\r\ngame_version=0.0.0\r\nsdk_version=\r\nsub_channel=1\r\n")
    var isDirectory: ObjCBool = false
    #expect(FileManager.default.fileExists(atPath: installation.tempDirectory(in: root).path, isDirectory: &isDirectory))
    #expect(isDirectory.boolValue)
  }

  @Test func INS_005_prepareAcceptsTheTempDirectoryAndFinderLeftovers() throws {
    let root = temporaryURL("genshin-launcher-inst")
    try FileManager.default.createDirectory(at: installation.tempDirectory(in: root), withIntermediateDirectories: true)
    try Data().write(to: root.appending(path: ".DS_Store"))

    try installation.prepareForInstall(in: root)
  }

  @Test func INS_005_prepareContinuesAnInterruptedInstallAndKeepsItsFiles() throws {
    let half = try makeGame(config: iniWith("0.0.0"))

    try installation.prepareForInstall(in: half)

    #expect(FileManager.default.fileExists(atPath: half.appending(path: "YuanShen.exe").path))
  }

  @Test func INS_005_prepareRefusesADirectoryWithAnotherInstallOrOtherFiles() throws {
    let installed = try makeGame(config: iniWith("5.6.0"))
    #expect(throws: SophonError.installDirectoryNotEmpty) { try installation.prepareForInstall(in: installed) }
    #expect(try String(contentsOf: installed.appending(path: "config.ini"), encoding: .utf8) == iniWith("5.6.0"))

    let stranger = makeTemporaryDirectory("genshin-launcher-inst")
    try Data("x".utf8).write(to: stranger.appending(path: "photos.zip"))
    #expect(throws: SophonError.installDirectoryNotEmpty) { try installation.prepareForInstall(in: stranger) }
    #expect(!FileManager.default.fileExists(atPath: stranger.appending(path: "config.ini").path))
  }

  @Test func INS_005_validateJudgesLikePrepareButTouchesNothing() throws {
    let installed = try makeGame(config: iniWith("5.6.0"))
    let half = try makeGame(config: iniWith("0.0.0"))
    let stranger = temporaryURL("genshin-launcher-inst")
    let missing = temporaryURL("genshin-launcher-inst")
    try FileManager.default.createDirectory(at: stranger, withIntermediateDirectories: true)
    try Data("x".utf8).write(to: stranger.appending(path: "photos.zip"))

    #expect(throws: SophonError.installDirectoryNotEmpty) { try installation.validateInstallDirectory(installed) }
    #expect(throws: SophonError.installDirectoryNotEmpty) { try installation.validateInstallDirectory(stranger) }
    try installation.validateInstallDirectory(half)
    try installation.validateInstallDirectory(missing)

    #expect(!FileManager.default.fileExists(atPath: missing.path))
    #expect(!FileManager.default.fileExists(atPath: stranger.appending(path: ".genshin-launcher-tmp").path))
    #expect(!FileManager.default.fileExists(atPath: half.appending(path: ".genshin-launcher-tmp").path))
    #expect(try String(contentsOf: installed.appending(path: "config.ini"), encoding: .utf8) == iniWith("5.6.0"))
  }

  @Test func UPG_011_writeVersionReplacesExactlyTheGameVersionLine() throws {
    let game = try makeGame(config: iniWith("5.5.0"))

    try installation.writeVersion("5.6.0", in: game)

    #expect(try String(contentsOf: game.appending(path: "config.ini"), encoding: .utf8) == iniWith("5.6.0"))
  }

  @Test func UPG_011_writeVersionSkipsAnUnrecognisedFileInsteadOfGuessing() throws {
    let text = "[General]\r\ngame_version=5.5.0\r\ngame_version=5.5.0\r\n"
    let game = try makeGame(config: text)

    #expect(throws: SophonError.invalidConfig) { try installation.writeVersion("5.6.0", in: game) }
    #expect(try String(contentsOf: game.appending(path: "config.ini"), encoding: .utf8) == text)

    let missing = try makeGame()
    #expect(throws: SophonError.invalidConfig) { try installation.writeVersion("5.6.0", in: missing) }
  }

  @Test func INS_016_legacyTempFoldersAreRemovedOnlyFromARecognisedGameDirectory() throws {
    let game = try makeGame(config: iniWith("5.6.0"))
    for name in [".tmp", "ldiff"] {
      try FileManager.default.createDirectory(at: game.appending(path: name), withIntermediateDirectories: true)
    }
    let current = installation.tempDirectory(in: game)
    try FileManager.default.createDirectory(at: current, withIntermediateDirectories: true)
    try Data("{}".utf8).write(to: current.appending(path: "job.json"))

    installation.removeLegacyTemporaryFolders(in: game)

    #expect(!FileManager.default.fileExists(atPath: game.appending(path: ".tmp").path))
    #expect(!FileManager.default.fileExists(atPath: game.appending(path: "ldiff").path))
    #expect(FileManager.default.fileExists(atPath: current.appending(path: "job.json").path))

    let stranger = temporaryURL("genshin-launcher-inst")
    try FileManager.default.createDirectory(at: stranger.appending(path: ".tmp"), withIntermediateDirectories: true)
    installation.removeLegacyTemporaryFolders(in: stranger)
    #expect(FileManager.default.fileExists(atPath: stranger.appending(path: ".tmp").path))
  }
}

@Suite struct SophonGameDescriptorTests {
  @Test func UPG_005_theGameDescriptorNamesTheFilesNotSophon() throws {
    let other = SophonGame(
      endpoints: FakeGameCDN.endpoints, dataFolder: "Other_Data", executableName: "Other.exe",
      foreignBuildMarkers: ["Other_Data/Foreign.dll"], tempDirectoryName: ".other-tmp")
    let installation = SophonInstallation(game: other)
    let root = temporaryURL("genshin-launcher-other")
    let data = root.appending(path: "Other_Data")
    try FileManager.default.createDirectory(at: data, withIntermediateDirectories: true)
    try Data(("\0" + "1.2.3_4_5" + "\0").utf8).write(to: data.appending(path: "globalgamemanagers"))

    #expect(try installation.installedVersion(in: root) == "1.2.3")
    #expect(installation.tempDirectory(in: root).lastPathComponent == ".other-tmp")

    try Data().write(to: data.appending(path: "Foreign.dll"))
    #expect(throws: SophonError.brokenInstallation) { try installation.installedVersion(in: root) }
  }
}
