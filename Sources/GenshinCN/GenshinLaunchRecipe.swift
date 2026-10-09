import Foundation
import Wine

/// The launch-time preferences that reach Wine (a snapshot, never read from `UserDefaults` here).
public struct GenshinLaunchSettings: Sendable, Equatable {
  public var retina: Bool
  public var leftCommandIsControl: Bool
  public var metalHUD: Bool
  public var hdr: Bool
  public var metalFX: Bool
  /// `nil` = do not touch the game's own resolution. Positive values only; validation is the settings UI's job.
  public var customResolution: Resolution?
  /// Raw `host:port`, passed through unchanged (LCH-034). `nil` or empty = no proxy.
  public var proxyHost: String?

  public struct Resolution: Sendable, Equatable {
    public var width: Int
    public var height: Int
    public init(width: Int, height: Int) {
      self.width = width
      self.height = height
    }
  }

  public init(
    retina: Bool = false, leftCommandIsControl: Bool = false, metalHUD: Bool = false, hdr: Bool = false,
    metalFX: Bool = false, customResolution: Resolution? = nil, proxyHost: String? = nil
  ) {
    self.retina = retina
    self.leftCommandIsControl = leftCommandIsControl
    self.metalHUD = metalHUD
    self.hdr = hdr
    self.metalFX = metalFX
    self.customResolution = customResolution
    self.proxyHost = proxyHost
  }
}

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

  public static func make(
    settings: GenshinLaunchSettings,
    gameDirectory: URL,
    dataDirectory: URL,
    protonExtras protonExtrasDirectory: URL
  ) -> LaunchRecipe {
    // MetalFX only takes effect at the display's native size (LCH-004).
    let metalFX = settings.metalFX && settings.customResolution == nil

    var environment = [
      "WINE_ENABLE_TIMEOUT_FIX": "1",
      "WINEESYNC": "1",
      "DXMT_LOG_PATH": dataDirectory.path,
      "DXMT_CONFIG": "d3d11.preferredMaxFrameRate=60;",
      "DXMT_CONFIG_FILE": dataDirectory.appending(path: "dxmt.conf").path,
      "GST_PLUGIN_FEATURE_RANK": "atdec:MAX,avdec_h264:MAX",
    ]
    if settings.metalHUD { environment["MTL_HUD_ENABLED"] = "1" }
    if metalFX { environment["DXMT_METALFX_SPATIAL_SWAPCHAIN"] = "1" }
    if let proxy = settings.proxyHost, !proxy.isEmpty {
      environment["HTTP_PROXY"] = proxy
      environment["HTTPS_PROXY"] = proxy
    }

    func yesNo(_ value: Bool) -> RegistryValue { .string(value ? "y" : "n") }
    var registry = [
      RegistryEdit(
        key: macDriverKey, name: "RetinaMode", action: .set(yesNo(settings.retina && !metalFX)), restoresOnExit: false),
      RegistryEdit(
        key: macDriverKey, name: "LeftCommandIsCtrl", action: .set(yesNo(settings.leftCommandIsControl)),
        restoresOnExit: false),
    ]
    // HDR is written or deleted to match the setting on every launch; a crash leftover heals itself.
    registry.append(
      settings.hdr
        ? RegistryEdit(key: gameKey, name: hdrValue, action: .set(.dword(1)), restoresOnExit: true)
        : RegistryEdit(key: gameKey, name: hdrValue, action: .delete, restoresOnExit: false))
    if let resolution = settings.customResolution {
      registry += [
        RegistryEdit(key: gameKey, name: fullscreenValue, action: .set(.dword(0)), restoresOnExit: true),
        RegistryEdit(key: gameKey, name: widthValue, action: .set(.dword(UInt32(resolution.width))), restoresOnExit: true),
        RegistryEdit(key: gameKey, name: heightValue, action: .set(.dword(UInt32(resolution.height))), restoresOnExit: true),
      ]
    }

    return LaunchRecipe(
      environment: environment,
      registry: registry,
      moveAside: movedAside.map { gameDirectory.appending(path: $0) },
      prefixCopies: protonExtras.map {
        PrefixCopy(source: protonExtrasDirectory.appending(path: $0.0), destination: $0.1)
      },
      batchScript: batchScript(gameDirectory: gameDirectory),
      gameExecutableName: GenshinCN.executableName,
      gameDisplayName: displayName)
  }

  /// `config.bat` (LCH-010/011). `cmd` reads it in the OEM code page; a non-ASCII game directory is a
  /// real-machine item for the diag. `%` is doubled so it cannot start a variable expansion.
  static func batchScript(gameDirectory: URL) -> String {
    let directory = "Z:" + gameDirectory.path.replacingOccurrences(of: "/", with: "\\")
      .replacingOccurrences(of: "%", with: "%%")
    return [
      "@echo off",
      #"cd "%~dp0""#,
      #"copy "\#(directory)\HoYoKProtect.sys" "%WINDIR%\system32\""#,
      #"cd /d "\#(directory)""#,
      #""%WINDIR%\system32\steam.exe" "\#(directory)\\#(GenshinCN.executableName)" -platform_type CLOUD_THIRD_PARTY_PC -is_cloud 1"#,
      "",
    ].joined(separator: "\n")
  }
}
