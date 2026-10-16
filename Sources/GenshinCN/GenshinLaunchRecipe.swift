import Foundation
import Launcher
import Wine

/// Builds the `LaunchRecipe` for Genshin CN. A pure function; golden-tested.
///
/// Steam patch, Timeout Fix and Game Mode are always on (#28 A9): there are no switches for them.
public enum GenshinLaunchRecipe {
  static let macDriverKey = #"HKCU\Software\Wine\Mac Driver"#
  static let gameKey = #"HKCU\Software\miHoYo\原神"#
  static let hdrValue = "WINDOWS_HDR_ON_h3132281285"
  static let fullscreenValue = "Screenmanager Is Fullscreen mode_h3981298716"
  static let widthValue = "Screenmanager Resolution Width_h182942802"
  static let heightValue = "Screenmanager Resolution Height_h2627697771"
  static let displayName = "原神"

  /// Game files moved aside while the game runs (LCH-014): crash reporters and the Vulkan loader.
  static let movedAside = [
    "YuanShen_Data/upload_crash.exe",
    "YuanShen_Data/Plugins/crashreport.exe",
    "YuanShen_Data/Plugins/vulkan-1.dll",
  ]

  /// Proton's Steam shim, copied into the prefix (LCH-018). 64-bit files go to `system32`, 32-bit to
  /// `syswow64`, as in the TS launcher.
  static let protonExtras = [
    ("steam64.exe", "system32/steam.exe"),
    ("steam32.exe", "syswow64/steam.exe"),
    ("lsteamclient64.dll", "system32/lsteamclient.dll"),
    ("lsteamclient32.dll", "syswow64/lsteamclient.dll"),
  ]

  /// A double quote or a line break in the game directory is rejected up front: no known game folder needs one, and
  /// it keeps every path handed to Wine and the log plain.
  public static func isSupported(gameDirectory: URL) -> Bool {
    !gameDirectory.path.contains { $0 == "\"" || $0.isNewline }
  }

  static func make(
    options: LaunchOptions,
    dataDirectory: URL,
    protonExtras protonExtrasDirectory: URL
  ) -> LaunchRecipe {
    // MetalFX only takes effect at the display's native size (LCH-004).
    // Out-of-range values are skipped like the TS launcher did (LCH-008); the settings UI validates input.
    let resolution = options.customResolution.flatMap { resolution -> (UInt32, UInt32)? in
      guard let width = UInt32(exactly: resolution.width), let height = UInt32(exactly: resolution.height),
        width > 0, height > 0
      else { return nil }
      return (width, height)
    }
    let metalFX = options.graphicsBackend == .dxmt && options.metalFX && resolution == nil

    var environment = [
      "WINE_ENABLE_TIMEOUT_FIX": "1",
      "WINEESYNC": "1",
      "GST_PLUGIN_FEATURE_RANK": "atdec:MAX,avdec_h264:MAX",
    ]
    if options.graphicsBackend == .dxmt {
      environment["DXMT_LOG_PATH"] = dataDirectory.path
      environment["DXMT_CONFIG"] = "d3d11.preferredMaxFrameRate=60;"
      environment["DXMT_CONFIG_FILE"] = dataDirectory.appending(path: "dxmt.conf").path
    }
    if options.metalHUD { environment["MTL_HUD_ENABLED"] = "1" }
    if metalFX { environment["DXMT_METALFX_SPATIAL_SWAPCHAIN"] = "1" }
    if let proxy = options.proxyHost, !proxy.isEmpty {
      environment["HTTP_PROXY"] = proxy
      environment["HTTPS_PROXY"] = proxy
    }

    func yesNo(_ value: Bool) -> RegistryValue { .string(value ? "y" : "n") }
    var registry = [
      RegistryEdit(
        key: macDriverKey, name: "RetinaMode",
        action: .set(yesNo(options.retina && !metalFX)), restoresOnExit: false),
      RegistryEdit(
        key: macDriverKey, name: "LeftCommandIsCtrl", action: .set(yesNo(options.leftCommandIsControl)),
        restoresOnExit: false),
    ]
    // HDR is written or deleted to match the setting on every launch; a crash leftover heals itself.
    registry.append(
      options.hdr
        ? RegistryEdit(key: gameKey, name: hdrValue, action: .set(.dword(1)), restoresOnExit: true)
        : RegistryEdit(key: gameKey, name: hdrValue, action: .delete, restoresOnExit: false))
    if let resolution {
      registry += [
        RegistryEdit(key: gameKey, name: fullscreenValue, action: .set(.dword(0)), restoresOnExit: true),
        RegistryEdit(key: gameKey, name: widthValue, action: .set(.dword(resolution.0)), restoresOnExit: true),
        RegistryEdit(key: gameKey, name: heightValue, action: .set(.dword(resolution.1)), restoresOnExit: true),
      ]
    }

    return LaunchRecipe(
      environment: environment,
      registry: registry,
      moveAside: movedAside.map { options.gameDirectory.appending(path: $0) },
      prefixCopies: protonExtras.map {
        PrefixCopy(source: protonExtrasDirectory.appending(path: $0.0), destination: $0.1)
      },
      command: command(gameDirectory: options.gameDirectory),
      gameExecutableName: GenshinCN.executableName,
      gameDisplayName: displayName)
  }

  /// The Wine arguments (LCH-010/011): Proton's `steam.exe` shim starts the game, as the TS launcher's Steam patch
  /// did. Never through `cmd`: with `cmd.exe` as the parent the game loads `HoYoKProtect.sys`, which this Wine cannot
  /// load (#57). No driver copy and no cloud arguments either, like the TS Steam-patch path that worked.
  static func command(gameDirectory: URL) -> [String] {
    let game = gameDirectory.appending(path: GenshinCN.executableName)
    return [#"C:\windows\system32\steam.exe"#, GameSession.windowsPath(game)]
  }
}
