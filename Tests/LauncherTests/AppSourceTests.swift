import Foundation
import Testing
import TestSupport

@testable import Launcher

/// Reads the files of the SwiftUI app and the project, like `StringCatalogTests` reads the string catalog. The
/// views cannot be built in `swift test`, so rules that are only about what a window offers are checked on its
/// source: the structure it declares, not how it looks.
enum AppSource {
  static let root = URL(filePath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

  static func text(_ path: String) throws -> String {
    try String(contentsOf: root.appending(path: path), encoding: .utf8)
  }

  /// The value of the first `KEY: value` line of `project.yml`, without quotes.
  static func projectSetting(_ key: String) throws -> String {
    let line = try text("project.yml").split(separator: "\n").first { $0.trimmingCharacters(in: .whitespaces).hasPrefix("\(key):") }
    let value = try #require(line).split(separator: ":", maxSplits: 1)[1]
    return value.trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: "\"")))
  }

  /// The position of `needle` in `text`, to compare the order things are declared in.
  static func position(of needle: String, in text: String) throws -> Int {
    let range = try #require(text.range(of: needle), "\(needle) is missing")
    return text.distance(from: text.startIndex, to: range.lowerBound)
  }
}

@MainActor private final class RetinaSwitch {
  var value = false
}

@Suite struct SettingsWindowStructureTests {
  private let settings = Result { try AppSource.text("App/Views/SettingsView.swift") }

  // CFG-004 / APP-018: the TS launcher hid the settings button before the first install and disabled it while
  // the queue was busy. The native Settings window is always reachable: the "⋯" menu entry is never disabled and
  // a Settings scene is declared (⌘,). Nothing needs locking, because a launch works on a snapshot of the settings.
  @Test func CFG_004_APP_018_settingsAreReachableInEveryState() throws {
    let capsule = try AppSource.text("App/Views/CapsuleView.swift")
    let lines = capsule.split(separator: "\n", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
    let entry = try #require(lines.firstIndex { $0.hasPrefix(#"Button("Settings…")"#) })

    #expect(!lines[entry].contains(".disabled"))
    #expect(!lines[entry + 1].hasPrefix(".disabled"))
    #expect(try AppSource.text("App/GenshinLauncherApp.swift").contains("Settings {"))
  }

  @MainActor @Test func APP_018_aSettingChangedWhileTheGameRunsOnlyAffectsTheNextLaunch() async throws {
    let fake = FakeGameClient(status: GameStatus(localVersion: "5.6.0", remoteVersion: "5.6.0"))
    let directory = makeTemporaryDirectory("settings")
    let model = LauncherModel(client: fake, gameDirectory: directory)
    let retina = RetinaSwitch()
    model.makeLaunchOptions = { LaunchOptions(gameDirectory: $0, retina: retina.value) }
    await model.refresh()

    try await model.launch()
    try await fake.nextLaunch()
    retina.value = true

    #expect(fake.launchOptions.map(\.retina) == [false])
    fake.finishLaunch(.exited)
    await model.waitUntilIdle()
  }

  // CFG-005: a sidebar of pages, not the TS modal's tabs. FPS unlock and ReShade are gone with the "Advanced" tab
  // they lived on, and the licenses are listed on the Advanced page.
  @Test func CFG_005_theSettingsWindowHasASidebarOfFourPages() throws {
    let source = try settings.get()

    #expect(source.contains("case general, game, wine, advanced"))
    #expect(source.contains("NavigationSplitView"))
    #expect(source.contains("List(Page.allCases"))
    #expect(!source.contains("ReShade") && !source.lowercased().contains("fps"))
  }

  // CFG-030: the Game page holds HDR, MetalFX and the custom resolution. Steam patch, Timeout Fix and Game Mode
  // are always on and have no switch (#28 A9); the page says so instead.
  @Test func CFG_030_theGamePageListsHdrMetalFxAndTheCustomResolutionInOrder() throws {
    let source = try settings.get()
    let game = String(try #require(source.components(separatedBy: "private struct GamePage").last?
      .components(separatedBy: "private struct WinePage").first))

    let hdr = try AppSource.position(of: #"Toggle("HDR""#, in: game)
    let metalFX = try AppSource.position(of: #"Toggle("MetalFX upscaling""#, in: game)
    let resolution = try AppSource.position(of: #"Toggle("Custom resolution""#, in: game)
    #expect(hdr < metalFX && metalFX < resolution)
    #expect(!game.contains(#"Toggle("Steam"#) && !game.contains(#"Toggle("Timeout"#) && !game.contains(#"Toggle("Game Mode"#))
    #expect(game.contains("Native full screen and Game Mode are always on."))
  }

  // CFG-008: the Wine page shows the pinned versions and offers no choice, so there is no "switch version"
  // confirmation, no relaunch and no surprise prefix rebuild (see the Wine tests for what a mismatch does).
  @Test func CFG_008_theWinePageShowsThePinnedVersionAndOffersNoChoice() throws {
    let source = try settings.get()
    let wine = String(try #require(source.components(separatedBy: "private struct WinePage").last?
      .components(separatedBy: "private struct AdvancedPage").first))

    #expect(wine.contains(#"LabeledContent("Wine", value: WineRuntime.pinnedVersion)"#))
    #expect(!wine.contains("Picker"))
  }

  // CFG-018: the launcher version (and build) is shown on the General page, read from the bundle.
  @Test func CFG_018_theGeneralPageShowsTheBundleVersionAndBuild() throws {
    let source = try settings.get()

    #expect(source.contains(#"LabeledContent("Version", value: Bundle.main.versionString)"#))
    #expect(source.contains("CFBundleShortVersionString") && source.contains("CFBundleVersion"))
    #expect(try AppSource.projectSetting("MARKETING_VERSION").isEmpty == false)
  }

  // CFG-032: the folders and the Wine prompt can be opened from the settings and the "⋯" menu.
  @Test func CFG_032_theFoldersAndTheWinePromptAreOneClickAway() throws {
    let source = try settings.get()
    let capsule = try AppSource.text("App/Views/CapsuleView.swift")

    #expect(source.contains(#"Button("Show in Finder")"#))  // the game folder
    #expect(source.contains(#"Button("Show Data Folder in Finder")"#))
    #expect(source.contains(#"Button("Show Logs in Finder")"#))
    #expect(source.contains(#"Button("Open Wine Command Prompt")"#))
    #expect(capsule.contains(#"Button("Open Game Folder")"#))
    #expect(capsule.contains(#"Button("Open Wine Command Prompt")"#))
  }

  // CFG-034: the notices of the Valve files the Steam patch copies stay in the app and in the repository.
  @Test func CFG_034_theValveLicensesAreListedInTheAppAndShippedWithTheFiles() throws {
    let credits = try AppSource.text("App/Credits.swift")
    let notices = try AppSource.text("THIRD_PARTY_NOTICES.md")

    #expect(credits.contains("Proton steam_helper (Valve)") && credits.contains("BSD-3-Clause"))
    #expect(credits.contains("Proton lsteamclient (Valve)"))
    #expect(try settings.get().contains("Credits.components"))
    #expect(notices.contains("steam_helper") && notices.contains("lsteamclient") && notices.contains("Valve"))
    for file in ["LICENSE.proton", "LICENSE.lsteamclient"] {
      #expect(FileManager.default.fileExists(atPath: AppSource.root.appending(path: "Resources/protonextras/\(file)").path))
    }
  }

  // CFG-016 / CFG-017: the language follows the system (#28 A10): English is the development language, the
  // catalog has zh-Hans, and no picker for a language exists.
  @Test func CFG_016_CFG_017_noLanguagePickerAndEnglishIsTheDevelopmentLanguage() throws {
    #expect(try AppSource.projectSetting("developmentLanguage") == "en")
    #expect(!(try settings.get().lowercased().contains("language")))
    #expect(try AppSource.text("App/Localizable.xcstrings").contains(#""zh-Hans""#))
  }
}

@Suite struct ProjectParityTests {
  // UPD-017: Info.plist is generated from the project settings. The app needs macOS 26, and App Transport
  // Security stays on: the TS Info.plist allowed any HTTP load.
  @Test func UPD_017_theBundleRequiresMacOS26AndDoesNotAllowArbitraryHttp() throws {
    let project = try AppSource.text("project.yml")

    #expect(try AppSource.projectSetting("INFOPLIST_KEY_LSMinimumSystemVersion") == "26.0")
    #expect(!project.contains("NSAllowsArbitraryLoads") && !project.contains("NSAppTransportSecurity"))
  }

  // UPD-016: the proxy is the game's. It is written into the game's environment by the launch recipe and
  // nowhere else: the launcher's own downloads (Wine, DXMT, Sophon, background image) never read it.
  @Test func UPD_016_onlyTheLaunchRecipeMentionsAProxy() throws {
    let sources = AppSource.root.appending(path: "Sources")
    let files = try #require(FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil))
    var mentioning: [String] = []
    for case let file as URL in files where file.pathExtension == "swift" {
      let text = try String(contentsOf: file, encoding: .utf8)
      if text.contains("HTTP_PROXY") || text.contains("connectionProxyDictionary") || text.contains("kCFNetworkProxies") {
        mentioning.append(file.lastPathComponent)
      }
    }

    #expect(mentioning == ["GenshinLaunchRecipe.swift"])
  }
}
