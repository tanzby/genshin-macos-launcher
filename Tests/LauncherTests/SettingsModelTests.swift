import Foundation
import Testing
import TestSupport

@testable import Launcher

@MainActor
private func freshDefaults() -> UserDefaults {
  makeTemporaryDefaults().defaults
}

@MainActor @Suite struct SettingsModelTests {
  @Test func CFG_001_defaultsAndResolutionIs1080p() {
    let settings = SettingsModel(defaults: freshDefaults())
    #expect(settings.graphicsBackend == .gptk4)
    #expect(settings.gameDirectory == nil)
    #expect(settings.retina && !settings.metalHUD && !settings.leftCommandIsControl)
    #expect(!settings.hdr && !settings.metalFX && !settings.unlockFrameRate && !settings.proxyEnabled)
    #expect(settings.customResolution == nil)
    #expect(settings.resolutionWidth == 1920 && settings.resolutionHeight == 1080)
  }

  @Test func CFG_001_changesPersistAcrossInstances() {
    let defaults = freshDefaults()
    let first = SettingsModel(defaults: defaults)
    first.graphicsBackend = .dxmt
    first.gameDirectory = URL(filePath: "/Volumes/Games/Genshin")
    first.retina = false
    first.metalHUD = true
    first.leftCommandIsControl = true
    first.hdr = true
    first.metalFX = true
    #expect(first.setResolution(width: 2560, height: 1440))
    first.customResolutionEnabled = true
    #expect(first.setProxyHost("127.0.0.1:7890"))
    first.proxyEnabled = true

    let second = SettingsModel(defaults: defaults)
    #expect(second.graphicsBackend == .dxmt)
    #expect(second.gameDirectory == URL(filePath: "/Volumes/Games/Genshin"))
    #expect(!second.retina && second.metalHUD && second.leftCommandIsControl && second.hdr && second.metalFX)
    #expect(second.customResolution == SettingsModel.Resolution(width: 2560, height: 1440))
    #expect(second.proxyEnabled)
    #expect(second.effectiveProxy == "127.0.0.1:7890")
  }

  @Test func CFG_011_metalHudPersistsAndDefaultsOff() { toggles(\.metalHUD) }
  @Test func CFG_012_retinaPersistsAndDefaultsOn() {
    let defaults = freshDefaults()
    #expect(SettingsModel(defaults: defaults).retina)
    SettingsModel(defaults: defaults).retina = false
    #expect(!SettingsModel(defaults: defaults).retina)
  }
  @Test func CFG_013_leftCommandAsControlPersistsAndDefaultsOff() { toggles(\.leftCommandIsControl) }
  @Test func CFG_021_hdrPersistsAndDefaultsOff() { toggles(\.hdr) }
  @Test func CFG_029_metalFXPersistsAndDefaultsOff() { toggles(\.metalFX) }
  @Test func CFG_019_unlockFrameRatePersistsAndDefaultsOff() { toggles(\.unlockFrameRate) }

  @Test func CFG_030_aBuildWithoutGPTKDefaultsToDXMT() {
    let defaults = freshDefaults()
    #expect(SettingsModel(defaults: defaults, defaultBackend: .dxmt).graphicsBackend == .dxmt)
    SettingsModel(defaults: defaults, defaultBackend: .dxmt).graphicsBackend = .gptk4
    #expect(SettingsModel(defaults: defaults, defaultBackend: .dxmt).graphicsBackend == .gptk4)
  }

  @Test func CFG_030_graphicsBackendPersistsAndDefaultsToGPTK4() {
    let defaults = freshDefaults()
    #expect(SettingsModel(defaults: defaults).graphicsBackend == .gptk4)
    SettingsModel(defaults: defaults).graphicsBackend = .dxmt
    #expect(defaults.string(forKey: "graphicsBackend") == "dxmt")
    #expect(SettingsModel(defaults: defaults).graphicsBackend == .dxmt)
  }

  @Test func CFG_030_launchOptionsKeepTheBackendSelectedWhenTheyWereCreated() {
    let settings = SettingsModel(defaults: freshDefaults())
    settings.graphicsBackend = .dxmt
    let options = settings.launchOptions(gameDirectory: URL(filePath: "/Games/GI"))
    settings.graphicsBackend = .gptk4

    #expect(options.graphicsBackend == .dxmt)
    #expect(settings.launchOptions(gameDirectory: URL(filePath: "/Games/GI")).graphicsBackend == .gptk4)
  }

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

  private let supported: @Sendable (URL) -> Bool = { !$0.path.contains("\"") }

  private func validate(_ dir: URL) throws -> GameDirectoryKind {
    try GameDirectoryValidator.validate(dir, gameExecutable: "YuanShen.exe", isSupportedPath: supported)
  }

  @Test func CFG_010_emptyDirectoryIsAnInstallTarget() throws {
    let dir = makeTemporaryDirectory("genshin-launcher-dir")
    #expect(try validate(dir) == .empty)
  }

  @Test func CFG_010_interruptedInstallLeftoversStillCount() throws {
    let dir = makeTemporaryDirectory("genshin-launcher-dir")
    try FileManager.default.createDirectory(at: dir.appending(path: ".genshin-launcher-tmp"), withIntermediateDirectories: true)
    #expect(try validate(dir) == .empty)
  }

  @Test func CFG_010_existingGameIsRecognised() throws {
    let dir = makeTemporaryDirectory("genshin-launcher-dir")
    try Data().write(to: dir.appending(path: "YuanShen.exe"))
    #expect(try validate(dir) == .existingGame)
  }

  @Test func CFG_010_otherContentIsRefused() throws {
    let dir = makeTemporaryDirectory("genshin-launcher-dir")
    try Data().write(to: dir.appending(path: "photos.zip"))
    #expect(throws: GameDirectoryProblem.notEmpty) {
      try validate(dir)
    }
  }

  @Test func CFG_010_aFileNamedLikeTheTempFolderIsNotIgnored() throws {
    let dir = makeTemporaryDirectory("genshin-launcher-dir")
    let tmp = dir.appending(path: PendingJobStore.directoryName)
    try Data().write(to: tmp)
    #expect(throws: GameDirectoryProblem.notEmpty) {
      try validate(dir)
    }
    try FileManager.default.removeItem(at: tmp)
    try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: false)
    #expect(try validate(dir) == .empty)
  }

  @Test func CFG_010_aFolderThatCannotBeListedIsNotTreatedAsEmpty() throws {
    let dir = makeTemporaryDirectory("genshin-launcher-dir")
    // Readable again, so TestSupport can remove it.
    defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir.path) }
    try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: dir.path)
    #expect(throws: GameDirectoryProblem.unreadable) {
      try validate(dir)
    }
  }

  @Test func CFG_010_missingOrFileOrUnsupportedPathsAreRefused() throws {
    let dir = makeTemporaryDirectory("genshin-launcher-dir")
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

  @MainActor @Test func LCH_005_launchOptionsCarryEverySettingTheGameNeeds() {
    let settings = SettingsModel(defaults: freshDefaults())
    settings.retina = true
    settings.leftCommandIsControl = true
    settings.metalHUD = true
    settings.hdr = true
    settings.metalFX = true
    settings.unlockFrameRate = true
    settings.customResolutionEnabled = true
    settings.setResolution(width: 2560, height: 1440)
    settings.proxyEnabled = true
    settings.setProxyHost("127.0.0.1:7890")

    let options = settings.launchOptions(gameDirectory: URL(filePath: "/Games/GI"))

    #expect(options.gameDirectory == URL(filePath: "/Games/GI"))
    #expect(options.retina && options.leftCommandIsControl && options.metalHUD && options.hdr && options.metalFX)
    #expect(options.unlockFrameRate)
    #expect(options.customResolution == .init(width: 2560, height: 1440))
    #expect(options.proxyHost == "127.0.0.1:7890")
  }

  @MainActor @Test func LCH_005_launchOptionsOfDefaultSettingsOnlyTurnOnRetina() {
    let options = SettingsModel(defaults: freshDefaults()).launchOptions(gameDirectory: URL(filePath: "/Games/GI"))

    #expect(options == LaunchOptions(gameDirectory: URL(filePath: "/Games/GI"), retina: true))
  }
}

// Settings that are saved the moment they change, a language that follows the system and switches that no longer
// exist (docs/parity/hk4e-cn.md, CFG-007, CFG-016, CFG-017, CFG-019).
@MainActor @Suite struct SettingsBehaviourTests {
  private func everythingOn(_ settings: SettingsModel) {
    settings.gameDirectory = URL(filePath: "/Volumes/Games/Genshin")
    settings.graphicsBackend = .dxmt
    settings.retina = true
    settings.metalHUD = true
    settings.leftCommandIsControl = true
    settings.hdr = true
    settings.metalFX = true
    settings.unlockFrameRate = true
    settings.customResolutionEnabled = true
    settings.setResolution(width: 2560, height: 1440)
    settings.setProxyHost("127.0.0.1:7890")
    settings.proxyEnabled = true
  }

  // CFG-007: the TS settings page saved nothing when it was closed. Native has no save step at all: each change
  // is in the user defaults before the window could be closed, and closing a window cannot undo it.
  @Test func CFG_007_everyChangeIsInTheUserDefaultsTheMomentItIsMade() {
    let defaults = freshDefaults()
    let settings = SettingsModel(defaults: defaults)

    settings.retina = true
    #expect(defaults.bool(forKey: "retina"))
    settings.hdr = true
    #expect(defaults.bool(forKey: "hdr"))
    settings.setProxyHost("127.0.0.1:7890")
    #expect(defaults.string(forKey: "proxyHost") == "127.0.0.1:7890")
    settings.gameDirectory = URL(filePath: "/Games/GI")
    #expect(defaults.string(forKey: "gameDirectory") == "/Games/GI")
  }

  /// The keys this app itself wrote into a private defaults domain.
  private func storedKeys(afterEverythingOn body: (SettingsModel) -> Void) -> Set<String> {
    let (defaults, suite) = makeTemporaryDefaults()
    body(SettingsModel(defaults: defaults))
    return Set(defaults.persistentDomain(forName: suite)?.keys.map { $0 } ?? [])
  }

  // CFG-016 / CFG-017: the interface language is the system's (#28 A10). No language is stored, so there is
  // nothing for a first run to pin and nothing a later system change could disagree with.
  @Test func CFG_016_CFG_017_noLanguageIsEverStored() {
    let keys = storedKeys(afterEverythingOn: everythingOn)

    #expect(!keys.isEmpty)
    #expect(keys.allSatisfy { key in !["locale", "language", "lang"].contains { key.lowercased().contains($0) } })
  }

  // CFG-019: the TS launcher's FPS settings (target value, hotkeys) stay gone; only the 120 FPS switch exists.
  @Test func CFG_019_theOnlyFrameRateSettingIsTheUnlockSwitch() {
    let keys = storedKeys(afterEverythingOn: everythingOn)

    #expect(keys.contains("unlockFrameRate"))
    #expect(keys.allSatisfy { !$0.lowercased().contains("fps") })
  }
}
