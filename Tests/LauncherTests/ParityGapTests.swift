import Diagnostics
import Foundation
import Testing
import Wine

@testable import Launcher

// Parity rules (docs/parity/hk4e-cn.md) whose behaviour lives in the launcher model and its small helpers.

@MainActor
@Suite struct LauncherParityTests {
  // APP-011: a game folder that no longer holds a readable game shows "install"; the saved folder stays.
  @Test func APP_011_aMovedGameShowsInstallAndKeepsTheSavedFolder() async {
    let directory = URL(filePath: "/Volumes/Gone/Genshin", directoryHint: .isDirectory)
    let fake = FakeGameClient(status: GameStatus(localVersion: nil, remoteVersion: "5.6.0"))
    let model = LauncherModel(client: fake, gameDirectory: directory)

    await model.refresh()

    #expect(model.primaryAction == .install)
    #expect(model.gameDirectory == directory)
  }

  // APP-014: an unreadable version used to be shown as "0.0.0" with an "update" button that reset the install.
  // It is now an error the status area reports, and neither launch nor update is offered.
  @Test func APP_014_aBrokenInstallationIsReportedAndOffersNeitherLaunchNorUpdate() async {
    let fake = FakeGameClient(status: GameStatus(localVersion: "5.5.0", remoteVersion: "5.6.0", canUpdate: true))
    fake.setStatusFailure(GameClientError.brokenInstallation)
    let model = LauncherModel(client: fake, gameDirectory: URL(filePath: "/Games/GI", directoryHint: .isDirectory))

    await model.refresh()
    let presentation = MainPresentation.derive(
      MainSnapshot(
        phase: model.phase, isPreDownloading: false, isPausing: false, progress: nil, pendingJob: nil,
        lastError: model.lastError, status: model.status, isOnline: true))

    #expect(model.lastError == .client(.brokenInstallation))
    #expect(presentation.status == .error(.client(.brokenInstallation)))
    #expect(presentation.button != .launch && presentation.button != .update)
  }

  // APP-016 on the model side: the primary action follows `canUpdate`, not a comparison of its own.
  @Test func APP_016_theMainButtonUpdatesOnlyWhenTheClientSaysAnUpdateIsRequired() {
    #expect(PrimaryAction.derive(GameStatus(localVersion: "5.5.0", remoteVersion: "5.6.0", canUpdate: true)) == .update)
    #expect(PrimaryAction.derive(GameStatus(localVersion: "5.6.0", remoteVersion: "5.6.0")) == .launch)
    #expect(PrimaryAction.derive(GameStatus(localVersion: "5.7.0", remoteVersion: "5.6.0")) == .launch)
  }
}

@Suite struct PathParityTests {
  // APP-004: the TS launcher built paths relative to the process directory. Every path the launcher uses is
  // absolute; a relative one from the command line is made absolute once, when it is read.
  @Test func APP_004_aRelativeCommandLinePathIsMadeAbsoluteWhenItIsRead() throws {
    let options = AutoLaunchOptions.parse(
      arguments: ["App", "--data-dir", "sandbox/data", "--game-dir", "games/GI"], environment: [:])

    let data = try #require(options.dataRoot)
    let game = try #require(options.gameDirectory)
    #expect(data.path.hasPrefix("/") && data.path.hasSuffix("/sandbox/data"))
    #expect(game.path.hasPrefix("/") && game.path.hasSuffix("/games/GI"))
    #expect(data.path == URL(filePath: "sandbox/data").absoluteURL.path)
  }

  @Test func APP_004_aTildePathIsExpandedAgainstTheHomeDirectory() throws {
    let options = AutoLaunchOptions.parse(arguments: ["App", "--game-dir", "~/Games/GI"], environment: [:])

    #expect(try #require(options.gameDirectory).path == NSHomeDirectory() + "/Games/GI")
  }

  @Test func APP_004_theWineLayoutOfARelativeRootIsAbsoluteToo() {
    let layout = WineLayout(root: URL(filePath: "relative/Genshin Launcher", directoryHint: .isDirectory))

    for url in [layout.prefixDirectory, layout.logsDirectory] {
      #expect(url.path.hasPrefix("/"))
    }
  }
}

@Suite struct BundleParityTests {
  // UPD-017: the app and the game host have their own ids (#28 A11). The host's is derived from the app's, so a
  // change of one cannot silently leave the other behind (TCC grants and LaunchServices records follow the id).
  @Test func UPD_017_theGameHostBundleIdentifierIsTheAppsPlusGame() throws {
    let appID = try AppSource.projectSetting("PRODUCT_BUNDLE_IDENTIFIER")

    #expect(appID == "io.github.tanzby.genshin-launcher")
    #expect(GameSession.gameHostBundleIdentifier == appID + ".game")
  }
}
