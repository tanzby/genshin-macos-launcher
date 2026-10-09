import Foundation
import Platform

/// A downloadable Wine build. ADR 0001 pins exactly one; there is no version picker.
public struct WineDistribution: Sendable, Equatable {
  public var id: String
  public var url: URL
  public var sha256: String
  /// Directory inside the archive that holds the Wine tree, stripped on extraction. `nil` = whole archive.
  public var winePath: String?
  /// Size of the download in bytes, for the free-space preflight.
  public var archiveSize: Int64
  /// Size of the unpacked runtime in bytes.
  public var installedSize: Int64

  public init(
    id: String, url: URL, sha256: String, winePath: String? = nil, archiveSize: Int64 = 0, installedSize: Int64 = 0
  ) {
    self.id = id
    self.url = url
    self.sha256 = sha256
    self.winePath = winePath
    self.archiveSize = archiveSize
    self.installedSize = installedSize
  }

  public static let pinned = WineDistribution(
    id: WineRuntime.pinnedVersion,
    url: URL(
      string:
        "https://github.com/yaagl/anime-game-wine/releases/download/wine-crossover-11.0-1-signed/wine-crossover-11.0-1-osx64-signed.tar.xz"
    )!,
    sha256: "89fa7e90fb626523a90d5867a03c6be785d017176739c6320a3b86c7838c3a35",
    winePath: "wine",
    archiveSize: 456_021_524,
    installedSize: 2_000_000_000
  )
}

/// The DXMT build installed together with Wine. Names are derived from one description.
public struct DXMTRelease: Sendable, Equatable {
  public var version: String
  public var commit: String
  public var zipURL: URL
  public var sha256: String
  public var archiveSize: Int64

  public init(version: String, commit: String, zipURL: URL, sha256: String, archiveSize: Int64 = 0) {
    self.version = version
    self.commit = commit
    self.zipURL = zipURL
    self.sha256 = sha256
    self.archiveSize = archiveSize
  }

  public static let pinned = DXMTRelease(
    version: "654f547",
    commit: "654f547ffab4e0c395ee368aad52bb4586b04576",
    zipURL: URL(
      string:
        "https://github.com/yaagl/anime-game-wine/releases/download/dxmt-654f547/dxmt-654f547ffab4e0c395ee368aad52bb4586b04576.zip"
    )!,
    sha256: "fbc0721fb72ebafd2bad0dbdd3d13a52056fd10c4a9a699cee2689363823255b",
    archiveSize: 32_603_639
  )
}

/// Written last when an install completes, inside `wine/`, so it disappears with the runtime.
public struct WineStamp: Codable, Sendable, Equatable {
  public static let currentSchemaVersion = 1

  public var schemaVersion: Int
  public var wineVersion: String
  public var dxmtVersion: String

  public init(schemaVersion: Int = Self.currentSchemaVersion, wineVersion: String, dxmtVersion: String) {
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
  public var stampFile: URL { runtimeDirectory.appending(path: ".yaagl-wine-stamp.json", directoryHint: .notDirectory) }
  public var wineserver: URL { runtimeDirectory.appending(path: "bin/wineserver", directoryHint: .notDirectory) }
  public var windowsLibraryDirectory: URL {
    runtimeDirectory.appending(path: "lib/wine/x86_64-windows", directoryHint: .isDirectory)
  }
  public var unixLibraryDirectory: URL {
    runtimeDirectory.appending(path: "lib/wine/x86_64-unix", directoryHint: .isDirectory)
  }
  public var prefixSystem32: URL {
    prefixDirectory.appending(path: "drive_c/windows/system32", directoryHint: .isDirectory)
  }
  /// DXMT files that replace the stock ones in `x86_64-windows`.
  static let dxmtWindowsFiles = ["d3d10core.dll", "d3d11.dll", "dxgi.dll", "winemetal.dll"]

  /// Written by `GameSession` before it mutates anything; deleted after the restore. Its presence means a crash.
  public var launchJournal: URL { root.appending(path: "launch-journal.json", directoryHint: .notDirectory) }
  public var configBatch: URL { root.appending(path: "config.bat", directoryHint: .notDirectory) }
  public var logsDirectory: URL { root.appending(path: "logs", directoryHint: .isDirectory) }
  public var gameHostApp: URL { root.appending(path: "YaaglGame.app", directoryHint: .isDirectory) }
  /// `lib/wine/x86_64-unix/wine`: Wine execs this for every new Windows process. The Game Mode shim replaces it.
  public var unixWine: URL { unixLibraryDirectory.appending(path: "wine", directoryHint: .notDirectory) }
  /// The original `wine`, renamed by the Game Mode shim install.
  public var unixWineHost: URL { unixLibraryDirectory.appending(path: "wine-host", directoryHint: .notDirectory) }
  public var prefixWindows: URL {
    prefixDirectory.appending(path: "drive_c/windows", directoryHint: .isDirectory)
  }

  /// Archives being downloaded; partial files here let an interrupted install resume.
  public var downloadsDirectory: URL { root.appending(path: "downloads", directoryHint: .isDirectory) }
  public var wineBootLog: URL { root.appending(path: "wineboot.log", directoryHint: .notDirectory) }
  public var wineCfgLog: URL { root.appending(path: "winecfg.log", directoryHint: .notDirectory) }

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
  /// The stamp is unreadable or names another Wine or DXMT version.
  case versionMismatch
  /// The stamp matches but a required file is gone (loader, DXMT files, prefix).
  case corrupt(missing: String)
}

public enum WineStatus: Sendable, Equatable {
  case ready
  case needsInstall(WineReinstallReason)
}

public enum WineInstallProgress: Sendable, Equatable {
  case downloadingWine(DownloadProgress)
  case downloadingDXMT(DownloadProgress)
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
  case dxmtArchiveInvalid
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
