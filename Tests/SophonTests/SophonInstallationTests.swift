import Foundation
import Testing

@testable import Sophon

// Installed-version detection, config.ini and the install-directory rules (UPG-005, INS-005/006, UPG-011, INS-016).
// Rule IDs refer to docs/parity/hk4e-cn.md.

private func makeGame(
  ggm: String? = "\0" + "5.6.0_100_200" + "\0", config: String? = nil, executable: Bool = true, pcGameSDK: Bool = false
) throws -> URL {
  let root = FileManager.default.temporaryDirectory.appending(path: "yaagl-inst-\(UUID().uuidString)")
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
    defer { try? FileManager.default.removeItem(at: game) }
    #expect(try SophonInstallation.installedVersion(in: game) == "5.6.0")
  }

  @Test func UPG_005_theSmallerOfGlobalGameManagersAndConfigWins() throws {
    let game = try makeGame(config: iniWith("5.5.0"))
    defer { try? FileManager.default.removeItem(at: game) }
    #expect(try SophonInstallation.installedVersion(in: game) == "5.5.0")

    let newer = try makeGame(config: iniWith("5.7.0"))
    defer { try? FileManager.default.removeItem(at: newer) }
    #expect(try SophonInstallation.installedVersion(in: newer) == "5.6.0")
  }

  @Test func UPG_005_versionsAreComparedNumericallyNotAsText() throws {
    let game = try makeGame(ggm: "\0" + "5.10.0_1_2" + "\0", config: iniWith("5.9.0"))
    defer { try? FileManager.default.removeItem(at: game) }
    #expect(try SophonInstallation.installedVersion(in: game) == "5.9.0")
    #expect(SophonVersion.isOlder("5.9.0", than: "5.10.0"))
    #expect(!SophonVersion.isOlder("5.10.0", than: "5.9.0"))
    #expect(!SophonVersion.isOlder("5.6.0", than: "5.6.0"))
  }

  @Test func UPG_005_missingOrMalformedConfigOnlyFallsBackToGlobalGameManagers() throws {
    let game = try makeGame(config: "[General]\r\nnothing here\r\n")
    defer { try? FileManager.default.removeItem(at: game) }
    #expect(try SophonInstallation.installedVersion(in: game) == "5.6.0")
  }

  @Test func UPG_005_theVersionPatternMustMatchExactlyOnce() throws {
    let none = try makeGame(ggm: "no version in here")
    defer { try? FileManager.default.removeItem(at: none) }
    #expect(throws: SophonError.brokenInstallation) { try SophonInstallation.installedVersion(in: none) }

    let two = try makeGame(ggm: "\0" + "5.6.0_1_2" + "\0x\0" + "5.5.0_3_4" + "\0")
    defer { try? FileManager.default.removeItem(at: two) }
    #expect(throws: SophonError.brokenInstallation) { try SophonInstallation.installedVersion(in: two) }
  }

  @Test func UPG_005_onlyTheChinaReleaseIsRecognised() throws {
    let global = try makeGame(executable: false)
    defer { try? FileManager.default.removeItem(at: global) }
    #expect(try SophonInstallation.installedVersion(in: global) == nil)

    let bilibili = try makeGame(pcGameSDK: true)
    defer { try? FileManager.default.removeItem(at: bilibili) }
    #expect(throws: SophonError.brokenInstallation) { try SophonInstallation.installedVersion(in: bilibili) }
  }

  @Test func INS_005_anEmptyOrHalfInstalledDirectoryIsNotInstalled() throws {
    let empty = FileManager.default.temporaryDirectory.appending(path: "yaagl-inst-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: empty) }
    #expect(try SophonInstallation.installedVersion(in: empty) == nil)

    // An interrupted install: the template still says 0.0.0, so the install can be continued.
    let half = try makeGame(config: iniWith("0.0.0"))
    defer { try? FileManager.default.removeItem(at: half) }
    #expect(try SophonInstallation.installedVersion(in: half) == nil)
  }
}

@Suite struct SophonInstallationConfigTests {
  @Test func INS_005_prepareWritesTheChinaTemplateWithCRLFAndCreatesTheTempDirectory() throws {
    let root = FileManager.default.temporaryDirectory.appending(path: "yaagl-inst-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }

    try SophonInstallation.prepareForInstall(in: root)

    let text = try String(contentsOf: root.appending(path: "config.ini"), encoding: .utf8)
    #expect(text == "[General]\r\nchannel=1\r\ncps=mihoyo\r\ngame_version=0.0.0\r\nsdk_version=\r\nsub_channel=1\r\n")
    var isDirectory: ObjCBool = false
    #expect(FileManager.default.fileExists(atPath: SophonInstallation.tempDirectory(in: root).path, isDirectory: &isDirectory))
    #expect(isDirectory.boolValue)
  }

  @Test func INS_005_prepareAcceptsTheTempDirectoryAndFinderLeftovers() throws {
    let root = FileManager.default.temporaryDirectory.appending(path: "yaagl-inst-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: SophonInstallation.tempDirectory(in: root), withIntermediateDirectories: true)
    try Data().write(to: root.appending(path: ".DS_Store"))
    defer { try? FileManager.default.removeItem(at: root) }

    try SophonInstallation.prepareForInstall(in: root)
  }

  @Test func INS_005_prepareContinuesAnInterruptedInstallAndKeepsItsFiles() throws {
    let half = try makeGame(config: iniWith("0.0.0"))
    defer { try? FileManager.default.removeItem(at: half) }

    try SophonInstallation.prepareForInstall(in: half)

    #expect(FileManager.default.fileExists(atPath: half.appending(path: "YuanShen.exe").path))
  }

  @Test func INS_005_prepareRefusesADirectoryWithAnotherInstallOrOtherFiles() throws {
    let installed = try makeGame(config: iniWith("5.6.0"))
    defer { try? FileManager.default.removeItem(at: installed) }
    #expect(throws: SophonError.installDirectoryNotEmpty) { try SophonInstallation.prepareForInstall(in: installed) }
    #expect(try String(contentsOf: installed.appending(path: "config.ini"), encoding: .utf8) == iniWith("5.6.0"))

    let stranger = FileManager.default.temporaryDirectory.appending(path: "yaagl-inst-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: stranger, withIntermediateDirectories: true)
    try Data("x".utf8).write(to: stranger.appending(path: "photos.zip"))
    defer { try? FileManager.default.removeItem(at: stranger) }
    #expect(throws: SophonError.installDirectoryNotEmpty) { try SophonInstallation.prepareForInstall(in: stranger) }
    #expect(!FileManager.default.fileExists(atPath: stranger.appending(path: "config.ini").path))
  }

  @Test func UPG_011_writeVersionReplacesExactlyTheGameVersionLine() throws {
    let game = try makeGame(config: iniWith("5.5.0"))
    defer { try? FileManager.default.removeItem(at: game) }

    try SophonInstallation.writeVersion("5.6.0", in: game)

    #expect(try String(contentsOf: game.appending(path: "config.ini"), encoding: .utf8) == iniWith("5.6.0"))
  }

  @Test func UPG_011_writeVersionSkipsAnUnrecognisedFileInsteadOfGuessing() throws {
    let text = "[General]\r\ngame_version=5.5.0\r\ngame_version=5.5.0\r\n"
    let game = try makeGame(config: text)
    defer { try? FileManager.default.removeItem(at: game) }

    #expect(throws: SophonError.invalidConfig) { try SophonInstallation.writeVersion("5.6.0", in: game) }
    #expect(try String(contentsOf: game.appending(path: "config.ini"), encoding: .utf8) == text)

    let missing = try makeGame()
    defer { try? FileManager.default.removeItem(at: missing) }
    #expect(throws: SophonError.invalidConfig) { try SophonInstallation.writeVersion("5.6.0", in: missing) }
  }

  @Test func INS_016_legacyTempFoldersAreRemovedOnlyFromARecognisedGameDirectory() throws {
    let game = try makeGame(config: iniWith("5.6.0"))
    defer { try? FileManager.default.removeItem(at: game) }
    for name in [".tmp", "ldiff"] {
      try FileManager.default.createDirectory(at: game.appending(path: name), withIntermediateDirectories: true)
    }
    let current = SophonInstallation.tempDirectory(in: game)
    try FileManager.default.createDirectory(at: current, withIntermediateDirectories: true)
    try Data("{}".utf8).write(to: current.appending(path: "job.json"))

    SophonInstallation.removeLegacyTemporaryFolders(in: game)

    #expect(!FileManager.default.fileExists(atPath: game.appending(path: ".tmp").path))
    #expect(!FileManager.default.fileExists(atPath: game.appending(path: "ldiff").path))
    #expect(FileManager.default.fileExists(atPath: current.appending(path: "job.json").path))

    let stranger = FileManager.default.temporaryDirectory.appending(path: "yaagl-inst-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: stranger.appending(path: ".tmp"), withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: stranger) }
    SophonInstallation.removeLegacyTemporaryFolders(in: stranger)
    #expect(FileManager.default.fileExists(atPath: stranger.appending(path: ".tmp").path))
  }
}
