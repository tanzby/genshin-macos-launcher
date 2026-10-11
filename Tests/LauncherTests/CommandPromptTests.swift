import Foundation
import Testing
import Wine

@testable import Launcher

// CFG-032 / WIN-022: the "Open Wine Command Prompt" entry of the launcher model.

@MainActor
@Suite struct LauncherCommandPromptTests {
  private let directory = URL(filePath: "/Games/Genshin", directoryHint: .isDirectory)

  @Test func WIN_022_opensThePromptWithTheLaunchOptionsOfTheGameDirectory() async {
    let fake = FakeGameClient()
    let model = LauncherModel(client: fake, gameDirectory: directory)
    model.makeLaunchOptions = { LaunchOptions(gameDirectory: $0, metalHUD: true) }

    #expect(model.canOpenWineCommandPrompt)
    await model.openWineCommandPrompt()

    #expect(fake.commandPrompts == [LaunchOptions(gameDirectory: directory, metalHUD: true)])
  }

  @Test func WIN_022_withoutGameDirectoryNothingOpens() async {
    let fake = FakeGameClient()
    let model = LauncherModel(client: fake, gameDirectory: nil)

    #expect(!model.canOpenWineCommandPrompt)
    await model.openWineCommandPrompt()

    #expect(fake.commandPrompts.isEmpty)
  }

  @Test func WIN_022_untilWineIsReadyNothingOpens() async {
    let fake = FakeGameClient()
    let model = LauncherModel(client: fake, wine: FakeWinePreparer(status: .ready), gameDirectory: directory)

    #expect(!model.canOpenWineCommandPrompt, "the Wine status has not been read yet")
    await model.openWineCommandPrompt()
    #expect(fake.commandPrompts.isEmpty)

    await model.refreshWine()
    #expect(model.canOpenWineCommandPrompt)
  }
}
