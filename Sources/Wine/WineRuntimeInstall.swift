import Foundation
import Platform

extension WineRuntime {
  func currentStatus() -> WineStatus {
    let fileManager = FileManager.default
    var isDirectory: ObjCBool = false
    guard fileManager.fileExists(atPath: layout.runtimeDirectory.path, isDirectory: &isDirectory), isDirectory.boolValue
    else {
      return .needsInstall(.notInstalled)
    }
    guard fileManager.fileExists(atPath: layout.stampFile.path) else {
      return .needsInstall(.interrupted)
    }
    guard let data = try? Data(contentsOf: layout.stampFile),
      let stamp = try? JSONDecoder().decode(WineStamp.self, from: data),
      stamp.schemaVersion == WineStamp.currentSchemaVersion,
      stamp.wineVersion == distribution.id
    else {
      return .needsInstall(.versionMismatch)
    }
    // Only files this installer owns. `lib/wine/x86_64-unix/wine` and `wine-host` are deliberately not
    // listed: the Game Mode shim install renames them later.
    let required: [(String, URL)] = [
      ("bin/wine", layout.loader),
      ("bin/wineserver", layout.wineserver),
      ("prefix", layout.prefixDirectory),
      ("prefix/winemetal.dll", layout.prefixSystem32.appending(path: "winemetal.dll")),
    ] + WineLayout.dxmtWindowsFiles.map { ("lib/\($0)", layout.windowsLibraryDirectory.appending(path: $0)) }
      + [("lib/winemetal.so", layout.unixLibraryDirectory.appending(path: "winemetal.so"))]
    for (name, url) in required where !fileManager.fileExists(atPath: url.path) {
      return .needsInstall(.corrupt(missing: name))
    }
    // An app without DXMT (a development build) cannot judge it and keeps what is installed.
    if let dxmt, stamp.dxmtVersion != dxmt.version { return .needsInstall(.dxmtOutdated) }
    return .ready
  }

  func performInstall(progress: @escaping @Sendable (WineInstallProgress) -> Void) async throws {
    let fileManager = FileManager.default
    // Scratch directories that older builds created and could leave behind when killed mid-way.
    if let stale = try? fileManager.contentsOfDirectory(atPath: layout.root.path) {
      for name in stale where name.hasPrefix(".install-") {
        try? fileManager.removeItem(at: layout.root.appending(path: name))
      }
    }

    // The archive sits at a stable path with a name derived from the checksum: an interrupted download resumes
    // there on the next attempt (WIN-007).
    let wineArchive = layout.downloadsDirectory.appending(
      path: "wine-\(distribution.sha256.prefix(16)).archive", directoryHint: .notDirectory)

    // 0. DXMT comes with the app. Without it nothing is downloaded or deleted.
    let dxmtFiles = try bundledDXMTFiles()

    // 1. Free space, before anything is downloaded or deleted (WIN-006). An unreadable volume does not block.
    //    On the data volume at the same time: the archive, the unpacked runtime and the new prefix `wineboot`
    //    fills. Bytes of an archive that is already there (finished or partial) are on the volume and no
    //    longer needed.
    let required =
      max(0, distribution.archiveSize - Self.bytesOnDisk(of: wineArchive))
      + distribution.installedSize + distribution.prefixSize
    if let available = availableSpace(layout.root), available < required {
      throw WineInstallError.insufficientDiskSpace(required: required, available: available)
    }

    // 2. Download and verify the archive before touching the working install, so a network failure leaves
    //    the existing runtime and prefix alone.
    try fileManager.createDirectory(at: layout.downloadsDirectory, withIntermediateDirectories: true)
    do {
      try await downloader.download(from: distribution.url, to: wineArchive, sha256: distribution.sha256) {
        progress(.downloadingWine($0))
      }
    } catch {
      // A partial file stays for the next attempt; an empty directory does not.
      removeIfEmpty(layout.downloadsDirectory)
      throw error
    }

    // 3. Replace the runtime and prefix (WIN-006). The stamp is gone with `wine/`, so an interruption
    //    from here on reads as `.interrupted`.
    progress(.extracting)
    // An orphaned wineserver on the old prefix must not outlive the prefix it serves.
    if fileManager.fileExists(atPath: layout.wineserver.path) {
      _ = try? await runner.run(
        layout.wineserver, arguments: ["-k"], environment: ["WINEPREFIX": layout.prefixDirectory.path],
        workingDirectory: layout.root)
    }
    try removeIfPresent(layout.runtimeDirectory)
    try removeIfPresent(layout.prefixDirectory)
    try fileManager.createDirectory(at: layout.runtimeDirectory, withIntermediateDirectories: true)
    var arguments = ["-xf", wineArchive.path, "-C", layout.runtimeDirectory.path]
    if let winePath = distribution.winePath {
      let depth = winePath.split(separator: "/").count
      arguments += ["--strip-components=\(depth)", winePath]
    }
    try await runTool("/usr/bin/tar", arguments)

    // 4. Root certificate, before wineboot (WIN-009).
    progress(.configuring)
    let wineInf = layout.runtimeDirectory.appending(path: "share/wine/wine.inf")
    let original = try String(contentsOf: wineInf, encoding: .utf8)
    try WineInf.injectingCertificate(into: original).write(to: wineInf, atomically: true, encoding: .utf8)

    // 5. Prefix (WIN-012) with the stock DLLs, as the TS launcher did.
    progress(.initializingPrefix)
    try await initializePrefix()

    // 6. DXMT, once, after the prefix exists (WIN-020). No .bak: nothing is restored at launch.
    progress(.installingDXMT)
    try installDXMT(from: dxmtFiles)

    // 7. Stamp last.
    progress(.finalizing)
    try writeStamp()

    // Done: the verified archive is no longer needed. After a failure it stays, so a retry does not download again.
    try? fileManager.removeItem(at: layout.downloadsDirectory)
  }

  private func runTool(_ path: String, _ arguments: [String]) async throws {
    let result = try await runner.run(
      URL(filePath: path), arguments: arguments, environment: [:], workingDirectory: layout.root)
    guard result.exitCode == 0 else {
      throw WineInstallError.extractionFailed(
        tool: URL(filePath: path).lastPathComponent, exitCode: result.exitCode,
        output: String(result.output.suffix(Self.toolOutputLimit)))
    }
  }

  /// The files to install, checked up front so a broken app fails before anything is deleted.
  private func bundledDXMTFiles() throws -> DXMTBundle {
    guard let dxmt else { throw WineInstallError.dxmtBundleInvalid }
    let fileManager = FileManager.default
    guard
      WineLayout.dxmtWindowsFiles.allSatisfy({
        fileManager.fileExists(atPath: dxmt.windowsDirectory.appending(path: $0).path)
      }),
      fileManager.fileExists(atPath: dxmt.unixDirectory.appending(path: "winemetal.so").path)
    else { throw WineInstallError.dxmtBundleInvalid }
    return dxmt
  }

  /// A newer DXMT arrived with an app update: replace its files and the stamp, keep Wine and the prefix.
  func refreshDXMT(progress: @escaping @Sendable (WineInstallProgress) -> Void) async throws {
    let files = try bundledDXMTFiles()
    // A running game holds the old winemetal.so; the launcher only refreshes while nothing runs.
    progress(.installingDXMT)
    try installDXMT(from: files)
    progress(.finalizing)
    try writeStamp()
  }

  private func writeStamp() throws {
    let stamp = WineStamp(wineVersion: distribution.id, dxmtVersion: dxmt?.version ?? "")
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try encoder.encode(stamp).write(to: layout.stampFile, options: .atomic)
  }

  private func initializePrefix() async throws {
    let steps: [(arguments: [String], log: URL)] = [
      (["wineboot", "-u"], layout.wineBootLog),
      (["winecfg", "-v", "win10"], layout.wineCfgLog),
    ]
    for step in steps {
      let result = try await runner.run(
        layout.loader, arguments: step.arguments, environment: layout.wineEnvironment, workingDirectory: layout.root)
      try? result.output.write(to: step.log, atomically: true, encoding: .utf8)
      // TS reported wineboot.log for either failure (WIN-012 edge case); each step reports its own log here.
      guard result.exitCode == 0 else { throw WineInstallError.prefixInitializationFailed(logURL: step.log) }
    }
  }

  private func installDXMT(from files: DXMTBundle) throws {
    let fileManager = FileManager.default
    try fileManager.createDirectory(at: layout.windowsLibraryDirectory, withIntermediateDirectories: true)
    try fileManager.createDirectory(at: layout.unixLibraryDirectory, withIntermediateDirectories: true)
    try fileManager.createDirectory(at: layout.prefixSystem32, withIntermediateDirectories: true)
    for name in WineLayout.dxmtWindowsFiles {
      try replace(files.windowsDirectory.appending(path: name), with: layout.windowsLibraryDirectory.appending(path: name))
    }
    try replace(files.unixDirectory.appending(path: "winemetal.so"), with: layout.unixLibraryDirectory.appending(path: "winemetal.so"))
    try replace(
      files.windowsDirectory.appending(path: "winemetal.dll"), with: layout.prefixSystem32.appending(path: "winemetal.dll"))
  }

  private func replace(_ source: URL, with destination: URL) throws {
    try removeIfPresent(destination)
    try FileManager.default.copyItem(at: source, to: destination)
    // An app that came from a quarantined download passes the flag on to what we copy out of it.
    try Quarantine.remove(from: destination)
  }

  static let toolOutputLimit = 2000

  /// Size of a finished download plus its `.part`, 0 if neither exists.
  static func bytesOnDisk(of archive: URL) -> Int64 {
    Downloader.fileSize(archive) + Downloader.fileSize(URL(filePath: archive.path + ".part"))
  }

  private func removeIfEmpty(_ directory: URL) {
    let entries = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
    if entries.isEmpty { try? FileManager.default.removeItem(at: directory) }
  }

  private func removeIfPresent(_ url: URL) throws {
    if FileManager.default.fileExists(atPath: url.path) || (try? url.checkResourceIsReachable()) == true {
      try FileManager.default.removeItem(at: url)
    }
  }
}
