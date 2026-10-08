import Foundation

/// `~/Library/Application Support/Yaagl`. `prepare()` is the only way to get one for real use:
/// it runs the first-launch cleanup of TS-launcher leftovers (ADR 0001) before returning.
public struct DataDirectory: Sendable, Equatable {
  public static let name = "Yaagl"
  public static let nativeMarkerName = ".yaagl-native"

  public let root: URL

  public init(root: URL) {
    self.root = root
  }

  public static var defaultRoot: URL {
    URL.applicationSupportDirectory.appending(path: name, directoryHint: .isDirectory)
  }

  /// WKWebView leftovers of the Neutralino app, outside the data directory.
  public static var defaultExternalResidue: [URL] {
    let library = URL.libraryDirectory
    return [
      library.appending(path: "Caches/com.3shain.yaagl", directoryHint: .isDirectory),
      library.appending(path: "WebKit/com.3shain.yaagl", directoryHint: .isDirectory),
    ]
  }

  public var nativeMarker: URL { entry(Self.nativeMarkerName) }
  /// Wine and DXMT are installed together; its version stamp lives inside.
  public var wine: URL { entry("wine", directory: true) }
  public var winePrefix: URL { entry("wineprefix", directory: true) }
  public var logs: URL { entry("logs", directory: true) }

  private func entry(_ name: String, directory: Bool = false) -> URL {
    root.appending(path: name, directoryHint: directory ? .isDirectory : .notDirectory)
  }
}

extension DataDirectory {
  /// Content of `.yaagl-native`. Kept in its own file so that damage to other state is never
  /// mistaken for "no marker", which would trigger a wipe.
  public struct Marker: Codable, Sendable, Equatable {
    public static let currentSchemaVersion = 1
    public var schemaVersion: Int

    public init(schemaVersion: Int = Self.currentSchemaVersion) {
      self.schemaVersion = schemaVersion
    }
  }

  public enum PrepareError: Error, Equatable {
    /// The marker exists but cannot be decoded. Nothing was deleted.
    case unrecognizedMarker(URL)
    /// The marker was written by a newer launcher. Nothing was deleted.
    case unsupportedSchemaVersion(Int)
    /// A leftover could not be removed. The marker was not written, so the next launch retries.
    case cleanupFailed(URL, String)
  }

  /// Top-level entries of the TS launcher that the native app deletes. `wine-gptk4/`, `gptk4/`,
  /// `logs/` and everything unlisted belong to the user and stay.
  static let residueNames: Set<String> = [
    ".storage", "wine", "wineprefix", "dxmt", "YaaglGame.app", "sidecar",
    "resources.neu", "resources.neu.update", ".bundle-stamp", "neutralinojs.log", "aria2.session",
    "decompress.log", "winedrv_config.bat", "config.bat", "wineboot.log", "winecfg.log",
    "wine.tar.xz", "icon.icns",
  ]
  static let residueSuffixes = [".reg", "_d3d11.log", "_dxgi.log"]

  /// Creates the root if needed, wipes TS leftovers when there is no native marker, writes the
  /// marker and returns the ready directory. A marker that is present but unusable is an error.
  public static func prepare(
    root: URL = defaultRoot,
    externalResidue: [URL] = defaultExternalResidue,
    fileManager: FileManager = .default
  ) throws -> DataDirectory {
    let directory = DataDirectory(root: root)
    try fileManager.createDirectory(at: root, withIntermediateDirectories: true)

    if fileManager.fileExists(atPath: directory.nativeMarker.path) {
      let marker: Marker
      do {
        marker = try JSONDecoder().decode(Marker.self, from: Data(contentsOf: directory.nativeMarker))
      } catch {
        throw PrepareError.unrecognizedMarker(directory.nativeMarker)
      }
      guard marker.schemaVersion <= Marker.currentSchemaVersion else {
        throw PrepareError.unsupportedSchemaVersion(marker.schemaVersion)
      }
      return directory
    }

    let names = try fileManager.contentsOfDirectory(atPath: root.path)
    let doomed = names.filter { name in
      residueNames.contains(name) || residueSuffixes.contains { name.hasSuffix($0) }
    }
    for url in doomed.map({ root.appending(path: $0) }) + externalResidue {
      try remove(url, fileManager: fileManager)
    }

    try JSONEncoder().encode(Marker()).write(to: directory.nativeMarker, options: .atomic)
    return directory
  }

  private static func remove(_ url: URL, fileManager: FileManager) throws {
    do {
      try fileManager.removeItem(at: url)
    } catch let error as CocoaError where error.code == .fileNoSuchFile {
      return
    } catch {
      throw PrepareError.cleanupFailed(url, String(describing: error))
    }
  }
}
