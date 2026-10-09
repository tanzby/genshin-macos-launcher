import Foundation
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
private let dataDirectory = URL(filePath: "/Users/test/Library/Application Support/Yaagl", directoryHint: .isDirectory)
private let protonExtras = URL(filePath: "/Users/test/Library/Application Support/Yaagl/sidecar/protonextras", directoryHint: .isDirectory)

private func make(
  _ settings: GenshinLaunchSettings = .init(), gameDirectory: URL = defaultGameDirectory
) -> LaunchRecipe {
  GenshinLaunchRecipe.make(
    settings: settings, gameDirectory: gameDirectory, dataDirectory: dataDirectory, protonExtras: protonExtras)
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
        "DXMT_LOG_PATH": "/Users/test/Library/Application Support/Yaagl",
        "DXMT_CONFIG": "d3d11.preferredMaxFrameRate=60;",
        "DXMT_CONFIG_FILE": "/Users/test/Library/Application Support/Yaagl/dxmt.conf",
        "GST_PLUGIN_FEATURE_RANK": "atdec:MAX,avdec_h264:MAX",
      ])
  }

  @Test func LCH_032_timeoutFixIsAlwaysEnabledWhateverTheSettingsAre() {
    let all = GenshinLaunchSettings(
      retina: true, leftCommandIsControl: true, metalHUD: true, hdr: true, metalFX: true,
      customResolution: .init(width: 1920, height: 1080), proxyHost: "127.0.0.1:7890")

    #expect(make().environment["WINE_ENABLE_TIMEOUT_FIX"] == "1")
    #expect(make(all).environment["WINE_ENABLE_TIMEOUT_FIX"] == "1")
    #expect(make().environment["WINEDLLOVERRIDES"] == nil)
  }

  @Test func LCH_032_metalHudIsSetToOneOnlyWhenEnabled() {
    let on = make(GenshinLaunchSettings(metalHUD: true))
    let off = make(GenshinLaunchSettings(metalHUD: false))

    #expect(on.environment["MTL_HUD_ENABLED"] == "1")
    #expect(off.environment["MTL_HUD_ENABLED"] == nil)
    #expect(on.environment["WINEESYNC"] == "1")  // positive: the rest is still there
  }

  @Test func LCH_034_proxyHostIsPassedRawToBothProxyVariables() {
    let recipe = make(GenshinLaunchSettings(proxyHost: "127.0.0.1:7890"))

    #expect(recipe.environment["HTTP_PROXY"] == "127.0.0.1:7890")
    #expect(recipe.environment["HTTPS_PROXY"] == "127.0.0.1:7890")
  }

  @Test func LCH_034_proxyHostKeepsAnExplicitSchemeUnchangedAndAddsNone() {
    let withScheme = make(GenshinLaunchSettings(proxyHost: "http://proxy.local:8080"))
    let bare = make(GenshinLaunchSettings(proxyHost: "proxy.local:8080"))

    #expect(withScheme.environment["HTTP_PROXY"] == "http://proxy.local:8080")
    #expect(bare.environment["HTTPS_PROXY"] == "proxy.local:8080")
  }

  @Test func LCH_034_noProxyVariablesForNilOrEmptyHost() {
    let nilHost = make(GenshinLaunchSettings(proxyHost: nil))
    let emptyHost = make(GenshinLaunchSettings(proxyHost: ""))

    #expect(nilHost.environment["WINEESYNC"] == "1")  // positive: environment built
    #expect(nilHost.environment["HTTP_PROXY"] == nil)
    #expect(nilHost.environment["HTTPS_PROXY"] == nil)
    #expect(emptyHost.environment["WINEESYNC"] == "1")
    #expect(emptyHost.environment["HTTP_PROXY"] == nil)
    #expect(emptyHost.environment["HTTPS_PROXY"] == nil)
  }

  @Test func LCH_004_metalFxSpatialSwapchainIsSetOnlyWhenMetalFxIsOnAndNoCustomResolution() {
    let effective = make(GenshinLaunchSettings(metalFX: true))
    let off = make(GenshinLaunchSettings(metalFX: false))
    let withResolution = make(GenshinLaunchSettings(metalFX: true, customResolution: .init(width: 2560, height: 1600)))

    #expect(effective.environment["DXMT_METALFX_SPATIAL_SWAPCHAIN"] == "1")
    #expect(off.environment["WINEESYNC"] == "1")
    #expect(off.environment["DXMT_METALFX_SPATIAL_SWAPCHAIN"] == nil)
    #expect(withResolution.environment["WINEESYNC"] == "1")
    #expect(withResolution.environment["DXMT_METALFX_SPATIAL_SWAPCHAIN"] == nil)
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
    let recipe = make(GenshinLaunchSettings(retina: true, leftCommandIsControl: true))

    let mac = edits(recipe, key: macDriverKey)
    #expect(
      mac == [
        RegistryEdit(key: macDriverKey, name: "RetinaMode", action: .set(.string("y")), restoresOnExit: false),
        RegistryEdit(key: macDriverKey, name: "LeftCommandIsCtrl", action: .set(.string("y")), restoresOnExit: false),
      ])
    #expect(mac.allSatisfy { !$0.restoresOnExit })
  }

  @Test func LCH_005_retinaOnlyAndLeftCommandOnlyAreIndependent() {
    let retinaOnly = edits(make(GenshinLaunchSettings(retina: true)), key: macDriverKey)
    let leftOnly = edits(make(GenshinLaunchSettings(leftCommandIsControl: true)), key: macDriverKey)

    #expect(retinaOnly.map(\.action) == [.set(.string("y")), .set(.string("n"))])
    #expect(leftOnly.map(\.action) == [.set(.string("n")), .set(.string("y"))])
  }

  @Test func LCH_004_retinaIsForcedOffWhenMetalFxIsEffective() {
    let forced = edits(make(GenshinLaunchSettings(retina: true, metalFX: true)), key: macDriverKey)
    let notEffective = edits(
      make(GenshinLaunchSettings(retina: true, metalFX: true, customResolution: .init(width: 1920, height: 1080))),
      key: macDriverKey)

    #expect(forced.first?.name == "RetinaMode")
    #expect(forced.first?.action == .set(.string("n")))
    #expect(notEffective.first?.action == .set(.string("y")))
  }

  @Test func LCH_006_hdrOnSetsTheHdrDwordToOneAndRestoresItOnExit() {
    let recipe = make(GenshinLaunchSettings(hdr: true))

    #expect(
      edits(recipe, key: miHoYoKey) == [
        RegistryEdit(key: miHoYoKey, name: hdrName, action: .set(.dword(1)), restoresOnExit: true)
      ])
  }

  @Test func LCH_006_hdrOffDeletesTheHdrValueAndDoesNotRestoreIt() {
    let recipe = make(GenshinLaunchSettings(hdr: false))

    #expect(
      edits(recipe, key: miHoYoKey) == [
        RegistryEdit(key: miHoYoKey, name: hdrName, action: .delete, restoresOnExit: false)
      ])
  }

  @Test func LCH_007_customResolutionForcesWindowedModeWithWidthAndHeightAndRestoresOnExit() {
    let recipe = make(GenshinLaunchSettings(customResolution: .init(width: 2560, height: 1600)))

    #expect(
      edits(recipe, key: miHoYoKey) == [
        RegistryEdit(key: miHoYoKey, name: hdrName, action: .delete, restoresOnExit: false),
        RegistryEdit(key: miHoYoKey, name: fullscreenName, action: .set(.dword(0)), restoresOnExit: true),
        RegistryEdit(key: miHoYoKey, name: widthName, action: .set(.dword(2560)), restoresOnExit: true),
        RegistryEdit(key: miHoYoKey, name: heightName, action: .set(.dword(1600)), restoresOnExit: true),
      ])
  }

  @Test func LCH_007_noCustomResolutionMeansNoResolutionEditsAtAll() {
    let recipe = make(GenshinLaunchSettings(hdr: true))

    #expect(recipe.registry.contains { $0.name == hdrName })  // positive: registry was built
    for name in [fullscreenName, widthName, heightName] {
      #expect(!recipe.registry.contains { $0.name == name })
    }
  }

  @Test func LCH_007_everythingOnGivesTheFullRegistryInMacDriverHdrResolutionOrder() {
    let recipe = make(
      GenshinLaunchSettings(
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

    let extras = "/Users/test/Library/Application Support/Yaagl/sidecar/protonextras"
    #expect(
      recipe.prefixCopies.map { [$0.source.path, $0.destination] } == [
        ["\(extras)/steam64.exe", "system32/steam.exe"],
        ["\(extras)/steam32.exe", "syswow64/steam.exe"],
        ["\(extras)/lsteamclient64.dll", "system32/lsteamclient.dll"],
        ["\(extras)/lsteamclient32.dll", "syswow64/lsteamclient.dll"],
      ])
  }

  @Test func LCH_010_batchScriptGoldenForGameDirectoryGamesGI() {
    let recipe = make()

    #expect(
      recipe.batchScript == #"""
        @echo off
        cd "%~dp0"
        copy "Z:\Games\GI\HoYoKProtect.sys" "%WINDIR%\system32\"
        cd /d "Z:\Games\GI"
        "%WINDIR%\system32\steam.exe" "Z:\Games\GI\YuanShen.exe" -platform_type CLOUD_THIRD_PARTY_PC -is_cloud 1

        """#)
  }

  @Test func LCH_011_batchScriptLaunchesThroughSteamExeWithTheCloudArguments() {
    let script = make().batchScript

    #expect(script.contains(#""%WINDIR%\system32\steam.exe" "Z:\Games\GI\YuanShen.exe""#))
    #expect(script.hasSuffix(" -platform_type CLOUD_THIRD_PARTY_PC -is_cloud 1\n"))
    #expect(!script.contains("\r"))
  }

  @Test func LCH_010_aPercentSignInTheGameDirectoryIsDoubledInEveryOccurrence() {
    let recipe = make(gameDirectory: URL(filePath: "/Games/50%Off", directoryHint: .isDirectory))

    #expect(
      recipe.batchScript == #"""
        @echo off
        cd "%~dp0"
        copy "Z:\Games\50%%Off\HoYoKProtect.sys" "%WINDIR%\system32\"
        cd /d "Z:\Games\50%%Off"
        "%WINDIR%\system32\steam.exe" "Z:\Games\50%%Off\YuanShen.exe" -platform_type CLOUD_THIRD_PARTY_PC -is_cloud 1

        """#)
  }

  @Test func LCH_010_aNonAsciiGameDirectoryAppearsVerbatimInTheScript() {
    let recipe = make(gameDirectory: URL(filePath: "/Games/原神 GI", directoryHint: .isDirectory))

    #expect(
      recipe.batchScript == #"""
        @echo off
        cd "%~dp0"
        copy "Z:\Games\原神 GI\HoYoKProtect.sys" "%WINDIR%\system32\"
        cd /d "Z:\Games\原神 GI"
        "%WINDIR%\system32\steam.exe" "Z:\Games\原神 GI\YuanShen.exe" -platform_type CLOUD_THIRD_PARTY_PC -is_cloud 1

        """#)
    #expect(recipe.moveAside.first?.path == "/Games/原神 GI/YuanShen_Data/upload_crash.exe")
  }
}
