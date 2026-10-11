import Foundation
import Testing
import TestSupport

@testable import Launcher

// How the model hands the game directory and the settings snapshot to the GameClient (ticket #12).

@MainActor
private func waitForLaunch(_ fake: FakeGameClient) async {
  try? await fake.nextLaunch()
}

@Suite struct LauncherClientHandoffTests {
  @MainActor
  @Test func WIN_005_theCurrentGameDirectoryReachesTheClientBeforeEveryRefreshStartAndLaunch() async throws {
    let fake = FakeGameClient(status: GameStatus(localVersion: "5.6.0", remoteVersion: "5.6.0"))
    let first = makeTemporaryDirectory("handoff")
    let second = URL(filePath: "/Games/B")
    let model = LauncherModel(client: fake, gameDirectory: first)

    await model.refresh()
    model.gameDirectory = second
    await model.refresh()
    model.gameDirectory = nil
    await model.refresh()

    let seen = fake.gameDirectories
    #expect(seen.count == 3)
    #expect(seen[0] == first)
    #expect(seen[1] == second)
    #expect(seen[2] == nil)
  }

  @MainActor
  @Test func LCH_005_launchPassesTheSettingsSnapshotFromTheProvider() async throws {
    let fake = FakeGameClient(status: GameStatus(localVersion: "5.6.0", remoteVersion: "5.6.0"))
    let directory = makeTemporaryDirectory("handoff")
    let model = LauncherModel(client: fake, gameDirectory: directory)
    model.makeLaunchOptions = { LaunchOptions(gameDirectory: $0, retina: true, hdr: true, proxyHost: "127.0.0.1:7890") }
    await model.refresh()

    try await model.launch()
    await waitForLaunch(fake)

    let options = fake.launchOptions
    #expect(options.count == 1)
    #expect(options[0].gameDirectory == directory)
    #expect(options[0].retina)
    #expect(options[0].hdr)
    #expect(!options[0].metalFX)
    #expect(options[0].proxyHost == "127.0.0.1:7890")
    fake.finishLaunch(.exited)
    await model.waitUntilIdle()
  }

  @MainActor
  @Test func WIN_005_aRejectedStartDoesNotRepointTheClientAwayFromTheRunningJob() async throws {
    let fake = FakeGameClient(status: GameStatus(localVersion: "4.9.0", remoteVersion: "5.0.0", canUpdate: true))
    let running = makeTemporaryDirectory("handoff")
    let model = LauncherModel(client: fake, gameDirectory: running)
    await model.refresh()
    try await model.start(.update)
    let run = try await fake.nextRun()

    model.gameDirectory = URL(filePath: "/Games/B")
    await #expect(throws: LauncherError.busy) { try await model.start(.update) }

    #expect(fake.gameDirectories.last == running)
    fake.finish(run: run)
    await model.waitUntilIdle()
  }

  @MainActor
  @Test func UPG_005_refreshSurfacesABrokenInstallationButNotAnOfflineClient() async {
    let fake = FakeGameClient(status: GameStatus(localVersion: "5.0.0", remoteVersion: "5.0.0"))
    let model = LauncherModel(client: fake)
    fake.setStatusFailure(GameClientError.network)
    await model.refresh()
    #expect(model.lastError == nil)

    fake.setStatusFailure(GameClientError.brokenInstallation)
    await model.refresh()
    #expect(model.lastError == .client(.brokenInstallation))
  }

  @MainActor
  @Test func APP_010_aSlowRefreshDoesNotOverwriteANewerOne() async {
    let fake = FakeGameClient(status: GameStatus(localVersion: "5.0.0", remoteVersion: "5.0.0"))
    let model = LauncherModel(client: fake)
    fake.stallsStatus.withLock { $0 = true }
    let slow = Task { await model.refresh() }
    await fake.statusQueries.pop()
    fake.stallsStatus.withLock { $0 = false }
    fake.setStatus(GameStatus(localVersion: "5.1.0", remoteVersion: "5.1.0"))
    await model.refresh()
    #expect(model.status?.localVersion == "5.1.0")

    fake.statusGate.push(())
    await slow.value

    #expect(model.status?.localVersion == "5.1.0")
  }

  @MainActor
  @Test func UPG_005_aSuccessfulRefreshClearsTheErrorTheLastRefreshLeft() async {
    let fake = FakeGameClient(status: GameStatus(localVersion: "5.0.0", remoteVersion: "5.0.0"))
    let model = LauncherModel(client: fake)
    fake.setStatusFailure(GameClientError.brokenInstallation)
    await model.refresh()
    #expect(model.lastError == .client(.brokenInstallation))

    fake.setStatus(GameStatus(localVersion: "5.0.0", remoteVersion: "5.0.0"))
    await model.refresh()

    #expect(model.lastError == nil)
  }

  @MainActor
  @Test func PRG_006_pauseWaitsForTheClientToQuiesceAfterTheJobStream() async throws {
    let fake = FakeGameClient(status: GameStatus(localVersion: "4.9.0", remoteVersion: "5.0.0", canUpdate: true))
    let directory = makeTemporaryDirectory("handoff")
    let model = LauncherModel(client: fake, gameDirectory: directory)
    await model.refresh()
    try await model.start(.update)
    _ = try await fake.nextRun()

    await model.pause()

    #expect(fake.quiesces >= 1)
  }

  @MainActor
  @Test func INS_015_aPreDownloadRecordsThePreDownloadVersionAsItsTarget() async throws {
    let fake = FakeGameClient(
      status: GameStatus(
        localVersion: "5.0.0", remoteVersion: "5.0.0", canPreDownload: true, preDownloadVersion: "5.1.0"))
    let directory = makeTemporaryDirectory("handoff")
    let model = LauncherModel(client: fake, gameDirectory: directory)
    await model.refresh()
    try await model.start(.preDownload)
    let run = try await fake.nextRun()

    #expect(PendingJobStore(gameDirectory: directory).load()?.targetVersion == "5.1.0")
    fake.finish(run: run)
    await model.waitUntilIdle()
  }
}
