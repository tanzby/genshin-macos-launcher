import Foundation
import Platform
import Synchronization
import Testing
import TestSupport

@testable import Launcher

@MainActor
private func settings() -> SettingsModel {
  SettingsModel(defaults: makeTemporaryDefaults("onboard").defaults)
}

private func tempDirectory() -> URL { makeTemporaryDirectory("genshin-launcher-onb") }

@MainActor @Suite struct OnboardingModelTests {
  @Test func APP_020_autoLaunchNeverOffersTheGameFolderPickerButStillOffersHosts() {
    let model = OnboardingModel(hosts: HostsModel(FakeHosts(.current)), settings: settings(), gameDirectoryRules: .test)
    model.refresh()
    #expect(model.step == .gameDirectory)
    #expect(model.showsSheet(unattended: false))
    #expect(!model.showsSheet(unattended: true))

    let blocked = OnboardingModel(hosts: HostsModel(FakeHosts(.missing)), settings: settings(), gameDirectoryRules: .test)
    blocked.refresh()
    #expect(blocked.showsSheet(unattended: true))
  }

  @Test func WIN_011_hostsBlockIsTheFirstRequiredStep() {
    let model = OnboardingModel(hosts: HostsModel(FakeHosts(.missing)), settings: settings(), gameDirectoryRules: .test)
    model.refresh()
    #expect(model.step == .hosts)
    #expect(!model.isComplete)
    #expect(!model.allowsLaunch)
  }

  @Test func WIN_011_outdatedBlocklistCountsAsMissing() {
    let model = OnboardingModel(hosts: HostsModel(FakeHosts(.outdated)), settings: settings(), gameDirectoryRules: .test)
    model.refresh()
    #expect(model.step == .hosts)
  }

  @Test func WIN_011_applyingMovesOnToTheGameDirectory() async {
    let hosts = FakeHosts(.missing)
    let model = OnboardingModel(hosts: HostsModel(hosts), settings: settings(), gameDirectoryRules: .test)
    model.refresh()
    await model.applyHosts()
    #expect(hosts.applyCalls == 1)
    #expect(model.step == .gameDirectory)
    #expect(model.hosts.error == nil)
    #expect(model.allowsLaunch)
  }

  @Test func WIN_011_cancellingThePasswordDialogKeepsTheStepAndShowsAnError() async {
    let model = OnboardingModel(hosts: HostsModel(FakeHosts(.missing, applyError: PasswordCancelled())), settings: settings(), gameDirectoryRules: .test)
    model.refresh()
    await model.applyHosts()
    #expect(model.step == .hosts)
    #expect(model.hosts.error != nil)
    #expect(!model.hosts.isApplying)
  }

  @Test func WIN_011_unreadableHostsFileBlocksLaunch() {
    let hosts = FakeHosts(.current)
    hosts.setStatus(.failure(PasswordCancelled()))
    let model = OnboardingModel(hosts: HostsModel(hosts), settings: settings(), gameDirectoryRules: .test)
    model.refresh()
    #expect(!model.allowsLaunch)
    #expect(model.step == .hosts)
  }

  @Test func INS_001_aFolderWithOtherContentIsRefusedAndNotStored() throws {
    let settings = settings()
    let dir = tempDirectory()
    try Data().write(to: dir.appending(path: "notes.txt"))
    let model = OnboardingModel(hosts: HostsModel(FakeHosts(.current)), settings: settings, gameDirectoryRules: .test)
    #expect(throws: GameDirectoryProblem.notEmpty) { try model.chooseGameDirectory(dir) }
    #expect(settings.gameDirectory == nil)
    try Data().write(to: dir.appending(path: "Game.exe"))
    try model.chooseGameDirectory(dir)  // an existing installation
    #expect(settings.gameDirectory == dir)
  }

  @Test func INS_001_chosenGameDirectoryCompletesOnboarding() throws {
    let settings = settings()
    let dir = tempDirectory()
    let model = OnboardingModel(hosts: HostsModel(FakeHosts(.current)), settings: settings, gameDirectoryRules: .test)
    model.refresh()
    #expect(model.step == .gameDirectory)
    try model.chooseGameDirectory(dir)
    #expect(settings.gameDirectory == dir)
    #expect(model.step == .done)
    #expect(model.isComplete)
  }

  @Test func hostsStaysWatchedAfterOnboarding() {
    let hosts = FakeHosts(.current)
    let settings = settings()
    let dir = tempDirectory()
    settings.gameDirectory = dir
    let model = OnboardingModel(hosts: HostsModel(hosts), settings: settings, gameDirectoryRules: .test)
    model.refresh()
    #expect(model.isComplete)
    hosts.setStatus(.success(.outdated))
    model.refresh()
    #expect(model.step == .hosts)
    #expect(!model.allowsLaunch)
  }

  @Test func WIN_011_aLaterSuccessfulReadClearsAnEarlierReadError() {
    let hosts = FakeHosts(.current)
    hosts.setStatus(.failure(PasswordCancelled()))
    let model = OnboardingModel(hosts: HostsModel(hosts), settings: settings(), gameDirectoryRules: .test)
    model.refresh()
    #expect(model.hosts.error != nil)
    hosts.setStatus(.success(.current))
    model.refresh()
    #expect(model.hosts.error == nil)
  }

  @Test func CFG_009_aVanishedGameFolderSendsTheUserBackToThePicker() throws {
    let settings = settings()
    let dir = tempDirectory()
    settings.gameDirectory = dir
    let model = OnboardingModel(hosts: HostsModel(FakeHosts(.current)), settings: settings, gameDirectoryRules: .test)
    model.refresh()
    #expect(model.isComplete)
    try FileManager.default.removeItem(at: dir)  // the external drive went away
    model.refresh()
    #expect(model.step == .gameDirectory)
    #expect(!model.isComplete)
  }

  @Test func CFG_009_aSavedGameFolderThatBecameUnreadableSendsTheUserBackToThePicker() throws {
    let settings = settings()
    let dir = tempDirectory()
    // Readable again, so TestSupport can remove it.
    defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir.path) }
    settings.gameDirectory = dir
    let model = OnboardingModel(hosts: HostsModel(FakeHosts(.current)), settings: settings, gameDirectoryRules: .test)
    model.refresh()
    #expect(model.isComplete)
    try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: dir.path)
    model.refresh()
    #expect(model.step == .gameDirectory)
  }
}
