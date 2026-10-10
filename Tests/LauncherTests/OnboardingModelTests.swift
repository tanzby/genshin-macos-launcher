import Foundation
import Platform
import Synchronization
import Testing

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
  let suite = "yaagl-onboard-\(UUID().uuidString)"
  let defaults = UserDefaults(suiteName: suite)!
  defaults.removePersistentDomain(forName: suite)
  return SettingsModel(defaults: defaults)
}

@MainActor @Suite struct OnboardingModelTests {
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
    let model = OnboardingModel(hosts: FakeHosts(.current), settings: settings)
    model.refresh()
    #expect(model.step == .gameDirectory)
    model.useGameDirectory(URL(filePath: "/Volumes/Games/Genshin"))
    #expect(settings.gameDirectory == URL(filePath: "/Volumes/Games/Genshin"))
    #expect(model.step == .done)
    #expect(model.isComplete)
  }

  @Test func hostsStaysWatchedAfterOnboarding() {
    let hosts = FakeHosts(.current)
    let settings = settings()
    settings.gameDirectory = URL(filePath: "/g")
    let model = OnboardingModel(hosts: hosts, settings: settings)
    model.refresh()
    #expect(model.isComplete)
    hosts.setStatus(.success(.outdated))
    model.refresh()
    #expect(model.step == .hosts)
    #expect(!model.allowsLaunch)
  }
}
