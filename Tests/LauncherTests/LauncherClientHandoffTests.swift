import Foundation
import Testing

@testable import Launcher

// How the model hands the game directory and the settings snapshot to the GameClient (ticket #12).

@MainActor
private func waitForLaunch(_ fake: FakeGameClient) async {
  try? await fake.nextLaunch()
}

@Suite struct LauncherClientHandoffTests {
  @MainActor
  @Test func WIN_005_theGameDirectoryReachesTheClientAtInitAndOnEveryChange() {
    let fake = FakeGameClient(status: GameStatus(localVersion: "5.6.0", remoteVersion: "5.6.0"))
    let first = URL(filePath: "/Games/A")
    let second = URL(filePath: "/Games/B")
    let model = LauncherModel(client: fake, gameDirectory: first)

    model.gameDirectory = second
    model.gameDirectory = second  // unchanged: not repeated
    model.gameDirectory = nil

    let seen = fake.gameDirectories
    #expect(seen.count == 3)
    #expect(seen[0] == first)
    #expect(seen[1] == second)
    #expect(seen[2] == nil)
  }

  @MainActor
  @Test func LCH_005_launchPassesTheSettingsSnapshotFromTheProvider() async throws {
    let fake = FakeGameClient(status: GameStatus(localVersion: "5.6.0", remoteVersion: "5.6.0"))
    let directory = FileManager.default.temporaryDirectory.appending(path: "handoff-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
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
}
