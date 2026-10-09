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
      stamp.wineVersion == distribution.id,
      stamp.dxmtVersion == dxmt.version
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
    return .ready
  }

  func performInstall(progress: @escaping @Sendable (WineInstallProgress) -> Void) async throws {
    let fileManager = FileManager.default
    // Scratch directories of installs that were killed mid-way.
    if let stale = try? fileManager.contentsOfDirectory(atPath: layout.root.path) {
      for name in stale where name.hasPrefix(".install-") {
        try? fileManager.removeItem(at: layout.root.appending(path: name))
      }
    }
    let scratch = layout.root.appending(path: ".install-\(UUID().uuidString)", directoryHint: .isDirectory)
    try fileManager.createDirectory(at: scratch, withIntermediateDirectories: true)
    defer { try? fileManager.removeItem(at: scratch) }

    // 0. Free space, before anything is downloaded or deleted (WIN-006). An unreadable volume does not block.
    //    On the data volume at the same time: the Wine archive and the unpacked runtime, plus the DXMT zip,
    //    its tar.gz and the unpacked files (taken as 4 x the zip).
    let required = distribution.archiveSize + 4 * dxmt.archiveSize + distribution.installedSize
    if let available = availableSpace(layout.root), available < required {
      throw WineInstallError.insufficientDiskSpace(required: required, available: available)
    }

    // 1. Download and verify both archives before touching the working install, so a network failure leaves
    //    the existing runtime and prefix alone. They go to a stable path with a name derived from the checksum:
    //    an interrupted download resumes there on the next attempt (WIN-007), and the two run in parallel.
    try fileManager.createDirectory(at: layout.downloadsDirectory, withIntermediateDirectories: true)
    let wineArchive = layout.downloadsDirectory.appending(
      path: "wine-\(distribution.sha256.prefix(16)).archive", directoryHint: .notDirectory)
    let dxmtArchive = layout.downloadsDirectory.appending(
      path: "dxmt-\(dxmt.sha256.prefix(16)).zip", directoryHint: .notDirectory)
    let downloader = downloader, distribution = distribution, dxmt = dxmt
    do {
      try await withThrowingTaskGroup(of: Void.self) { group in
        group.addTask {
          try await downloader.download(from: distribution.url, to: wineArchive, sha256: distribution.sha256) {
            progress(.downloadingWine($0))
          }
        }
        group.addTask {
          try await downloader.download(from: dxmt.zipURL, to: dxmtArchive, sha256: dxmt.sha256) {
            progress(.downloadingDXMT($0))
          }
        }
        try await group.waitForAll()
      }
    } catch {
      // Partial files stay for the next attempt; an empty directory does not.
      removeIfEmpty(layout.downloadsDirectory)
      throw error
    }

    // 2. Unpack DXMT into scratch while nothing is destroyed yet; an invalid archive fails early.
    let dxmtFiles = try await unpackDXMT(zip: dxmtArchive, in: scratch)

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
    try? fileManager.removeItem(at: wineArchive)

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
    let stamp = WineStamp(wineVersion: distribution.id, dxmtVersion: dxmt.version)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try encoder.encode(stamp).write(to: layout.stampFile, options: .atomic)

    // Done: the verified archives are no longer needed. After a failure they stay, so a retry does not download again.
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

  private func unpackDXMT(zip: URL, in scratch: URL) async throws -> DXMTFiles {
    let unzipped = scratch.appending(path: "dxmt-zip", directoryHint: .isDirectory)
    let unpacked = scratch.appending(path: "dxmt", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: unzipped, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: unpacked, withIntermediateDirectories: true)
    try await runTool("/usr/bin/ditto", ["-x", "-k", zip.path, unzipped.path])
    let inner = unzipped.appending(path: "dxmt-\(dxmt.commit).tar.gz")
    guard FileManager.default.fileExists(atPath: inner.path) else { throw WineInstallError.dxmtArchiveInvalid }
    try await runTool("/usr/bin/tar", ["-xf", inner.path, "-C", unpacked.path])
    let root = unpacked.appending(path: dxmt.commit, directoryHint: .isDirectory)
    let windows = root.appending(path: "x86_64-windows", directoryHint: .isDirectory)
    let unix = root.appending(path: "x86_64-unix", directoryHint: .isDirectory)
    let fileManager = FileManager.default
    guard WineLayout.dxmtWindowsFiles.allSatisfy({ fileManager.fileExists(atPath: windows.appending(path: $0).path) }),
      fileManager.fileExists(atPath: unix.appending(path: "winemetal.so").path)
    else { throw WineInstallError.dxmtArchiveInvalid }
    return DXMTFiles(windows: windows, unix: unix)
  }

  private func initializePrefix() async throws {
    let environment = ["WINEPREFIX": layout.prefixDirectory.path, "WINEDEBUG": "fixme-all,err-unwind,+timestamp"]
    let steps: [(arguments: [String], log: URL)] = [
      (["wineboot", "-u"], layout.wineBootLog),
      (["winecfg", "-v", "win10"], layout.wineCfgLog),
    ]
    for step in steps {
      let result = try await runner.run(
        layout.loader, arguments: step.arguments, environment: environment, workingDirectory: layout.root)
      try? result.output.write(to: step.log, atomically: true, encoding: .utf8)
      // TS reported wineboot.log for either failure (WIN-012 edge case); each step reports its own log here.
      guard result.exitCode == 0 else { throw WineInstallError.prefixInitializationFailed(logURL: step.log) }
    }
  }

  private func installDXMT(from files: DXMTFiles) throws {
    let fileManager = FileManager.default
    try fileManager.createDirectory(at: layout.windowsLibraryDirectory, withIntermediateDirectories: true)
    try fileManager.createDirectory(at: layout.unixLibraryDirectory, withIntermediateDirectories: true)
    try fileManager.createDirectory(at: layout.prefixSystem32, withIntermediateDirectories: true)
    for name in WineLayout.dxmtWindowsFiles {
      try replace(files.windows.appending(path: name), with: layout.windowsLibraryDirectory.appending(path: name))
    }
    try replace(files.unix.appending(path: "winemetal.so"), with: layout.unixLibraryDirectory.appending(path: "winemetal.so"))
    try replace(
      files.windows.appending(path: "winemetal.dll"), with: layout.prefixSystem32.appending(path: "winemetal.dll"))
  }

  private func replace(_ source: URL, with destination: URL) throws {
    try removeIfPresent(destination)
    try FileManager.default.copyItem(at: source, to: destination)
  }

  static let toolOutputLimit = 2000

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

struct DXMTFiles {
  var windows: URL
  var unix: URL
}
