import Foundation
import Launcher
import Testing
import Wine

@testable import GenshinCN

// GenshinLaunchRecipe.make is a pure function; every expectation is a literal. Rule IDs refer to
// docs/parity/hk4e-cn.md.

private let miHoYoKey = #"HKCU\Software\miHoYo\原神"#
private let macDriverKey = #"HKCU\Software\Wine\Mac Driver"#
private let hdrName = "WINDOWS_HDR_ON_h3132281285"
private let fullscreenName = "Screenmanager Is Fullscreen mode_h3981298716"
private let widthName = "Screenmanager Resolution Width_h182942802"
private let heightName = "Screenmanager Resolution Height_h2627697771"

private let defaultGameDirectory = URL(filePath: "/Games/GI", directoryHint: .isDirectory)
private let dataDirectory = URL(filePath: "/Users/test/Library/Application Support/Genshin Launcher", directoryHint: .isDirectory)
private let protonExtras = URL(filePath: "/Users/test/Library/Application Support/Genshin Launcher/sidecar/protonextras", directoryHint: .isDirectory)

/// Launch options in `defaultGameDirectory`.
private func settings(
  graphicsBackend: GraphicsBackend = .dxmt,
  retina: Bool = false, leftCommandIsControl: Bool = false, metalHUD: Bool = false, hdr: Bool = false,
  metalFX: Bool = false, unlockFrameRate: Bool = false, customResolution: LaunchOptions.Resolution? = nil,
  proxyHost: String? = nil
) -> LaunchOptions {
  LaunchOptions(
    gameDirectory: defaultGameDirectory, graphicsBackend: graphicsBackend, retina: retina, leftCommandIsControl: leftCommandIsControl,
    metalHUD: metalHUD, hdr: hdr, metalFX: metalFX, unlockFrameRate: unlockFrameRate, customResolution: customResolution,
    proxyHost: proxyHost)
}

private func make(_ options: LaunchOptions = settings(), gameDirectory: URL = defaultGameDirectory) -> LaunchRecipe {
  var options = options
  options.gameDirectory = gameDirectory
  return GenshinLaunchRecipe.make(options: options, dataDirectory: dataDirectory, protonExtras: protonExtras)
}

private func edits(_ recipe: LaunchRecipe, key: String) -> [RegistryEdit] {
  recipe.registry.filter { $0.key == key }
}

@Suite("GenshinLaunchRecipe environment") struct GenshinLaunchRecipeEnvironmentTests {
  @Test func LCH_033_defaultSettingsGiveExactlyTheFixedEnvironment() {
    let recipe = make()

    #expect(
      recipe.environment == [
        "WINE_ENABLE_TIMEOUT_FIX": "1",
        "WINEESYNC": "1",
        "DXMT_LOG_PATH": "/Users/test/Library/Application Support/Genshin Launcher",
        "DXMT_CONFIG": "d3d11.preferredMaxFrameRate=60;",
        "DXMT_CONFIG_FILE": "/Users/test/Library/Application Support/Genshin Launcher/dxmt.conf",
        "GST_PLUGIN_FEATURE_RANK": "atdec:MAX,avdec_h264:MAX",
      ])
  }

  @Test func GPTK4_launchOmitsDXMTEnvironmentAndMetalFXShim() {
    let recipe = make(settings(graphicsBackend: .gptk4, retina: true, metalFX: true))

    #expect(recipe.environment["WINE_ENABLE_TIMEOUT_FIX"] == "1")
    #expect(recipe.environment["DXMT_LOG_PATH"] == nil)
    #expect(recipe.environment["DXMT_CONFIG"] == nil)
    #expect(recipe.environment["DXMT_CONFIG_FILE"] == nil)
    #expect(recipe.environment["DXMT_METALFX_SPATIAL_SWAPCHAIN"] == nil)
    #expect(edits(recipe, key: macDriverKey).first?.action == .set(.string("y")))
  }

  @Test func LCH_032_timeoutFixIsAlwaysEnabledWhateverTheSettingsAre() {
    let all = settings(
      retina: true, leftCommandIsControl: true, metalHUD: true, hdr: true, metalFX: true,
      customResolution: .init(width: 1920, height: 1080), proxyHost: "127.0.0.1:7890")

    #expect(make().environment["WINE_ENABLE_TIMEOUT_FIX"] == "1")
    #expect(make(all).environment["WINE_ENABLE_TIMEOUT_FIX"] == "1")
    #expect(make().environment["WINEDLLOVERRIDES"] == nil)
  }

  @Test func LCH_032_metalHudIsSetToOneWithEveryMetricOnlyWhenEnabled() {
    let on = make(settings(metalHUD: true))
    let off = make(settings(metalHUD: false))

    #expect(on.environment["MTL_HUD_ENABLED"] == "1")
    #expect(
      on.environment["MTL_HUD_ELEMENTS"]
        == "device,rosetta,layersize,layerscale,memory,fps,frameinterval,gputime,thermal,frameintervalgraph,presentdelay,"
        + "frameintervalhistogram,metalcpu,gputimeline,shaders,framenumber,disk,fpsgraph,toplabeledcommandbuffers,"
        + "toplabeledencoders")
    #expect(on.environment["MTL_HUD_SHOW_ZERO_METRICS"] == "1")
    #expect(off.environment["MTL_HUD_ENABLED"] == nil)
    #expect(off.environment["MTL_HUD_ELEMENTS"] == nil)
    #expect(off.environment["MTL_HUD_SHOW_ZERO_METRICS"] == nil)
    #expect(on.environment["WINEESYNC"] == "1")  // positive: the rest is still there
  }

  @Test func LCH_034_proxyHostIsPassedRawToBothProxyVariables() {
    let recipe = make(settings(proxyHost: "127.0.0.1:7890"))

    #expect(recipe.environment["HTTP_PROXY"] == "127.0.0.1:7890")
    #expect(recipe.environment["HTTPS_PROXY"] == "127.0.0.1:7890")
  }

  @Test func LCH_034_proxyHostKeepsAnExplicitSchemeUnchangedAndAddsNone() {
    let withScheme = make(settings(proxyHost: "http://proxy.local:8080"))
    let bare = make(settings(proxyHost: "proxy.local:8080"))

    #expect(withScheme.environment["HTTP_PROXY"] == "http://proxy.local:8080")
    #expect(bare.environment["HTTPS_PROXY"] == "proxy.local:8080")
  }

  @Test func LCH_034_noProxyVariablesForNilOrEmptyHost() {
    let nilHost = make(settings(proxyHost: nil))
    let emptyHost = make(settings(proxyHost: ""))

    #expect(nilHost.environment["WINEESYNC"] == "1")  // positive: environment built
    #expect(nilHost.environment["HTTP_PROXY"] == nil)
    #expect(nilHost.environment["HTTPS_PROXY"] == nil)
    #expect(emptyHost.environment["WINEESYNC"] == "1")
    #expect(emptyHost.environment["HTTP_PROXY"] == nil)
    #expect(emptyHost.environment["HTTPS_PROXY"] == nil)
  }

  @Test func LCH_004_metalFxSpatialSwapchainIsSetOnlyWhenMetalFxIsOnAndNoCustomResolution() {
    let effective = make(settings(metalFX: true))
    let off = make(settings(metalFX: false))
    let withResolution = make(settings(metalFX: true, customResolution: .init(width: 2560, height: 1600)))

    #expect(effective.environment["DXMT_METALFX_SPATIAL_SWAPCHAIN"] == "1")
    #expect(off.environment["WINEESYNC"] == "1")
    #expect(off.environment["DXMT_METALFX_SPATIAL_SWAPCHAIN"] == nil)
    #expect(withResolution.environment["WINEESYNC"] == "1")
    #expect(withResolution.environment["DXMT_METALFX_SPATIAL_SWAPCHAIN"] == nil)
  }

  @Test func CFG_019_unlockAsksGamehostFor120AndRaisesTheDXMTCap() {
    let dxmt = make(settings(unlockFrameRate: true))
    let gptk = make(settings(graphicsBackend: .gptk4, unlockFrameRate: true))

    #expect(dxmt.environment["GENSHIN_LAUNCHER_FPS_TARGET"] == "120")
    #expect(dxmt.environment["DXMT_CONFIG"] == "d3d11.preferredMaxFrameRate=120;")
    #expect(gptk.environment["GENSHIN_LAUNCHER_FPS_TARGET"] == "120")
    #expect(gptk.environment["DXMT_CONFIG"] == nil)
    #expect(make().environment["GENSHIN_LAUNCHER_FPS_TARGET"] == nil)
  }

  @Test func LCH_026_recipeNamesTheGameExecutableAndDisplayName() {
    let recipe = make()

    #expect(recipe.gameExecutableName == "YuanShen.exe")
    #expect(recipe.gameDisplayName == "原神")
  }
}

@Suite("GenshinLaunchRecipe registry") struct GenshinLaunchRecipeRegistryTests {
  @Test func LCH_005_defaultSettingsWriteMacDriverNoAndNoPlusAHdrDeleteAndNoResolution() {
    let recipe = make()

    #expect(
      recipe.registry == [
        RegistryEdit(key: macDriverKey, name: "RetinaMode", action: .set(.string("n")), restoresOnExit: false),
        RegistryEdit(key: macDriverKey, name: "LeftCommandIsCtrl", action: .set(.string("n")), restoresOnExit: false),
        RegistryEdit(key: miHoYoKey, name: hdrName, action: .delete, restoresOnExit: false),
      ])
  }

  @Test func LCH_005_retinaAndLeftCommandMapToYAndNAsPersistentStrings() {
    let recipe = make(settings(retina: true, leftCommandIsControl: true))

    let mac = edits(recipe, key: macDriverKey)
    #expect(
      mac == [
        RegistryEdit(key: macDriverKey, name: "RetinaMode", action: .set(.string("y")), restoresOnExit: false),
        RegistryEdit(key: macDriverKey, name: "LeftCommandIsCtrl", action: .set(.string("y")), restoresOnExit: false),
      ])
    #expect(mac.allSatisfy { !$0.restoresOnExit })
  }

  @Test func LCH_005_retinaOnlyAndLeftCommandOnlyAreIndependent() {
    let retinaOnly = edits(make(settings(retina: true)), key: macDriverKey)
    let leftOnly = edits(make(settings(leftCommandIsControl: true)), key: macDriverKey)

    #expect(retinaOnly.map(\.action) == [.set(.string("y")), .set(.string("n"))])
    #expect(leftOnly.map(\.action) == [.set(.string("n")), .set(.string("y"))])
  }

  @Test func LCH_004_retinaIsForcedOffWhenMetalFxIsEffective() {
    let forced = edits(make(settings(retina: true, metalFX: true)), key: macDriverKey)
    let notEffective = edits(
      make(settings(retina: true, metalFX: true, customResolution: .init(width: 1920, height: 1080))),
      key: macDriverKey)

    #expect(forced.first?.name == "RetinaMode")
    #expect(forced.first?.action == .set(.string("n")))
    #expect(notEffective.first?.action == .set(.string("y")))
  }

  @Test func LCH_006_hdrOnSetsTheHdrDwordToOneAndRestoresItOnExit() {
    let recipe = make(settings(hdr: true))

    #expect(
      edits(recipe, key: miHoYoKey) == [
        RegistryEdit(key: miHoYoKey, name: hdrName, action: .set(.dword(1)), restoresOnExit: true)
      ])
  }

  @Test func LCH_006_hdrOffDeletesTheHdrValueAndDoesNotRestoreIt() {
    let recipe = make(settings(hdr: false))

    #expect(
      edits(recipe, key: miHoYoKey) == [
        RegistryEdit(key: miHoYoKey, name: hdrName, action: .delete, restoresOnExit: false)
      ])
  }

  @Test func LCH_007_customResolutionForcesWindowedModeWithWidthAndHeightAndRestoresOnExit() {
    let recipe = make(settings(customResolution: .init(width: 2560, height: 1600)))

    #expect(
      edits(recipe, key: miHoYoKey) == [
        RegistryEdit(key: miHoYoKey, name: hdrName, action: .delete, restoresOnExit: false),
        RegistryEdit(key: miHoYoKey, name: fullscreenName, action: .set(.dword(0)), restoresOnExit: true),
        RegistryEdit(key: miHoYoKey, name: widthName, action: .set(.dword(2560)), restoresOnExit: true),
        RegistryEdit(key: miHoYoKey, name: heightName, action: .set(.dword(1600)), restoresOnExit: true),
      ])
  }

  @Test func LCH_007_noCustomResolutionMeansNoResolutionEditsAtAll() {
    let recipe = make(settings(hdr: true))

    #expect(recipe.registry.contains { $0.name == hdrName })  // positive: registry was built
    for name in [fullscreenName, widthName, heightName] {
      #expect(!recipe.registry.contains { $0.name == name })
    }
  }

  @Test func LCH_007_everythingOnGivesTheFullRegistryInMacDriverHdrResolutionOrder() {
    let recipe = make(
      settings(
        retina: true, leftCommandIsControl: true, hdr: true, customResolution: .init(width: 1920, height: 1080)))

    #expect(
      recipe.registry == [
        RegistryEdit(key: macDriverKey, name: "RetinaMode", action: .set(.string("y")), restoresOnExit: false),
        RegistryEdit(key: macDriverKey, name: "LeftCommandIsCtrl", action: .set(.string("y")), restoresOnExit: false),
        RegistryEdit(key: miHoYoKey, name: hdrName, action: .set(.dword(1)), restoresOnExit: true),
        RegistryEdit(key: miHoYoKey, name: fullscreenName, action: .set(.dword(0)), restoresOnExit: true),
        RegistryEdit(key: miHoYoKey, name: widthName, action: .set(.dword(1920)), restoresOnExit: true),
        RegistryEdit(key: miHoYoKey, name: heightName, action: .set(.dword(1080)), restoresOnExit: true),
      ])
  }
}

@Suite("GenshinLaunchRecipe files and script") struct GenshinLaunchRecipeFileTests {
  @Test func LCH_014_movesAsideTheThreeCrashAndVulkanFiles() {
    let recipe = make()

    #expect(
      recipe.moveAside.map(\.path) == [
        "/Games/GI/YuanShen_Data/upload_crash.exe",
        "/Games/GI/YuanShen_Data/Plugins/crashreport.exe",
        "/Games/GI/YuanShen_Data/Plugins/vulkan-1.dll",
      ])
  }

  @Test func LCH_018_deploysSteamAndLsteamclientFromProtonExtrasIntoSystem32AndSyswow64() {
    let recipe = make()

    let extras = "/Users/test/Library/Application Support/Genshin Launcher/sidecar/protonextras"
    #expect(
      recipe.prefixCopies.map { [$0.source.path, $0.destination] } == [
        ["\(extras)/steam64.exe", "system32/steam.exe"],
        ["\(extras)/steam32.exe", "syswow64/steam.exe"],
        ["\(extras)/lsteamclient64.dll", "system32/lsteamclient.dll"],
        ["\(extras)/lsteamclient32.dll", "syswow64/lsteamclient.dll"],
      ])
  }

  @Test func LCH_010_commandGoldenForGameDirectoryGamesGI() {
    #expect(make().command == [#"C:\windows\system32\steam.exe"#, #"Z:\Games\GI\YuanShen.exe"#])
  }

  @Test func LCH_011_commandGoesThroughSteamExeWithoutCmdDriverCopyOrCloudArguments() {
    let command = make().command

    // #57: a `cmd` parent makes the game load HoYoKProtect.sys, which fails on this Wine
    #expect(command.count == 2)
    #expect(command.first == #"C:\windows\system32\steam.exe"#)
    #expect(!command.contains("cmd"))
  }

  @Test func LCH_010_aPercentSignAndANonAsciiGameDirectoryAppearVerbatim() {
    #expect(
      make(gameDirectory: URL(filePath: "/Games/50%Off", directoryHint: .isDirectory)).command.last
        == #"Z:\Games\50%Off\YuanShen.exe"#)
    let recipe = make(gameDirectory: URL(filePath: "/Games/原神 GI", directoryHint: .isDirectory))
    #expect(recipe.command.last == #"Z:\Games\原神 GI\YuanShen.exe"#)
    #expect(recipe.moveAside.first?.path == "/Games/原神 GI/YuanShen_Data/upload_crash.exe")
  }
}

@Suite("GenshinLaunchRecipe invalid resolution") struct GenshinLaunchRecipeInvalidResolutionTests {
  @Test func LCH_008_outOfRangeResolutionIsSkippedWithoutTrapping() {
    for bad in [(-1, 1080), (1920, 0), (Int.max, 1080)] {
      let recipe = make(
        settings(metalFX: true, customResolution: .init(width: bad.0, height: bad.1)))
      #expect(edits(recipe, key: miHoYoKey).filter { $0.name != hdrName }.isEmpty)
      #expect(recipe.environment["DXMT_METALFX_SPATIAL_SWAPCHAIN"] == "1")
    }
  }
}

@Suite("GenshinLaunchRecipe game directory") struct GenshinLaunchRecipeGameDirectoryTests {
  @Test func LCH_010_directoriesWithQuotesOrLineBreaksAreUnsupported() {
    #expect(GenshinLaunchRecipe.isSupported(gameDirectory: URL(filePath: "/Games/原神 GI")))
    #expect(!GenshinLaunchRecipe.isSupported(gameDirectory: URL(filePath: "/Games/a\"b")))
    #expect(!GenshinLaunchRecipe.isSupported(gameDirectory: URL(filePath: "/Games/a\nb")))
  }
}

// The switches of the TS launcher that are gone: Steam patch, Timeout Fix and Game Mode are always on (#28 A9)
// Nothing in the settings that reach the recipe can name them.
@Suite("Launch settings have no fixed-on switches") struct FixedSwitchTests {
  private func labels(_ value: Any) -> [String] { Mirror(reflecting: value).children.compactMap(\.label) }

  @Test func CFG_024_CFG_027_CFG_028_CFG_019_theLaunchSettingsOnlyCarryTheSwitchesThatRemain() {
    let expected = [
      "graphicsBackend", "retina", "leftCommandIsControl", "metalHUD", "hdr", "metalFX", "unlockFrameRate",
      "customResolution", "proxyHost",
    ]
    #expect(labels(LaunchOptions(gameDirectory: defaultGameDirectory)) == ["gameDirectory"] + expected)
  }

  @Test func CFG_024_theSteamPatchIsOnWhateverTheSettingsAre() {
    for settings in [settings(), settings(hdr: true, metalFX: true)] {
      let recipe = make(settings)
      #expect(recipe.command.first == #"C:\windows\system32\steam.exe"#)
      #expect(recipe.prefixCopies.map(\.destination).contains("system32/steam.exe"))
      #expect(recipe.prefixCopies.map(\.destination).contains("system32/lsteamclient.dll"))
    }
  }

  @Test func CFG_027_theTimeoutFixIsOnWhateverTheSettingsAre() {
    #expect(make().environment["WINE_ENABLE_TIMEOUT_FIX"] == "1")
    #expect(make(settings(retina: true, metalHUD: true)).environment["WINE_ENABLE_TIMEOUT_FIX"] == "1")
  }

  @Test func CFG_019_theFrameRateCapIs60UnlessUnlocked() {
    for settings in [settings(), settings(metalHUD: true, hdr: true, metalFX: true)] {
      #expect(make(settings).environment["DXMT_CONFIG"] == "d3d11.preferredMaxFrameRate=60;")
    }
  }
}
