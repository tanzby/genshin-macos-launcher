import Foundation
import Testing

@testable import Launcher

// How the model hands the game directory and the settings snapshot to the GameClient (ticket #12).

@MainActor
@Suite struct LauncherClientHandoffTests {
  private let installed = GameStatus(localVersion: "5.6.0", remoteVersion: "5.6.0")

  @Test func WIN_005_theGameDirectoryReachesTheClientAtInitAndOnEveryChange() async {
    let fake = FakeGameClient(status: installed)
    let first = URL(filePath: "/Games/A")
    let model = LauncherModel(client: fake, gameDirectory: first)

    model.gameDirectory = URL(filePath: "/Games/B")
    model.gameDirectory = URL(filePath: "/Games/B")  // unchanged: not repeated
    model.gameDirectory = nil

    #expect(fake.gameDirectories == [first, URL(filePath: "/Games/B"), nil])
  }

  @Test func LCH_005_launchPassesTheSettingsSnapshotFromTheProvider() async throws {
    let fake = FakeGameClient(status: installed)
    let directory = FileManager.default.temporaryDirectory.appending(path: "handoff-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let model = LauncherModel(client: fake, gameDirectory: directory)
    model.makeLaunchOptions = { LaunchOptions(gameDirectory: $0, retina: true, hdr: true, proxyHost: "127.0.0.1:7890") }
    await model.refresh()

    try await model.launch()
    try await fake.nextLaunch()

    let options = try #require(fake.launchOptions.first)
    #expect(options.gameDirectory == directory)
    #expect(options.retina && options.hdr && !options.metalFX)
    #expect(options.proxyHost == "127.0.0.1:7890")
    fake.finishLaunch(.exited)
    await model.waitUntilIdle()
  }
}
