import Foundation
import Platform
import Testing

@testable import Wine

@Suite("GPTK 4 runtime") struct WineGPTK4Tests {
  @Test func theRequiredGPTKFilesAreInTheBuildManifest() throws {
    // scripts/gptk4-files is what scripts/prepare-gptk4 stages and check-gptk4 verifies.
    let list = URL(filePath: #filePath).deletingLastPathComponent().appending(path: "../../scripts/gptk4-files")
    let shipped = Set(try String(contentsOf: list, encoding: .utf8).split(separator: "\n").map(String.init))
    #expect(GPTK4Bundle.requiredFiles.filter { !shipped.contains("lib/\($0)") } == [])
  }

  @Test func aStampFromBeforeBackendsReadsAsDXMT() throws {
    let old = #"{"dxmtVersion":"e94c312","schemaVersion":1,"wineVersion":"w"}"#
    let stamp = try JSONDecoder().decode(WineStamp.self, from: Data(old.utf8))
    #expect(stamp == WineStamp(wineVersion: "w", dxmtVersion: "e94c312", graphicsBackend: .dxmt, gptkVersion: ""))
  }

  @Test("GPTK and DXMT use separate runtimes, overlay bridge files, and retain one prefix")
  func isolatedRuntimesSharePrefix() async throws {
    try await withWineTempDirectory { dir in
      let h = try makeWineHarness(in: dir)
      let dxmt = WineLayout(root: h.root, backend: .dxmt)
      let gptk4 = WineLayout(root: h.root, backend: .gptk4)
      let bundle = try #require(h.fixtures.gptk4)
      let missing = GPTK4Bundle.requiredFiles.filter {
        !FileManager.default.fileExists(atPath: bundle.directory.appending(path: $0).path)
      }
      #expect(missing.isEmpty, "missing GPTK fixture files: \(missing)")

      #expect(dxmt.runtimeDirectory != gptk4.runtimeDirectory)
      #expect(dxmt.prefixDirectory == gptk4.prefixDirectory)
      try await h.runtime.ensureInstalled(for: .dxmt)
      try h.writeFile("wineprefix/login-sentinel.txt")
      #expect(wineExists(dxmt.runtimeDirectory.appending(path: "lib/external/wine-base.dylib")))

      try await h.runtime.ensureInstalled(for: .gptk4)

      #expect(await h.runtime.status(for: .dxmt) == .ready)
      #expect(await h.runtime.status(for: .gptk4) == .ready)
      #expect(wineExists(dxmt.runtimeDirectory.appending(path: "lib/external/wine-base.dylib")))
      #expect(!wineExists(gptk4.runtimeDirectory.appending(path: "lib/external/wine-base.dylib")))
      #expect(wineExists(gptk4.windowsLibraryDirectory.appending(path: "kernel32.dll")))
      #expect(
        try Data(contentsOf: gptk4.windowsLibraryDirectory.appending(path: "kernel32.dll"))
          == WineFixtureContent.stock("kernel32.dll"))
      #expect(
        try Data(contentsOf: gptk4.windowsLibraryDirectory.appending(path: "d3d11.dll"))
          == Data("GPTK-windows-d3d11".utf8))
      #expect(
        try FileManager.default.destinationOfSymbolicLink(
          atPath: gptk4.unixLibraryDirectory.appending(path: "d3d11.so").path)
          == "../../external/libd3dshared.dylib")
      #expect(wineExists(gptk4.runtimeDirectory.appending(path: "lib/external/D3DMetal.framework/Versions/A/D3DMetal")))
      #expect(wineExists(gptk4.runtimeDirectory.appending(path: "lib/external/libd3dshared.dylib")))
      #expect(try Data(contentsOf: dxmt.windowsLibraryDirectory.appending(path: "d3d11.dll")) == WineFixtureContent.dxmt("d3d11.dll"))
      #expect(wineExists(h.root.appending(path: "wineprefix/login-sentinel.txt")))
      #expect(h.runner.wineCalls.filter { $0.arguments.first == "wineboot" }.count == 1)
      #expect(h.downloader.count(of: h.fixtures.distribution.url) == 1)

      let stamp = try JSONDecoder().decode(WineStamp.self, from: Data(contentsOf: gptk4.stampFile))
      #expect(stamp.graphicsBackend == .gptk4)
      #expect(stamp.gptkVersion == GPTK4Bundle.expectedVersion)
    }
  }

  @Test("a build without GPTK fails before downloading or touching the shared prefix")
  func missingBundleDoesNotInstall() async throws {
    try await withWineTempDirectory { dir in
      var options = WineHarnessOptions()
      options.fixture.gptk4Included = false
      let h = try makeWineHarness(in: dir, options: options)

      #expect(await h.runtime.status(for: .gptk4) == .needsInstall(.backendUnavailable))
      await #expect(throws: WineInstallError.gptk4BundleInvalid) {
        try await h.runtime.ensureInstalled(for: .gptk4)
      }
      #expect(h.downloader.requests.isEmpty)
      #expect(!wineExists(WineLayout(root: h.root, backend: .gptk4).runtimeDirectory))
      #expect(!wineExists(h.layout.prefixDirectory))
    }
  }

  @Test("an unrecognized non-empty prefix is preserved and blocks runtime installation")
  func unknownPrefixIsPreserved() async throws {
    try await withWineTempDirectory { dir in
      let h = try makeWineHarness(in: dir)
      try h.writeFile("wineprefix/user.reg", "partial user state")

      #expect(await h.runtime.status(for: .gptk4) == .needsInstall(.prefixUnrecognized))
      await #expect(throws: WineInstallError.prefixUnrecognized(h.layout.prefixDirectory)) {
        try await h.runtime.ensureInstalled(for: .gptk4)
      }
      #expect(try String(contentsOf: h.layout.prefixDirectory.appending(path: "user.reg"), encoding: .utf8) == "partial user state")
      #expect(h.downloader.requests.isEmpty)
      #expect(!wineExists(WineLayout(root: h.root, backend: .gptk4).runtimeDirectory))
    }
  }

  @Test("empty registry files and a system32 directory do not make a half-initialized prefix ready")
  func halfInitializedPrefixIsPreserved() async throws {
    try await withWineTempDirectory { dir in
      let h = try makeWineHarness(in: dir)
      let prefix = h.layout.prefixDirectory
      try FileManager.default.createDirectory(
        at: prefix.appending(path: "drive_c/windows/system32", directoryHint: .isDirectory),
        withIntermediateDirectories: true)
      try Data().write(to: prefix.appending(path: "system.reg"))
      try Data().write(to: prefix.appending(path: "user.reg"))

      #expect(await h.runtime.status(for: .gptk4) == .needsInstall(.prefixUnrecognized))
      await #expect(throws: WineInstallError.prefixUnrecognized(prefix)) {
        try await h.runtime.ensureInstalled(for: .gptk4)
      }
      #expect(wineExists(prefix.appending(path: "system.reg")))
      #expect(wineExists(prefix.appending(path: "user.reg")))
      #expect(wineExists(prefix.appending(path: "drive_c/windows/system32")))
      #expect(h.downloader.requests.isEmpty)
    }
  }

  @Test("a failed prefix initialization keeps its marker and retries without deleting the prefix")
  func interruptedPrefixInitializationRecovers() async throws {
    try await withWineTempDirectory { dir in
      var options = WineHarnessOptions()
      options.bootExitCode = 1
      let h = try makeWineHarness(in: dir, options: options)
      let layout = WineLayout(root: h.root, backend: .gptk4)

      await #expect(throws: WineInstallError.prefixInitializationFailed(logURL: layout.wineBootLog)) {
        try await h.runtime.ensureInstalled(for: .gptk4)
      }
      #expect(wineExists(layout.prefixInitializationMarker))
      #expect(await h.runtime.status(for: .gptk4) == .needsInstall(.interrupted))

      h.runner.setBootExitCode(0)
      try await h.runtime.ensureInstalled(for: .gptk4)

      #expect(await h.runtime.status(for: .gptk4) == .ready)
      #expect(!wineExists(layout.prefixInitializationMarker))
      #expect(wineExists(layout.prefixDirectory.appending(path: "system.reg")))
      #expect(wineExists(layout.prefixDirectory.appending(path: "user.reg")))
      #expect(h.downloader.count(of: h.fixtures.distribution.url) == 1)
    }
  }

  @Test("a failed GPTK overlay has no ready stamp and retry preserves DXMT and the prefix")
  func failedOverlayRecoversWithoutCrossBackendDamage() async throws {
    try await withWineTempDirectory { dir in
      let h = try await makeInstalledWineHarness(in: dir)
      let gptk4 = WineLayout(root: h.root, backend: .gptk4)
      try await h.runtime.ensureInstalled(for: .gptk4)
      try h.writeFile("wineprefix/login-sentinel.txt")

      h.runner.setDittoExitCode(1)
      await #expect(throws: WineInstallError.extractionFailed(
        tool: "ditto", exitCode: 1, output: "ditto: stub failure")) {
        try await h.runtime.reinstall(.gptk4)
      }
      #expect(await h.runtime.status(for: .gptk4) == .needsInstall(.interrupted))
      #expect(await h.runtime.status(for: .dxmt) == .ready)
      #expect(wineExists(h.root.appending(path: "wineprefix/login-sentinel.txt")))

      h.runner.setDittoExitCode(nil)
      try await h.runtime.ensureInstalled(for: .gptk4)

      #expect(await h.runtime.status(for: .gptk4) == .ready)
      #expect(await h.runtime.status(for: .dxmt) == .ready)
      #expect(wineExists(h.root.appending(path: "wineprefix/login-sentinel.txt")))
      // The archive went once both runtimes were installed; the reinstall fetched it again and the retry reused it.
      #expect(h.downloader.count(of: h.fixtures.distribution.url) == 2)
      #expect(wineExists(gptk4.windowsLibraryDirectory.appending(path: "kernel32.dll")))
    }
  }
}
