import Foundation
import Platform
import Testing

@testable import Wine

// Game Mode host preparation (LCH-022..026). The shim and dylib are fake files; codesign and LaunchServices are
// fakes; the bundle layout, the plist and the idempotence are asserted on disk.

private let gameHostVariables = [
  "YAAGL_GAME_HOST_EXE", "YAAGL_GAME_HOST_MATCH", "YAAGL_GAME_HOST_DYLIB", "YAAGL_GAMEHOST_LOG",
]

private var helperOptions: LaunchFixtureOptions {
  var options = LaunchFixtureOptions()
  options.helpers = true
  return options
}

private func expectNoGameHostVariables(_ f: LaunchFixture, sourceLocation: SourceLocation = #_sourceLocation) {
  let environment = f.runner.gameCall?.environment ?? ["<no game run>": ""]
  for name in gameHostVariables {
    #expect(environment[name] == nil, "\(name) must not be set", sourceLocation: sourceLocation)
  }
  #expect(f.runner.gameCall != nil, "the game must still launch", sourceLocation: sourceLocation)
}

@Suite("GameSession game host", .timeLimit(.minutes(1))) struct GameHostTests {
  // MARK: LCH-026 / LCH-022

  @Test func LCH_026_gameRunGetsTheFourGameHostVariables() async throws {
    try await withLaunchFixture(helperOptions) { f in
      let helpers = try #require(f.helpers)

      let result = await f.session.launch(makeLaunchRecipe())

      #expect(result == .exited)
      let environment = try #require(f.runner.gameCall?.environment)
      #expect(environment["YAAGL_GAME_HOST_EXE"] == f.macOSWine.path)
      #expect(environment["YAAGL_GAME_HOST_MATCH"] == "YuanShen.exe")
      #expect(environment["YAAGL_GAME_HOST_DYLIB"] == helpers.dylib.path)
      #expect(environment["YAAGL_GAMEHOST_LOG"] == f.layout.logsDirectory.appending(path: "gamehost.log").path)
    }
  }

  @Test func LCH_022_gameModeIsOnForEveryLaunchWhenTheHelpersExist() async throws {
    try await withLaunchFixture(helperOptions) { f in
      _ = await f.session.launch(makeLaunchRecipe())
      let environment = try #require(f.runner.gameCall?.environment)
      #expect(Set(gameHostVariables).isSubset(of: Set(environment.keys)))
    }
  }

  // MARK: LCH-023 degradation

  @Test func LCH_023_withoutHelpersTheGameStartsWithoutGameHostVariables() async throws {
    try await withLaunchFixture { f in
      let result = await f.session.launch(makeLaunchRecipe())

      #expect(result == .exited)
      expectNoGameHostVariables(f)
      #expect(f.runner.calls(.codesign).isEmpty)
      #expect(f.services.registered.isEmpty)
    }
  }

  @Test func LCH_023_aMissingShimFileDegradesAndStillLaunches() async throws {
    try await withLaunchFixture(helperOptions) { f in
      let helpers = try #require(f.helpers)
      try FileManager.default.removeItem(at: helpers.shim)

      let result = await f.session.launch(makeLaunchRecipe())

      #expect(result == .exited)
      expectNoGameHostVariables(f)
      #expect(f.runner.calls(.codesign).isEmpty)
    }
  }

  @Test func LCH_023_aMissingDylibFileDegradesAndStillLaunches() async throws {
    try await withLaunchFixture(helperOptions) { f in
      let helpers = try #require(f.helpers)
      try FileManager.default.removeItem(at: helpers.dylib)

      let result = await f.session.launch(makeLaunchRecipe())

      #expect(result == .exited)
      expectNoGameHostVariables(f)
    }
  }

  @Test func LCH_023_aFailingCodesignDegradesAndStillLaunches() async throws {
    try await withLaunchFixture(helperOptions) { f in
      f.runner.responder.value = { call in
        call.kind == .codesign ? ProcessResult(exitCode: 1, output: "codesign: failed") : nil
      }

      let result = await f.session.launch(makeLaunchRecipe())

      #expect(result == .exited)
      #expect(f.runner.calls(.codesign).count == 1)  // positive: it was attempted
      expectNoGameHostVariables(f)
    }
  }

  @Test func LCH_023_aThrowingLaunchServicesRegistrationDegradesAndStillLaunches() async throws {
    try await withLaunchFixture(helperOptions) { f in
      f.services.failure.value = FakeFailure(message: "lsregister failed")

      let result = await f.session.launch(makeLaunchRecipe())

      #expect(result == .exited)
      #expect(f.services.registered == [f.layout.gameHostApp.path])  // positive: it was attempted
      expectNoGameHostVariables(f)
    }
  }

  // MARK: LCH-024 shim install

  @Test func LCH_024_shimReplacesTheLoaderAndTheOriginalWineHostStaysPut() async throws {
    try await withLaunchFixture(helperOptions) { f in
      let result = await f.session.launch(makeLaunchRecipe())

      #expect(result == .exited)
      #expect(launchRead(f.layout.unixWine) == LaunchBytes.shim)
      #expect(launchRead(f.layout.unixWineHost) == LaunchBytes.host)
    }
  }

  @Test func LCH_024_withoutWineHostTheLoaderIsRenamedToWineHostThenTheShimIsCopied() async throws {
    var options = helperOptions
    options.hostState = .freshNoHost
    try await withLaunchFixture(options) { f in
      let result = await f.session.launch(makeLaunchRecipe())

      #expect(result == .exited)
      #expect(launchRead(f.layout.unixWineHost) == LaunchBytes.wine)
      #expect(launchRead(f.layout.unixWine) == LaunchBytes.shim)
      // the bundle is built from wine-host, never from the shim now living at `wine`
      #expect(launchRead(f.macOSWine) == LaunchBytes.wine)
      #expect(launchRead(f.macOSDotWineHost) == LaunchBytes.wine)
    }
  }

  @Test func LCH_024_whenWineHostIsMissingAndTheLoaderIsAlreadyTheShimItDegradesWithoutRenamingTheShim() async throws {
    var options = helperOptions
    options.hostState = .shimInstalledNoHost
    try await withLaunchFixture(options) { f in
      let result = await f.session.launch(makeLaunchRecipe())

      #expect(result == .exited)
      expectNoGameHostVariables(f)
      #expect(!wineExists(f.layout.unixWineHost))
      #expect(launchRead(f.layout.unixWine) == LaunchBytes.shim)
      #expect(f.runner.calls(.codesign).isEmpty)
    }
  }

  @Test func LCH_024_aShimThatIsAlreadyInstalledIsNotRewritten() async throws {
    try await withLaunchFixture(helperOptions) { f in
      try launchWrite(LaunchBytes.shim, to: f.layout.unixWine)
      let longAgo = Date(timeIntervalSince1970: 1_000_000_000)
      try launchSetModificationDate(longAgo, of: f.layout.unixWine)

      let result = await f.session.launch(makeLaunchRecipe())

      #expect(result == .exited)
      #expect(f.runner.gameCall?.environment["YAAGL_GAME_HOST_EXE"] != nil)  // positive: game mode worked
      #expect(launchRead(f.layout.unixWine) == LaunchBytes.shim)
      #expect(launchModificationDate(f.layout.unixWine) == longAgo)
    }
  }

  // MARK: LCH-025 bundle, codesign, register

  @Test func LCH_025_bundleHoldsCopiesOfWineHostAndIsSignedWithTheBundleIdentifier() async throws {
    try await withLaunchFixture(helperOptions) { f in
      let result = await f.session.launch(makeLaunchRecipe())

      #expect(result == .exited)
      #expect(GameSession.gameHostBundleIdentifier == "io.github.tanzby.yaagl.game")
      #expect(launchRead(f.macOSWine) == LaunchBytes.host)
      #expect(launchRead(f.macOSDotWineHost) == LaunchBytes.host)
      #expect(launchRead(f.macOSWine) != LaunchBytes.shim)
      let signs = f.runner.calls(.codesign)
      #expect(signs.count == 1)
      let sign = try #require(signs.first)
      #expect(sign.executable == "/usr/bin/codesign")
      #expect(sign.arguments == ["-f", "-s", "-", "-i", "io.github.tanzby.yaagl.game", f.macOSWine.path])
    }
  }

  @Test func LCH_025_infoPlistIsAnXmlPlistWithTheGameModeKeys() async throws {
    try await withLaunchFixture(helperOptions) { f in
      let result = await f.session.launch(makeLaunchRecipe())

      #expect(result == .exited)
      let data = try #require(try? Data(contentsOf: f.infoPlist))
      #expect(String(decoding: data.prefix(5), as: UTF8.self) == "<?xml")
      let plist = try #require(
        try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any])
      #expect(plist["CFBundleExecutable"] as? String == "wine")
      #expect(plist["CFBundleIdentifier"] as? String == "io.github.tanzby.yaagl.game")
      #expect(plist["CFBundleName"] as? String == "原神")
      #expect(plist["CFBundleDisplayName"] as? String == "原神")
      #expect(plist["LSApplicationCategoryType"] as? String == "public.app-category.games")
      #expect(plist["LSSupportsGameMode"] as? Bool == true)
      #expect(plist["LSUIElement"] as? Bool == true)
      #expect(plist["NSHighResolutionCapable"] as? Bool == true)
      #expect(plist["NSPrincipalClass"] as? String == "WineApplication")
    }
  }

  @Test func LCH_025_firstLaunchRegistersTheBundleWithLaunchServicesAfterSigning() async throws {
    try await withLaunchFixture(helperOptions) { f in
      let result = await f.session.launch(makeLaunchRecipe())

      #expect(result == .exited)
      #expect(f.services.registered == [f.layout.gameHostApp.path])
      let trace = f.trace.all
      let sign = try #require(trace.firstIndex(of: "codesign"))
      let register = try #require(trace.firstIndex(of: "register"))
      let game = try #require(trace.firstIndex(of: "GAME"))
      #expect(sign < register)
      #expect(register < game)
    }
  }

  @Test func LCH_025_aSecondLaunchWithNothingChangedDoesNotSignRegisterOrRewriteThePlist() async throws {
    try await withLaunchFixture(helperOptions) { f in
      let first = await f.session.launch(makeLaunchRecipe())
      #expect(first == .exited)
      #expect(f.runner.calls(.codesign).count == 1)  // positive: the first launch did the work
      #expect(f.services.registered.count == 1)
      let longAgo = Date(timeIntervalSince1970: 1_000_000_000)
      try launchSetModificationDate(longAgo, of: f.infoPlist)

      let second = await f.session.launch(makeLaunchRecipe())

      #expect(second == .exited)
      #expect(f.runner.calls(.codesign).count == 1)
      #expect(f.services.registered.count == 1)
      #expect(launchModificationDate(f.infoPlist) == longAgo)
      #expect(f.runner.gameCalls.count == 2)
      #expect(f.runner.gameCalls.last?.environment["YAAGL_GAME_HOST_EXE"] == f.macOSWine.path)
    }
  }

  @Test func LCH_025_aChangedWineHostRebuildsTheBundleSignsAndRegistersAgain() async throws {
    try await withLaunchFixture(helperOptions) { f in
      _ = await f.session.launch(makeLaunchRecipe())
      #expect(f.runner.calls(.codesign).count == 1)
      try launchWrite("FAKE-WINE-HOST-V2", to: f.layout.unixWineHost)

      let result = await f.session.launch(makeLaunchRecipe())

      #expect(result == .exited)
      #expect(launchRead(f.macOSWine) == "FAKE-WINE-HOST-V2")
      #expect(launchRead(f.macOSDotWineHost) == "FAKE-WINE-HOST-V2")
      #expect(f.runner.calls(.codesign).count == 2)
      #expect(f.services.registered.count == 2)
    }
  }

  @Test func LCH_025_aDriftedInfoPlistIsRewrittenAndRegisteredAgainWithoutSigningAgain() async throws {
    try await withLaunchFixture(helperOptions) { f in
      _ = await f.session.launch(makeLaunchRecipe())
      #expect(f.services.registered.count == 1)
      try launchWrite("not a plist", to: f.infoPlist)

      let result = await f.session.launch(makeLaunchRecipe())

      #expect(result == .exited)
      let data = try #require(try? Data(contentsOf: f.infoPlist))
      let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any]
      #expect(plist?["CFBundleExecutable"] as? String == "wine")
      #expect(f.services.registered.count == 2)
      #expect(f.runner.calls(.codesign).count == 1)
    }
  }
}
