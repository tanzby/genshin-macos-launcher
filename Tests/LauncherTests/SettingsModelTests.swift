import Foundation
import Testing

@testable import Launcher

@MainActor
private func freshDefaults() -> UserDefaults {
  let suite = "yaagl-tests-\(UUID().uuidString)"
  let defaults = UserDefaults(suiteName: suite)!
  defaults.removePersistentDomain(forName: suite)
  return defaults
}

@MainActor @Suite struct SettingsModelTests {
  @Test func CFG_001_defaultsAreOffAndResolutionIs1080p() {
    let settings = SettingsModel(defaults: freshDefaults())
    #expect(settings.gameDirectory == nil)
    #expect(!settings.retina && !settings.metalHUD && !settings.leftCommandIsControl)
    #expect(!settings.hdr && !settings.metalFX && !settings.proxyEnabled)
    #expect(settings.customResolution == nil)
    #expect(settings.resolutionWidth == 1920 && settings.resolutionHeight == 1080)
  }

  @Test func CFG_001_changesPersistAcrossInstances() {
    let defaults = freshDefaults()
    let first = SettingsModel(defaults: defaults)
    first.gameDirectory = URL(filePath: "/Volumes/Games/Genshin")
    first.retina = true
    first.metalHUD = true
    first.leftCommandIsControl = true
    first.hdr = true
    first.metalFX = true
    #expect(first.setResolution(width: 2560, height: 1440))
    first.customResolutionEnabled = true
    #expect(first.setProxyHost("127.0.0.1:7890"))
    first.proxyEnabled = true

    let second = SettingsModel(defaults: defaults)
    #expect(second.gameDirectory == URL(filePath: "/Volumes/Games/Genshin"))
    #expect(second.retina && second.metalHUD && second.leftCommandIsControl && second.hdr && second.metalFX)
    #expect(second.customResolution == SettingsModel.Resolution(width: 2560, height: 1440))
    #expect(second.proxyEnabled)
    #expect(second.effectiveProxy == "127.0.0.1:7890")
  }

  @Test func CFG_011_metalHudPersistsAndDefaultsOff() { toggles(\.metalHUD) }
  @Test func CFG_012_retinaPersistsAndDefaultsOff() { toggles(\.retina) }
  @Test func CFG_013_leftCommandAsControlPersistsAndDefaultsOff() { toggles(\.leftCommandIsControl) }
  @Test func CFG_021_hdrPersistsAndDefaultsOff() { toggles(\.hdr) }
  @Test func CFG_029_metalFXPersistsAndDefaultsOff() { toggles(\.metalFX) }

  private func toggles(_ key: ReferenceWritableKeyPath<SettingsModel, Bool>) {
    let defaults = freshDefaults()
    let first = SettingsModel(defaults: defaults)
    #expect(first[keyPath: key] == false)
    first[keyPath: key] = true
    #expect(SettingsModel(defaults: defaults)[keyPath: key])
  }

  @Test func CFG_001_clearingTheGameDirectoryRemovesTheKey() {
    let defaults = freshDefaults()
    let settings = SettingsModel(defaults: defaults)
    settings.gameDirectory = URL(filePath: "/tmp/g")
    settings.gameDirectory = nil
    #expect(SettingsModel(defaults: defaults).gameDirectory == nil)
  }

  @Test func CFG_026_resolutionOnlyAcceptsPositiveIntegers() {
    let settings = SettingsModel(defaults: freshDefaults())
    #expect(!settings.setResolution(width: 0, height: 1080))
    #expect(!settings.setResolution(width: 1920, height: -1))
    #expect(settings.resolutionWidth == 1920 && settings.resolutionHeight == 1080)
    #expect(settings.setResolution(width: 1280, height: 720))
    settings.customResolutionEnabled = true
    #expect(settings.customResolution == SettingsModel.Resolution(width: 1280, height: 720))
  }

  @Test func CFG_015_proxyIsRejectedBeforeItIsSaved() {
    let settings = SettingsModel(defaults: freshDefaults())
    for bad in ["", "localhost", "http://127.0.0.1:7890", "127.0.0.1:0", "127.0.0.1:99999", "a b:80", ":80", "host:port", "127.0.0.1:+80", "127.0.0.1:-80"] {
      #expect(!settings.setProxyHost(bad), "\(bad)")
    }
    #expect(settings.proxyHost == "")
    #expect(settings.setProxyHost(" proxy.local:8080 "))
    #expect(settings.proxyHost == "proxy.local:8080")
    #expect(settings.setProxyHost("[::1]:7890"))
  }

  @Test func CFG_014_proxyIsOnlyEffectiveWhenEnabledAndSet() {
    let settings = SettingsModel(defaults: freshDefaults())
    #expect(settings.effectiveProxy == nil)
    #expect(settings.setProxyHost("127.0.0.1:7890"))
    #expect(settings.effectiveProxy == nil)
    settings.proxyEnabled = true
    #expect(settings.effectiveProxy == "127.0.0.1:7890")
  }
}

@Suite struct CFG_010_GameDirectoryTests {
  private func makeDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appending(path: "yaagl-dir-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }

  private let supported: @Sendable (URL) -> Bool = { !$0.path.contains("\"") }

  @Test func CFG_010_emptyDirectoryIsAnInstallTarget() throws {
    let dir = try makeDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    #expect(try GameDirectoryValidator.validate(dir, gameExecutable: "YuanShen.exe", isSupportedPath: supported) == .empty)
  }

  @Test func CFG_010_interruptedInstallLeftoversStillCount() throws {
    let dir = try makeDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    try FileManager.default.createDirectory(at: dir.appending(path: ".yaagl-tmp"), withIntermediateDirectories: true)
    #expect(try GameDirectoryValidator.validate(dir, gameExecutable: "YuanShen.exe", isSupportedPath: supported) == .empty)
  }

  @Test func CFG_010_existingGameIsRecognised() throws {
    let dir = try makeDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    try Data().write(to: dir.appending(path: "YuanShen.exe"))
    #expect(try GameDirectoryValidator.validate(dir, gameExecutable: "YuanShen.exe", isSupportedPath: supported) == .existingGame)
  }

  @Test func CFG_010_otherContentIsRefused() throws {
    let dir = try makeDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    try Data().write(to: dir.appending(path: "photos.zip"))
    #expect(throws: GameDirectoryProblem.notEmpty) {
      try GameDirectoryValidator.validate(dir, gameExecutable: "YuanShen.exe", isSupportedPath: supported)
    }
  }

  @Test func CFG_010_aFolderThatCannotBeListedIsNotTreatedAsEmpty() throws {
    let dir = try makeDirectory()
    defer {
      try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir.path)
      try? FileManager.default.removeItem(at: dir)
    }
    try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: dir.path)
    #expect(throws: GameDirectoryProblem.unreadable) {
      try GameDirectoryValidator.validate(dir, gameExecutable: "YuanShen.exe", isSupportedPath: supported)
    }
  }

  @Test func CFG_010_missingOrFileOrUnsupportedPathsAreRefused() throws {
    let dir = try makeDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    #expect(throws: GameDirectoryProblem.missing) {
      try GameDirectoryValidator.validate(dir.appending(path: "nope"), gameExecutable: "x", isSupportedPath: supported)
    }
    let file = dir.appending(path: "f")
    try Data().write(to: file)
    #expect(throws: GameDirectoryProblem.notADirectory) {
      try GameDirectoryValidator.validate(file, gameExecutable: "x", isSupportedPath: supported)
    }
    let quoted = dir.appending(path: "a\"b")
    try FileManager.default.createDirectory(at: quoted, withIntermediateDirectories: true)
    #expect(throws: GameDirectoryProblem.unsupportedPath) {
      try GameDirectoryValidator.validate(quoted, gameExecutable: "x", isSupportedPath: supported)
    }
  }
}
