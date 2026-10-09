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
public enum GenshinLaunchRecipe {
  public static func make(
    settings: GenshinLaunchSettings,
    gameDirectory: URL,
    dataDirectory: URL,
    protonExtras: URL
  ) -> LaunchRecipe {
    LaunchRecipe()
  }
}
