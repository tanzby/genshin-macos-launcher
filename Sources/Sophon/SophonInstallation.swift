import Foundation

/// Dotted numeric versions such as `5.10.0`. Compared per component, never as text.
public enum SophonVersion {
  static func components(_ version: String) -> [Int] {
    version.split(separator: ".").map { Int($0) ?? 0 }
  }

  public static func isOlder(_ lhs: String, than rhs: String) -> Bool {
    let (a, b) = (components(lhs), components(rhs))
    for index in 0..<max(a.count, b.count) {
      let (x, y) = (index < a.count ? a[index] : 0, index < b.count ? b[index] : 0)
      if x != y { return x < y }
    }
    return false
  }
}

/// What is on disk in a Genshin CN game directory: the installed version, `config.ini` and the temp folders.
/// Sophon owns `config.ini` because it writes the version only after the files are in place (ADR 0002).
public enum SophonInstallation {
  public static let configFileName = "config.ini"
  public static let tempDirectoryName = ".yaagl-tmp"
  static let dataFolder = "YuanShen_Data"
  static let executableName = "YuanShen.exe"
  static let emptyVersion = "0.0.0"
  static let template =
    "[General]\r\nchannel=1\r\ncps=mihoyo\r\ngame_version=\(emptyVersion)\r\nsdk_version=\r\nsub_channel=1\r\n"
  private static var versionLine: Regex<(Substring, Substring)> { /game_version=(\d+\.\d+\.\d+)/ }
  private static var managerVersion: Regex<(Substring, Substring)> { /\0(\d+\.\d+\.\d+)_\d+_\d+\0/ }

  /// Chunk cache, ldiff files, assembly folders and the launcher's `job.json`.
  public static func tempDirectory(in gameDirectory: URL) -> URL {
    gameDirectory.appending(path: tempDirectoryName, directoryHint: .isDirectory)
  }

  /// The installed version, or `nil` when there is no (complete) install: no `YuanShen.exe`, no
  /// `globalgamemanagers` yet, or `config.ini` still holds the install template's `0.0.0`. The smaller of
  /// `globalgamemanagers` and `config.ini` wins, because `config.ini` is written last (UPG-005, UPG-011).
  public static func installedVersion(in gameDirectory: URL) throws -> String? {
    let fileManager = FileManager.default
    guard fileManager.fileExists(atPath: gameDirectory.appending(path: executableName).path) else { return nil }
    // Bilibili builds carry PCGameSDK.dll; only the China official release is supported.
    guard !fileManager.fileExists(atPath: gameDirectory.appending(path: "\(dataFolder)/Plugins/PCGameSDK.dll").path)
    else { throw SophonError.brokenInstallation }
    let managers = gameDirectory.appending(path: "\(dataFolder)/globalgamemanagers")
    guard let data = try? Data(contentsOf: managers) else { return nil }
    // Latin-1 maps every byte to a character, so binary data decodes without loss and `\0` stays `\0`.
    let text = String(data: data, encoding: .isoLatin1) ?? ""
    let matches = text.matches(of: managerVersion)
    guard matches.count == 1 else { throw SophonError.brokenInstallation }
    let fromManagers = String(matches[0].output.1)

    guard let fromConfig = configVersion(in: gameDirectory) else { return fromManagers }
    if fromConfig == emptyVersion { return nil }
    return SophonVersion.isOlder(fromConfig, than: fromManagers) ? fromConfig : fromManagers
  }

  static func configVersion(in gameDirectory: URL) -> String? {
    // Not exactly one `game_version=` line counts as no usable config, the same rule `writeVersion` applies.
    guard let text = try? String(contentsOf: gameDirectory.appending(path: configFileName), encoding: .utf8) else {
      return nil
    }
    let matches = text.matches(of: versionLine)
    return matches.count == 1 ? String(matches[0].output.1) : nil
  }

  /// INS-005: a fresh install needs an empty directory, or one an interrupted install left behind (its
  /// `config.ini` still says `0.0.0`). Finder's `.DS_Store` and the temp folder do not count. Writes the
  /// template and creates the temp folder; nothing is touched when the directory is refused.
  public static func prepareForInstall(in gameDirectory: URL) throws {
    let fileManager = FileManager.default
    try fileManager.createDirectory(at: gameDirectory, withIntermediateDirectories: true)
    let names = try fileManager.contentsOfDirectory(atPath: gameDirectory.path)
    let others = names.filter { $0 != ".DS_Store" && $0 != tempDirectoryName }
    if !others.isEmpty {
      guard configVersion(in: gameDirectory) == emptyVersion else { throw SophonError.installDirectoryNotEmpty }
    }
    try fileManager.createDirectory(at: tempDirectory(in: gameDirectory), withIntermediateDirectories: true)
    try Data(template.utf8).write(to: gameDirectory.appending(path: configFileName), options: .atomic)
  }

  /// INS-006 / UPG-011: replaces the one `game_version=` line. Anything but exactly one such line is
  /// refused and the file is left alone.
  public static func writeVersion(_ version: String, in gameDirectory: URL) throws {
    let url = gameDirectory.appending(path: configFileName)
    guard let text = try? String(contentsOf: url, encoding: .utf8), text.matches(of: versionLine).count == 1 else {
      throw SophonError.invalidConfig
    }
    let updated = text.replacing(versionLine, with: "game_version=\(version)")
    try Data(updated.utf8).write(to: url, options: .atomic)
  }

  /// INS-016: the old launcher kept chunks in `<game>/.tmp` and ldiff files in `<game>/ldiff`. They are
  /// deleted only when the folder is recognisably a game directory.
  public static func removeLegacyTemporaryFolders(in gameDirectory: URL) {
    let fileManager = FileManager.default
    guard fileManager.fileExists(atPath: gameDirectory.appending(path: configFileName).path)
      || fileManager.fileExists(atPath: gameDirectory.appending(path: executableName).path)
    else { return }
    for name in [".tmp", "ldiff"] {
      try? fileManager.removeItem(at: gameDirectory.appending(path: name))
    }
  }

  /// INS-006: the quick check after a download. Every file is there with the size the manifest says.
  public static func verifySizes(of files: [SophonFile], in gameDirectory: URL) throws {
    for file in files where !file.isDirectory {
      guard try size(of: file, in: gameDirectory) == file.size else {
        throw SophonError.verificationFailed(path: file.path)
      }
    }
  }

  /// Bytes of the files that are missing or have the wrong size. Looks at sizes only, never hashes.
  public static func bytesToFetch(for files: [SophonFile], in gameDirectory: URL) throws -> Int64 {
    try files.filter { !$0.isDirectory }.reduce(Int64(0)) { sum, file in
      try size(of: file, in: gameDirectory) == file.size ? sum : sum + file.size
    }
  }

  private static func size(of file: SophonFile, in gameDirectory: URL) throws -> Int64? {
    let url = try SophonPathPolicy.resolve(file.path, in: gameDirectory)
    return ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber)?.int64Value
  }
}
