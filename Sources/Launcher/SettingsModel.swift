import Foundation
import Observation

/// Why a directory cannot be the game directory.
public enum GameDirectoryProblem: Error, Sendable, Equatable {
  case missing, notADirectory, unsupportedPath, notEmpty
}

public enum GameDirectoryKind: Sendable, Equatable {
  /// Empty (or only an interrupted install's leftovers): a place to install into.
  case empty
  /// Already holds the game executable: import it.
  case existingGame
}

public enum GameDirectoryValidator {
  /// Names that do not count as content: this app's temp directory and Finder litter.
  static let ignored: Set<String> = [".yaagl-tmp", ".DS_Store"]

  public static func validate(
    _ url: URL, gameExecutable: String, isSupportedPath: (URL) -> Bool
  ) throws -> GameDirectoryKind {
    var isDirectory: ObjCBool = false
    guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
      throw GameDirectoryProblem.missing
    }
    guard isDirectory.boolValue else { throw GameDirectoryProblem.notADirectory }
    guard isSupportedPath(url) else { throw GameDirectoryProblem.unsupportedPath }
    let names = (try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? []
    if names.contains(gameExecutable) { return .existingGame }
    guard names.allSatisfy({ ignored.contains($0) }) else { throw GameDirectoryProblem.notEmpty }
    return .empty
  }
}

/// `host:port`, no scheme (CFG-015). Returns the trimmed value, or nil when it is not acceptable.
enum ProxyAddress {
  static func normalize(_ text: String) -> String? {
    let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let colon = value.lastIndex(of: ":") else { return nil }
    let host = String(value[..<colon])
    let port = String(value[value.index(after: colon)...])
    guard let number = Int(port), (1...65535).contains(number), port.allSatisfy(\.isASCII) else { return nil }
    if host.hasPrefix("[") && host.hasSuffix("]") {
      let inner = host.dropFirst().dropLast()
      guard !inner.isEmpty, inner.allSatisfy({ $0.isHexDigit || $0 == ":" || $0 == "." }) else { return nil }
      return value
    }
    let allowed = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-_")
    guard !host.isEmpty, host.allSatisfy({ allowed.contains($0) }) else { return nil }
    return value
  }
}

/// The user's preferences, typed and written to `UserDefaults` on change (ADR 0002). Domain modules never
/// read it: the app composition root snapshots the values it needs.
@MainActor @Observable
public final class SettingsModel {
  public struct Resolution: Sendable, Equatable {
    public var width: Int
    public var height: Int
    public init(width: Int, height: Int) {
      self.width = width
      self.height = height
    }
  }

  enum Key {
    static let gameDirectory = "gameDirectory"
    static let retina = "retina"
    static let leftCommandIsControl = "leftCommandIsControl"
    static let metalHUD = "metalHUD"
    static let hdr = "hdr"
    static let metalFX = "metalFX"
    static let customResolutionEnabled = "customResolutionEnabled"
    static let resolutionWidth = "resolutionWidth"
    static let resolutionHeight = "resolutionHeight"
    static let proxyEnabled = "proxyEnabled"
    static let proxyHost = "proxyHost"
  }

  @ObservationIgnored private let defaults: UserDefaults

  public var gameDirectory: URL? {
    didSet { defaults.set(gameDirectory?.path, forKey: Key.gameDirectory) }
  }
  public var retina: Bool { didSet { defaults.set(retina, forKey: Key.retina) } }
  public var leftCommandIsControl: Bool {
    didSet { defaults.set(leftCommandIsControl, forKey: Key.leftCommandIsControl) }
  }
  public var metalHUD: Bool { didSet { defaults.set(metalHUD, forKey: Key.metalHUD) } }
  public var hdr: Bool { didSet { defaults.set(hdr, forKey: Key.hdr) } }
  public var metalFX: Bool { didSet { defaults.set(metalFX, forKey: Key.metalFX) } }
  public var customResolutionEnabled: Bool {
    didSet { defaults.set(customResolutionEnabled, forKey: Key.customResolutionEnabled) }
  }
  public private(set) var resolutionWidth: Int
  public private(set) var resolutionHeight: Int
  public var proxyEnabled: Bool { didSet { defaults.set(proxyEnabled, forKey: Key.proxyEnabled) } }
  public private(set) var proxyHost: String

  public init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
    gameDirectory = defaults.string(forKey: Key.gameDirectory).map { URL(filePath: $0) }
    retina = defaults.bool(forKey: Key.retina)
    leftCommandIsControl = defaults.bool(forKey: Key.leftCommandIsControl)
    metalHUD = defaults.bool(forKey: Key.metalHUD)
    hdr = defaults.bool(forKey: Key.hdr)
    metalFX = defaults.bool(forKey: Key.metalFX)
    customResolutionEnabled = defaults.bool(forKey: Key.customResolutionEnabled)
    let width = defaults.integer(forKey: Key.resolutionWidth)
    let height = defaults.integer(forKey: Key.resolutionHeight)
    resolutionWidth = width > 0 ? width : 1920
    resolutionHeight = height > 0 ? height : 1080
    proxyEnabled = defaults.bool(forKey: Key.proxyEnabled)
    proxyHost = defaults.string(forKey: Key.proxyHost).flatMap(ProxyAddress.normalize) ?? ""
  }

  /// nil unless the custom resolution is switched on.
  public var customResolution: Resolution? {
    customResolutionEnabled ? Resolution(width: resolutionWidth, height: resolutionHeight) : nil
  }

  /// False (and nothing saved) unless both are positive.
  @discardableResult
  public func setResolution(width: Int, height: Int) -> Bool {
    guard width > 0, height > 0 else { return false }
    resolutionWidth = width
    resolutionHeight = height
    defaults.set(width, forKey: Key.resolutionWidth)
    defaults.set(height, forKey: Key.resolutionHeight)
    return true
  }

  /// False (and nothing saved) when `text` is not a `host:port`.
  @discardableResult
  public func setProxyHost(_ text: String) -> Bool {
    guard let normalized = ProxyAddress.normalize(text) else { return false }
    proxyHost = normalized
    defaults.set(normalized, forKey: Key.proxyHost)
    return true
  }

  /// The proxy the game process should use, or nil.
  public var effectiveProxy: String? {
    proxyEnabled && !proxyHost.isEmpty ? proxyHost : nil
  }
}
