import Foundation
import Platform

/// A downloadable Wine build. ADR 0001 pins exactly one; there is no version picker.
package struct WineDistribution: Sendable, Equatable {
  package var id: String
  package var url: URL
  package var sha256: String
  /// Directory inside the archive that holds the Wine tree, stripped on extraction. `nil` = whole archive.
  package var winePath: String?
  /// Size of the download in bytes, for the free-space preflight.
  package var archiveSize: Int64
  /// Size of the unpacked runtime in bytes.
  package var installedSize: Int64
  /// Size of a fresh prefix after `wineboot`, created after the old runtime is gone.
  package var prefixSize: Int64

  package init(
    id: String, url: URL, sha256: String, winePath: String? = nil, archiveSize: Int64 = 0, installedSize: Int64 = 0,
    prefixSize: Int64 = 0
  ) {
    self.id = id
    self.url = url
    self.sha256 = sha256
    self.winePath = winePath
    self.archiveSize = archiveSize
    self.installedSize = installedSize
    self.prefixSize = prefixSize
  }

  package static let pinned = WineDistribution(
    id: WineRuntime.pinnedVersion,
    url: URL(
      string:
        "https://github.com/yaagl/anime-game-wine/releases/download/wine-crossover-11.0-1-signed/wine-crossover-11.0-1-osx64-signed.tar.xz"
    )!,
    sha256: "89fa7e90fb626523a90d5867a03c6be785d017176739c6320a3b86c7838c3a35",
    winePath: "wine",
    archiveSize: 456_021_524,
    installedSize: 2_100_000_000,
    prefixSize: 600_000_000
  )
}

/// The DXMT build that ships inside the app (`Contents/Resources/dxmt`, built by `scripts/build-dxmt` from the
/// pinned `third_party/dxmt` submodule, docs/adr/0003). The composition root finds it; `Wine` never reads
/// `Bundle.main`.
public struct DXMTBundle: Sendable, Equatable {
  /// Holds `x86_64-windows/`, `x86_64-unix/` and `VERSION`.
  public var directory: URL
  /// The DXMT commit; compared with the stamp to decide whether the installed files are current.
  public var version: String

  public init(directory: URL, version: String) {
    self.directory = directory
    self.version = version
  }

  /// `nil` when the directory has no readable `VERSION` (a build that did not run `scripts/build-dxmt`).
  public static func load(from directory: URL) -> DXMTBundle? {
    let file = directory.appending(path: "VERSION", directoryHint: .notDirectory)
    guard let text = try? String(contentsOf: file, encoding: .utf8) else { return nil }
    let version = text.trimmingCharacters(in: .whitespacesAndNewlines)
    return version.isEmpty ? nil : DXMTBundle(directory: directory, version: version)
  }

  /// For the Wine settings page.
  public var shortVersion: String { String(version.prefix(7)) }

  var windowsDirectory: URL { directory.appending(path: "x86_64-windows", directoryHint: .isDirectory) }
  var unixDirectory: URL { directory.appending(path: "x86_64-unix", directoryHint: .isDirectory) }
}

/// Written last when an install completes, inside `wine/`, so it disappears with the runtime.
struct WineStamp: Codable, Sendable, Equatable {
  static let currentSchemaVersion = 1

  var schemaVersion: Int
  var wineVersion: String
  var dxmtVersion: String

  init(schemaVersion: Int = Self.currentSchemaVersion, wineVersion: String, dxmtVersion: String) {
    self.schemaVersion = schemaVersion
    self.wineVersion = wineVersion
    self.dxmtVersion = dxmtVersion
  }
}

/// Where everything lives under the data directory.
public struct WineLayout: Sendable, Equatable {
  public let root: URL

  public init(root: URL) {
    self.root = root
  }

  public var runtimeDirectory: URL { root.appending(path: "wine", directoryHint: .isDirectory) }
  public var prefixDirectory: URL { root.appending(path: "wineprefix", directoryHint: .isDirectory) }
  package var stampFile: URL { runtimeDirectory.appending(path: ".genshin-launcher-wine-stamp.json", directoryHint: .notDirectory) }
  public var wineserver: URL { runtimeDirectory.appending(path: "bin/wineserver", directoryHint: .notDirectory) }
  package var windowsLibraryDirectory: URL {
    runtimeDirectory.appending(path: "lib/wine/x86_64-windows", directoryHint: .isDirectory)
  }
  package var unixLibraryDirectory: URL {
    runtimeDirectory.appending(path: "lib/wine/x86_64-unix", directoryHint: .isDirectory)
  }
  package var prefixSystem32: URL {
    prefixDirectory.appending(path: "drive_c/windows/system32", directoryHint: .isDirectory)
  }
  /// DXMT files that replace the stock ones in `x86_64-windows`.
  static let dxmtWindowsFiles = ["d3d10core.dll", "d3d11.dll", "dxgi.dll", "winemetal.dll"]

  /// Written by `GameSession` before it mutates anything; deleted after the restore. Its presence means a crash.
  package var launchJournal: URL { root.appending(path: "launch-journal.json", directoryHint: .notDirectory) }
  public var logsDirectory: URL { root.appending(path: "logs", directoryHint: .isDirectory) }
  package var gameHostApp: URL { root.appending(path: "GenshinLauncherGame.app", directoryHint: .isDirectory) }
  /// `lib/wine/x86_64-unix/wine`: Wine execs this for every new Windows process. The Game Mode shim replaces it.
  package var unixWine: URL { unixLibraryDirectory.appending(path: "wine", directoryHint: .notDirectory) }
  /// The original `wine`, renamed by the Game Mode shim install.
  package var unixWineHost: URL { unixLibraryDirectory.appending(path: "wine-host", directoryHint: .notDirectory) }
  package var prefixWindows: URL {
    prefixDirectory.appending(path: "drive_c/windows", directoryHint: .isDirectory)
  }

  /// Archives being downloaded; partial files here let an interrupted install resume.
  package var downloadsDirectory: URL { root.appending(path: "downloads", directoryHint: .isDirectory) }
  package var wineBootLog: URL { root.appending(path: "wineboot.log", directoryHint: .notDirectory) }
  package var wineCfgLog: URL { root.appending(path: "winecfg.log", directoryHint: .notDirectory) }

  static let wineDebug = "fixme-all,err-unwind,+timestamp"
  /// What every Wine process gets: the prefix and the debug channels (WIN-016).
  var wineEnvironment: [String: String] { ["WINEPREFIX": prefixDirectory.path, "WINEDEBUG": Self.wineDebug] }

  /// `bin/wine64` when present, else `bin/wine` (WIN-016).
  public var loader: URL {
    let wine64 = runtimeDirectory.appending(path: "bin/wine64", directoryHint: .notDirectory)
    if FileManager.default.fileExists(atPath: wine64.path) { return wine64 }
    return runtimeDirectory.appending(path: "bin/wine", directoryHint: .notDirectory)
  }
}

public enum WineReinstallReason: Sendable, Equatable {
  /// No `wine/` directory at all.
  case notInstalled
  /// `wine/` exists but the stamp does not: an install was interrupted.
  case interrupted
  /// The stamp is unreadable or names another Wine version.
  case versionMismatch
  /// Wine is current but the installed DXMT is not the one in the app. Refreshing it copies a few files; Wine
  /// and the prefix stay.
  case dxmtOutdated
  /// The stamp matches but a required file is gone (loader, DXMT files, prefix).
  case corrupt(missing: String)
}

public enum WineStatus: Sendable, Equatable {
  case ready
  case needsInstall(WineReinstallReason)
}

public enum WineInstallProgress: Sendable, Equatable {
  case downloadingWine(DownloadProgress)
  case extracting
  case configuring
  case initializingPrefix
  case installingDXMT
  case finalizing
}

public enum WineInstallError: Error, Equatable {
  /// A system tool (`tar`, `ditto`) exited non-zero.
  case extractionFailed(tool: String, exitCode: Int32, output: String)
  /// Not enough free space on the data volume; raised before anything is downloaded or deleted.
  case insufficientDiskSpace(required: Int64, available: Int64)
  /// The app has no DXMT, or it lacks a file the launcher installs. Raised before anything is deleted.
  case dxmtBundleInvalid
  /// `wineboot` or `winecfg` failed; the log is at `logURL`.
  case prefixInitializationFailed(logURL: URL)
  case certificateSectionNotFound
}

enum WineInf {
  /// Inserts the root CA after the `; URL Associations` section (WIN-009). Idempotent.
  static func injectingCertificate(into contents: String) throws -> String {
    let thumbprint = "F09065E2D57F005BBD975DDCF9EB63F570764F17"
    if contents.contains(thumbprint) { return contents }
    var lines = contents.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
    guard let marker = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "; URL Associations" }),
      let blank = lines[(marker + 1)...].firstIndex(where: { $0.trimmingCharacters(in: .whitespaces).isEmpty })
    else {
      throw WineInstallError.certificateSectionNotFound
    }
    let block = WineInfCertificate.block.components(separatedBy: "\n")
    lines.insert(contentsOf: [""] + block, at: blank)
    return lines.joined(separator: "\n")
  }
}
