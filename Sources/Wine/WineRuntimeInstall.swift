import Foundation
import Platform

extension WineRuntime {
  /// Whether the pinned Wine and `backend`'s runtime are installed and intact.
  public func status(for backend: GraphicsBackend) -> WineStatus {
    let layout = layout(for: backend)
    if backend == .gptk4, gptk4 == nil { return .needsInstall(.backendUnavailable) }
    if prefixNeedsManualRecovery(layout) { return .needsInstall(.prefixUnrecognized) }
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
      stamp.graphicsBackend == backend
    else {
      return .needsInstall(.versionMismatch)
    }
    guard prefixIsRecognized(layout.prefixDirectory) else {
      return FileManager.default.fileExists(atPath: layout.prefixDirectory.path)
        ? .needsInstall(.prefixUnrecognized)
        : .needsInstall(.corrupt(missing: "prefix"))
    }
    // Only files this installer owns. `lib/wine/x86_64-unix/wine` and `wine-host` are deliberately not
    // listed: the Game Mode shim install renames them later.
    let required: [(String, URL)] = [
      ("bin/wine", layout.loader),
      ("bin/wineserver", layout.wineserver),
    ] + requiredBackendFiles(backend, layout: layout)
    for (name, url) in required where !fileManager.fileExists(atPath: url.path) {
      return .needsInstall(.corrupt(missing: name))
    }
    switch backend {
    case .dxmt:
      // A build without DXMT cannot judge the installed version and keeps what is installed.
      if let dxmt, stamp.dxmtVersion != dxmt.version { return .needsInstall(.dxmtOutdated) }
    case .gptk4:
      guard let gptk4 else { return .needsInstall(.backendUnavailable) }
      if stamp.gptkVersion != gptk4.version { return .needsInstall(.versionMismatch) }
    }
    return .ready
  }

  func performInstall(
    for backend: GraphicsBackend, progress: @escaping @Sendable (WineInstallProgress) -> Void
  ) async throws {
    let layout = layout(for: backend)
    let fileManager = FileManager.default
    // Scratch directories that older builds created and could leave behind when killed mid-way.
    if let stale = try? fileManager.contentsOfDirectory(atPath: layout.root.path) {
      for name in stale where name.hasPrefix(".install-") {
        try? fileManager.removeItem(at: layout.root.appending(path: name))
      }
    }
    // The free-space check below reads the volume of `root`, so it has to exist first.
    try fileManager.createDirectory(at: layout.root, withIntermediateDirectories: true)

    // The archive sits at a stable path with a name derived from the checksum: an interrupted download resumes
    // there on the next attempt (WIN-007).
    let wineArchive = layout.downloadsDirectory.appending(
      path: "wine-\(distribution.sha256.prefix(16)).archive", directoryHint: .notDirectory)

    // 0. Validate all app resources before touching the installed runtime.
    let payload: BackendPayload
    switch backend {
    case .dxmt: payload = .dxmt(try validatedDXMT())
    case .gptk4: payload = .gptk4(try validatedGPTK4())
    }

    // 1. Free space, before anything is downloaded or deleted (WIN-006). An unreadable volume does not block.
    //    On the data volume at the same time: the archive, the unpacked runtime and the new prefix `wineboot`
    //    fills. Bytes of an archive that is already there (finished or partial) are on the volume and no
    //    longer needed.
    let prefixAlreadyExists = prefixIsRecognized(layout.prefixDirectory)
    let required = max(0, distribution.archiveSize - Self.bytesOnDisk(of: wineArchive))
      + distribution.installedSize + (prefixAlreadyExists ? 0 : distribution.prefixSize)
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

    // 3. Replace only this backend's runtime. The other runtime and the shared prefix stay in place.
    progress(.extracting)
    if fileManager.fileExists(atPath: layout.wineserver.path) {
      _ = try? await WinePrefixCommands(layout: layout, runner: runner).wineserver("-k")
    }
    try removeIfPresent(layout.runtimeDirectory)
    try fileManager.createDirectory(at: layout.runtimeDirectory, withIntermediateDirectories: true)
    var arguments = ["-xf", wineArchive.path, "-C", layout.runtimeDirectory.path]
    if let winePath = distribution.winePath {
      let depth = winePath.split(separator: "/").count
      arguments += ["--strip-components=\(depth)", winePath]
    }
    try await runTool("/usr/bin/tar", arguments, layout: layout)

    // 4. Root certificate, before wineboot (WIN-009).
    progress(.configuring)
    let wineInf = layout.runtimeDirectory.appending(path: "share/wine/wine.inf")
    let original = try String(contentsOf: wineInf, encoding: .utf8)
    try WineInf.injectingCertificate(into: original).write(to: wineInf, atomically: true, encoding: .utf8)

    // Initialize only an absent/empty prefix or retry a prefix creation interrupted by this installer.
    progress(.initializingPrefix)
    try await initializePrefixIfNeeded(layout)

    switch payload {
    case .dxmt(let bundle):
      progress(.installingDXMT)
      try installDXMTRuntime(from: bundle, layout: layout)
      try installDXMTPrefix(from: bundle, layout: layout)
    case .gptk4(let bundle):
      progress(.installingGPTK4)
      try await installGPTK4(from: bundle, layout: layout)
    }

    // Stamp last; a missing/mismatched stamp never authorizes deleting the shared prefix.
    progress(.finalizing)
    try writeStamp(backend: backend, layout: layout)

    // The verified archive serves the other backend's install too. Once every backend the app carries is
    // installed it is no longer needed; after a failure it stays, so a retry does not download again.
    let carried = GraphicsBackend.allCases.filter { $0 == .dxmt ? dxmt != nil : gptk4 != nil }
    let stamps = carried.map { self.layout(for: $0).stampFile.path }
    if stamps.allSatisfy(fileManager.fileExists(atPath:)) {
      try? fileManager.removeItem(at: layout.downloadsDirectory)
    }
  }

  /// The app-bundled files of the backend being installed, validated before anything is deleted.
  private enum BackendPayload {
    case dxmt(DXMTBundle)
    case gptk4(GPTK4Bundle)
  }

  private func runTool(_ path: String, _ arguments: [String], layout: WineLayout) async throws {
    let result = try await runner.run(
      URL(filePath: path), arguments: arguments, environment: [:], workingDirectory: layout.root)
    guard result.exitCode == 0 else {
      throw WineInstallError.extractionFailed(
        tool: URL(filePath: path).lastPathComponent, exitCode: result.exitCode,
        output: String(result.output.suffix(Self.toolOutputLimit)))
    }
  }

  /// The files to install, checked up front so a broken app fails before anything is deleted.
  private func validatedDXMT() throws -> DXMTBundle {
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

  private func validatedGPTK4() throws -> GPTK4Bundle {
    guard let gptk4, gptk4.version == GPTK4Bundle.expectedVersion, GPTK4Bundle.isComplete(gptk4.directory)
    else { throw WineInstallError.gptk4BundleInvalid }
    return gptk4
  }

  private func requiredBackendFiles(_ backend: GraphicsBackend, layout: WineLayout) -> [(String, URL)] {
    switch backend {
    case .dxmt:
      return [
        ("prefix/winemetal.dll", layout.prefixSystem32.appending(path: "winemetal.dll")),
      ] + WineLayout.dxmtWindowsFiles.map { ("lib/\($0)", layout.windowsLibraryDirectory.appending(path: $0)) }
        + [("lib/winemetal.so", layout.unixLibraryDirectory.appending(path: "winemetal.so"))]
    case .gptk4:
      let targetRoot = layout.runtimeDirectory.appending(path: "lib", directoryHint: .isDirectory)
      return GPTK4Bundle.requiredFiles.map { ("lib/\($0)", targetRoot.appending(path: $0)) }
    }
  }

  private func installGPTK4(from bundle: GPTK4Bundle, layout: WineLayout) async throws {
    let targetLib = layout.runtimeDirectory.appending(path: "lib", directoryHint: .isDirectory)
    let external = targetLib.appending(path: "external", directoryHint: .isDirectory)
    try removeIfPresent(external)
    try await runTool(
      "/usr/bin/ditto", [bundle.directory.appending(path: "external").path, external.path], layout: layout)

    // The DMG's `wine/` tree contains only GPTK bridge libraries. Overlay its two architecture directories so
    // Wine's other builtin DLLs, loader shims and symlinks remain in place.
    for architecture in ["x86_64-unix", "x86_64-windows"] {
      let source = bundle.directory.appending(path: "wine/\(architecture)", directoryHint: .isDirectory)
      let destination = targetLib.appending(path: "wine/\(architecture)", directoryHint: .isDirectory)
      try await runTool("/usr/bin/ditto", [source.path, destination.path], layout: layout)
    }
  }

  /// A newer DXMT arrived with an app update: replace its files and the stamp, keep Wine and the prefix.
  func refreshDXMT(progress: @escaping @Sendable (WineInstallProgress) -> Void) async throws {
    let bundle = try validatedDXMT()
    // A running game holds the old winemetal.so; the launcher only refreshes while nothing runs.
    progress(.installingDXMT)
    try installDXMTRuntime(from: bundle, layout: layout)
    try installDXMTPrefix(from: bundle, layout: layout)
    progress(.finalizing)
    try writeStamp(backend: .dxmt, layout: layout)
  }

  private func writeStamp(backend: GraphicsBackend, layout: WineLayout) throws {
    let stamp = WineStamp(
      wineVersion: distribution.id, dxmtVersion: backend == .dxmt ? dxmt?.version ?? "" : "",
      graphicsBackend: backend, gptkVersion: backend == .gptk4 ? gptk4?.version ?? "" : "")
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try encoder.encode(stamp).write(to: layout.stampFile, options: .atomic)
  }

  private func initializePrefixIfNeeded(_ layout: WineLayout) async throws {
    let fileManager = FileManager.default
    if prefixIsRecognized(layout.prefixDirectory) {
      try? fileManager.removeItem(at: layout.prefixInitializationMarker)
      return
    }
    var isDirectory: ObjCBool = false
    if fileManager.fileExists(atPath: layout.prefixDirectory.path, isDirectory: &isDirectory) {
      guard isDirectory.boolValue else { throw WineInstallError.prefixUnrecognized(layout.prefixDirectory) }
      guard let entries = try? fileManager.contentsOfDirectory(atPath: layout.prefixDirectory.path) else {
        throw WineInstallError.prefixUnrecognized(layout.prefixDirectory)
      }
      guard entries.isEmpty || fileManager.fileExists(atPath: layout.prefixInitializationMarker.path) else {
        throw WineInstallError.prefixUnrecognized(layout.prefixDirectory)
      }
    } else {
      try fileManager.createDirectory(at: layout.prefixDirectory, withIntermediateDirectories: true)
    }
    try Data("1\n".utf8).write(to: layout.prefixInitializationMarker, options: .atomic)
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
    guard prefixIsRecognized(layout.prefixDirectory) else {
      throw WineInstallError.prefixInitializationFailed(logURL: layout.wineBootLog)
    }
    try fileManager.removeItem(at: layout.prefixInitializationMarker)
  }

  private func prefixNeedsManualRecovery(_ layout: WineLayout) -> Bool {
    let fm = FileManager.default
    guard fm.fileExists(atPath: layout.prefixDirectory.path),
      !prefixIsRecognized(layout.prefixDirectory),
      !fm.fileExists(atPath: layout.prefixInitializationMarker.path)
    else { return false }
    guard let entries = try? fm.contentsOfDirectory(atPath: layout.prefixDirectory.path) else { return true }
    return !entries.isEmpty
  }

  private func prefixIsRecognized(_ prefix: URL) -> Bool {
    let fm = FileManager.default
    var isDirectory: ObjCBool = false
    guard fm.fileExists(atPath: prefix.path, isDirectory: &isDirectory), isDirectory.boolValue else { return false }
    func isNonEmptyRegularFile(_ url: URL) -> Bool {
      guard let attributes = try? fm.attributesOfItem(atPath: url.path),
        attributes[.type] as? FileAttributeType == .typeRegular,
        let size = attributes[.size] as? NSNumber
      else { return false }
      return size.int64Value > 0
    }
    let system32 = prefix.appending(path: "drive_c/windows/system32", directoryHint: .isDirectory)
    var system32IsDirectory: ObjCBool = false
    return isNonEmptyRegularFile(prefix.appending(path: "system.reg"))
      && isNonEmptyRegularFile(prefix.appending(path: "user.reg"))
      && fm.fileExists(atPath: system32.path, isDirectory: &system32IsDirectory)
      && system32IsDirectory.boolValue
  }

  private func installDXMTRuntime(from bundle: DXMTBundle, layout: WineLayout) throws {
    let fileManager = FileManager.default
    try fileManager.createDirectory(at: layout.windowsLibraryDirectory, withIntermediateDirectories: true)
    try fileManager.createDirectory(at: layout.unixLibraryDirectory, withIntermediateDirectories: true)
    for name in WineLayout.dxmtWindowsFiles {
      try replace(bundle.windowsDirectory.appending(path: name), with: layout.windowsLibraryDirectory.appending(path: name))
    }
    try replace(bundle.unixDirectory.appending(path: "winemetal.so"), with: layout.unixLibraryDirectory.appending(path: "winemetal.so"))
  }

  private func installDXMTPrefix(from bundle: DXMTBundle, layout: WineLayout) throws {
    try FileManager.default.createDirectory(at: layout.prefixSystem32, withIntermediateDirectories: true)
    try replace(
      bundle.windowsDirectory.appending(path: "winemetal.dll"), with: layout.prefixSystem32.appending(path: "winemetal.dll"))
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
    Downloader.fileSize(archive) + Downloader.fileSize(Downloader.partialURL(for: archive))
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
