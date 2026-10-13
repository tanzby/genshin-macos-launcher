import Foundation
import Platform
import Testing
import TestSupport

@testable import Launcher

// The launcher is the one place that decides whether an action may run now (`refusal(for:)`); `start`, `launch`,
// `resume` and `prepareWine` guard through it, and a refused start lands in `lastError`.

@MainActor
private func makeModel(
  status: GameStatus = GameStatus(localVersion: "5.0.0", remoteVersion: "5.0.0"),
  hosts: FakeHosts = FakeHosts(.current), gameDirectory: URL? = temporaryURL("LauncherAvailability")
) async -> (LauncherModel, FakeGameClient, FakeHosts) {
  let fake = FakeGameClient(status: status)
  let model = LauncherModel(client: fake, hosts: hosts, gameDirectory: gameDirectory, chunkTempMargin: 0)
  await model.refresh()
  return (model, fake, hosts)
}

@MainActor @Suite struct LauncherAvailabilityTests {
  @Test func WIN_011_launchIsRefusedWithoutTheHostsBlocklist() async {
    let (model, fake, _) = await makeModel(hosts: FakeHosts(.missing))
    #expect(model.refusal(for: .launch) == .hostsRequired)
    await #expect(throws: LauncherError.hostsRequired) { try await model.launch() }
    #expect(fake.launchOptions.isEmpty)
    #expect(model.lastError == .hostsRequired)
  }

  @Test func WIN_011_anOutdatedBlocklistIsRefusedToo() async {
    let (model, _, _) = await makeModel(hosts: FakeHosts(.outdated))
    #expect(model.refusal(for: .launch) == .hostsRequired)
  }

  @Test func WIN_011_launchLooksAtHostsAgainRightBeforeStarting() async throws {
    let (model, fake, hosts) = await makeModel()
    #expect(model.refusal(for: .launch) == nil)
    hosts.setStatus(.success(.missing))  // /etc/hosts changed after the last refresh
    await #expect(throws: LauncherError.hostsRequired) { try await model.launch() }
    #expect(fake.launchOptions.isEmpty)
    hosts.setStatus(.success(.current))
    try await model.launch()
    try await fake.nextLaunch()
    await model.shutdown()
  }

  @Test func WIN_011_anUnreadableHostsFileCountsAsMissing() async {
    let hosts = FakeHosts(.current)
    hosts.setStatus(.failure(PasswordCancelled()))
    let (model, _, _) = await makeModel(hosts: hosts)
    #expect(model.refusal(for: .launch) == .hostsRequired)
  }

  @Test func WIN_011_aLauncherWithoutAHostsSeamHasNoHostsRule() async {
    let fake = FakeGameClient(status: GameStatus(localVersion: "5.0.0", remoteVersion: "5.0.0"))
    let model = LauncherModel(client: fake, gameDirectory: temporaryURL("LauncherAvailability"))
    await model.refresh()
    #expect(model.refusal(for: .launch) == nil)
  }

  @Test func WIN_011_refreshingHostsAfterTheApplyLiftsTheRefusalAndItsError() async {
    let (model, _, hosts) = await makeModel(hosts: FakeHosts(.missing))
    await #expect(throws: LauncherError.hostsRequired) { try await model.launch() }
    try? await hosts.apply()
    model.refreshHosts()
    #expect(model.refusal(for: .launch) == nil)
    #expect(model.lastError == nil)
  }

  @Test func APP_010_repairIsRefusedOffline() async {
    let (model, fake, _) = await makeModel(status: GameStatus(localVersion: "5.0.0", remoteVersion: nil))
    #expect(!model.isOnline)
    #expect(model.refusal(for: .start(.repair)) == .offline)
    await #expect(throws: LauncherError.offline) { try await model.start(.repair) }
    #expect(fake.runs.isEmpty)
    #expect(model.lastError == .offline)
  }

  @Test func APP_010_preDownloadIsRefusedOffline() async {
    let (model, fake, _) = await makeModel(
      status: GameStatus(localVersion: "5.0.0", remoteVersion: nil, canPreDownload: true))
    #expect(model.refusal(for: .start(.preDownload)) == .offline)
    await #expect(throws: LauncherError.offline) { try await model.start(.preDownload) }
    #expect(fake.runs.isEmpty)
  }

  @Test func APP_010_launchIsRefusedOffline() async {
    let (model, _, _) = await makeModel(status: GameStatus(localVersion: "5.0.0", remoteVersion: nil))
    #expect(model.refusal(for: .launch) == .offline)
  }

  @Test func APP_017_theAnswerNamesTheFirstReasonForEachAction() async {
    let update = GameStatus(localVersion: "4.9.0", remoteVersion: "5.0.0", canUpdate: true)
    let (outdated, _, _) = await makeModel(status: update)
    #expect(outdated.refusal(for: .launch) == .updateRequired)
    #expect(outdated.refusal(for: .start(.repair)) == .updateRequired)
    #expect(outdated.refusal(for: .start(.update)) == nil)

    let (fresh, _, _) = await makeModel(status: GameStatus(localVersion: nil, remoteVersion: "5.0.0"))
    #expect(fresh.refusal(for: .launch) == .notInstalled)
    #expect(fresh.refusal(for: .start(.repair)) == .notInstalled)
    #expect(fresh.refusal(for: .start(.install)) == nil)

    let (homeless, _, _) = await makeModel(gameDirectory: nil)
    #expect(homeless.refusal(for: .launch) == .noGameDirectory)
    #expect(homeless.refusal(for: .start(.repair)) == .noGameDirectory)

    let (current, _, _) = await makeModel()
    #expect(current.refusal(for: .start(.preDownload)) == .preDownloadUnavailable)
    #expect(current.refusal(for: .start(.repair)) == nil)
    #expect(current.refusal(for: .resume) == nil, "nothing to continue is not a refusal")
  }

  @Test func APP_015_launchIsRefusedWhileAnUnfinishedJobBlocksIt() async throws {
    let (model, fake, _) = await makeModel(status: GameStatus(localVersion: nil, remoteVersion: "5.0.0"))
    try await model.start(.install)
    _ = try await fake.nextRun()
    #expect(model.refusal(for: .launch) == .busy)
    #expect(model.refusal(for: .start(.repair)) == .busy)
    await model.pause()
    fake.setStatus(GameStatus(localVersion: "5.0.0", remoteVersion: "5.0.0"))
    await model.refresh()
    #expect(model.refusal(for: .launch) == .pendingJob(.install))
    #expect(model.refusal(for: .start(.repair)) == .pendingJob(.install))
    #expect(model.refusal(for: .resume) == nil)
    await model.shutdown()
  }

  @Test func APP_013_aRefusedStartIsTheLastErrorAndTheNextGoodStartClearsIt() async throws {
    let (model, fake, _) = await makeModel(status: GameStatus(localVersion: nil, remoteVersion: "5.0.0"))
    await #expect(throws: LauncherError.notInstalled) { try await model.start(.repair) }
    #expect(model.lastError == .notInstalled)
    try await model.start(.install)
    #expect(model.lastError == nil)
    _ = try await fake.nextRun()
    await model.shutdown()
  }

  @Test func INS_004_aFailedDiskSpacePreflightGoesToTheSameChannel() async {
    let fake = FakeGameClient(status: GameStatus(localVersion: nil, remoteVersion: "5.0.0"))
    fake.setRequiredDiskSpace(10 << 30, for: .install)
    let model = LauncherModel(
      client: fake, gameDirectory: temporaryURL("LauncherAvailability"), availableDiskSpace: { _ in 1 << 30 })
    await model.refresh()
    await #expect(throws: LauncherError.self) { try await model.start(.install) }
    guard case .insufficientDiskSpace = model.lastError else {
      Issue.record("expected insufficientDiskSpace, got \(String(describing: model.lastError))")
      return
    }
  }
}
