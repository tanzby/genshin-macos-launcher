import Foundation
import Platform
import Synchronization
import Testing
import TestSupport

@testable import Launcher

final class FakeHosts: HostsBlocking, Sendable {
  private let state: Mutex<(status: Result<HostsBlocklist.Status, any Error>, applyCalls: Int, applyError: (any Error)?)>
  init(_ status: HostsBlocklist.Status, applyError: (any Error)? = nil) {
    state = Mutex((status: .success(status), applyCalls: 0, applyError: applyError))
  }
  var applyCalls: Int { state.withLock { $0.applyCalls } }
  func setStatus(_ status: Result<HostsBlocklist.Status, any Error>) { state.withLock { $0.status = status } }
  func status() throws -> HostsBlocklist.Status { try state.withLock { try $0.status.get() } }
  func apply() async throws {
    let error = state.withLock { s -> (any Error)? in
      s.applyCalls += 1
      if s.applyError == nil { s.status = .success(.current) }
      return s.applyError
    }
    if let error { throw error }
  }
}

struct PasswordCancelled: Error {}

@MainActor
private func settings() -> SettingsModel {
  let suite = "genshin-launcher-onboard-\(UUID().uuidString)"
  let defaults = UserDefaults(suiteName: suite)!
  defaults.removePersistentDomain(forName: suite)
  return SettingsModel(defaults: defaults)
}

private func tempDirectory() -> URL { makeTemporaryDirectory("genshin-launcher-onb") }

@MainActor @Suite struct OnboardingModelTests {
  @Test func APP_020_autoLaunchNeverOffersTheGameFolderPickerButStillOffersHosts() {
    let model = OnboardingModel(hosts: FakeHosts(.current), settings: settings())
    model.refresh()
    #expect(model.step == .gameDirectory)
    #expect(model.showsSheet(unattended: false))
    #expect(!model.showsSheet(unattended: true))

    let blocked = OnboardingModel(hosts: FakeHosts(.missing), settings: settings())
    blocked.refresh()
    #expect(blocked.showsSheet(unattended: true))
  }

  @Test func WIN_011_hostsBlockIsTheFirstRequiredStep() {
    let model = OnboardingModel(hosts: FakeHosts(.missing), settings: settings())
    model.refresh()
    #expect(model.step == .hosts)
    #expect(!model.isComplete)
    #expect(!model.allowsLaunch)
  }

  @Test func WIN_011_outdatedBlocklistCountsAsMissing() {
    let model = OnboardingModel(hosts: FakeHosts(.outdated), settings: settings())
    model.refresh()
    #expect(model.step == .hosts)
  }

  @Test func WIN_011_applyingMovesOnToTheGameDirectory() async {
    let hosts = FakeHosts(.missing)
    let model = OnboardingModel(hosts: hosts, settings: settings())
    model.refresh()
    await model.applyHosts()
    #expect(hosts.applyCalls == 1)
    #expect(model.step == .gameDirectory)
    #expect(model.hostsError == nil)
    #expect(model.allowsLaunch)
  }

  @Test func WIN_011_cancellingThePasswordDialogKeepsTheStepAndShowsAnError() async {
    let model = OnboardingModel(hosts: FakeHosts(.missing, applyError: PasswordCancelled()), settings: settings())
    model.refresh()
    await model.applyHosts()
    #expect(model.step == .hosts)
    #expect(model.hostsError != nil)
    #expect(!model.isApplyingHosts)
  }

  @Test func WIN_011_unreadableHostsFileBlocksLaunch() {
    let hosts = FakeHosts(.current)
    hosts.setStatus(.failure(PasswordCancelled()))
    let model = OnboardingModel(hosts: hosts, settings: settings())
    model.refresh()
    #expect(!model.allowsLaunch)
    #expect(model.step == .hosts)
  }

  @Test func INS_001_chosenGameDirectoryCompletesOnboarding() {
    let settings = settings()
    let dir = tempDirectory()
    let model = OnboardingModel(hosts: FakeHosts(.current), settings: settings)
    model.refresh()
    #expect(model.step == .gameDirectory)
    model.useGameDirectory(dir)
    #expect(settings.gameDirectory == dir)
    #expect(model.step == .done)
    #expect(model.isComplete)
  }

  @Test func hostsStaysWatchedAfterOnboarding() {
    let hosts = FakeHosts(.current)
    let settings = settings()
    let dir = tempDirectory()
    settings.gameDirectory = dir
    let model = OnboardingModel(hosts: hosts, settings: settings)
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
    let model = OnboardingModel(hosts: hosts, settings: settings())
    model.refresh()
    #expect(model.hostsError != nil)
    hosts.setStatus(.success(.current))
    model.refresh()
    #expect(model.hostsError == nil)
  }

  @Test func CFG_009_aVanishedGameFolderSendsTheUserBackToThePicker() throws {
    let settings = settings()
    let dir = tempDirectory()
    settings.gameDirectory = dir
    let model = OnboardingModel(hosts: FakeHosts(.current), settings: settings)
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
    let model = OnboardingModel(hosts: FakeHosts(.current), settings: settings)
    model.refresh()
    #expect(model.isComplete)
    try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: dir.path)
    model.refresh()
    #expect(model.step == .gameDirectory)
  }
}
