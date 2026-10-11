import Foundation
import Platform
import Testing

@testable import Wine

// GameSession.openCommandPrompt: an interactive `wine cmd` in the game's prefix (CFG-032, WIN-022).

@Suite("GameSession command prompt", .timeLimit(.minutes(1))) struct CommandPromptTests {
  @Test func WIN_022_runsWineCmdInThePrefixWithTheGameEnvironment() async throws {
    try await withLaunchFixture { f in
      let recipe = makeLaunchRecipe(environment: ["DXMT_CONFIG": "x=1", "EMPTY": ""])
      let gameDirectory = URL(filePath: "/Games/Genshin Impact Game", directoryHint: .isDirectory)

      let code = await f.session.openCommandPrompt(recipe, gameDirectory: gameDirectory)

      #expect(code == 0)
      let call = try #require(f.runner.calls.first)
      #expect(f.runner.calls.count == 1)
      #expect(call.executable == f.layout.loader.path)
      #expect(call.arguments == ["start", "/wait", "cmd"])
      #expect(call.workingDirectory == f.layout.root.path)
      #expect(call.environment["WINEPREFIX"] == f.layout.prefixDirectory.path)
      #expect(call.environment["WINEDEBUG"] == "fixme-all,err-unwind,+timestamp")
      #expect(call.environment["DXMT_CONFIG"] == "x=1")
      #expect(call.environment["EMPTY"] == nil)
      #expect(call.environment["WINEPATH"] == #"Z:\Games\Genshin Impact Game"#)
    }
  }

  @Test func WIN_022_withoutGameDirectoryNoWinePathIsSet() async throws {
    try await withLaunchFixture { f in
      _ = await f.session.openCommandPrompt(makeLaunchRecipe(), gameDirectory: nil)
      #expect(f.runner.calls.first?.environment["WINEPATH"] == nil)
    }
  }

  @Test func WIN_022_doesNotTouchRegistryJournalOrConfigBatch() async throws {
    try await withLaunchFixture { f in
      _ = await f.session.openCommandPrompt(makeLaunchRecipe(registry: [LaunchRegistry.widthEdit(2560)]), gameDirectory: nil)
      #expect(!FileManager.default.fileExists(atPath: f.layout.launchJournal.path))
      #expect(!FileManager.default.fileExists(atPath: f.layout.configBatch.path))
      #expect(f.runner.calls.allSatisfy { $0.arguments == ["start", "/wait", "cmd"] })
    }
  }

  @Test func WIN_022_failureToStartReturnsNil() async throws {
    try await withLaunchFixture { f in
      f.runner.responder.value = { _ in throw FakeFailure() }
      #expect(await f.session.openCommandPrompt(makeLaunchRecipe(), gameDirectory: nil) == nil)
    }
  }
}
