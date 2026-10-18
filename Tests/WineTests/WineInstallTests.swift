import Foundation
import Platform
import Testing

@testable import Wine

private let thumbprint = "F09065E2D57F005BBD975DDCF9EB63F570764F17"

@Suite("WIN-006/007 download, replace and cleanup") struct WineInstallDownloadTests {
  @Test("WIN-007 downloads wine from distribution.url, once")
  func downloadsWine() async throws {
    try await withWineTempDirectory { dir in
      let h = try await makeInstalledWineHarness(in: dir)
      #expect(h.downloader.count(of: h.fixtures.distribution.url) == 1)
      #expect(h.downloader.requests.count == 1)
    }
  }

  @Test("WIN-007 the request passes the pinned sha256")
  func passesChecksums() async throws {
    try await withWineTempDirectory { dir in
      let h = try await makeInstalledWineHarness(in: dir)
      let bySHA = Dictionary(uniqueKeysWithValues: h.downloader.requests.map { ($0.url, $0.sha256) })
      #expect(bySHA[h.fixtures.distribution.url] == h.fixtures.distribution.sha256)
    }
  }

  @Test("WIN-007 the verified archive stays available for the other backend")
  func verifiedArchiveIsKeptForTheOtherBackend() async throws {
    try await withWineTempDirectory { dir in
      let h = try await makeInstalledWineHarness(in: dir)
      for request in h.downloader.requests {
        #expect(request.destination.resolvingSymlinksInPath().path.hasPrefix(h.root.path + "/"))
        #expect(wineExists(request.destination))
      }
      let top = try FileManager.default.contentsOfDirectory(atPath: h.root.path).sorted()
      #expect(top == ["downloads", "wine", "wineboot.log", "wineprefix", "winecfg.log"].sorted())
    }
  }

  @Test("WIN-007 a corrupted wine archive throws, installs nothing and leaves status unchanged")
  func corruptedWineArchive() async throws {
    try await withWineTempDirectory { dir in
      var options = WineHarnessOptions()
      options.fixture.corruptWine = true
      let h = try makeWineHarness(in: dir, options: options)
      await #expect(throws: DownloadError.self) { try await h.install() }
      #expect(!wineExists(h.layout.runtimeDirectory))
      #expect(!wineExists(h.layout.prefixDirectory))
      #expect(await h.runtime.status(for: .dxmt) == .needsInstall(.notInstalled))
      #expect(h.runner.wineCalls.isEmpty)
      // The corrupt archive is removed and nothing else was written.
      #expect(try FileManager.default.contentsOfDirectory(atPath: h.root.path).isEmpty)
    }
  }

  @Test("WIN-006 reinstall replaces only the selected runtime and keeps the shared prefix")
  func reinstallKeepsPrefix() async throws {
    try await withWineTempDirectory { dir in
      let h = try await makeInstalledWineHarness(in: dir)
      try h.writeFile("wine/old-sentinel.txt")
      try h.writeFile("wineprefix/login-sentinel.txt")
      try await h.runtime.reinstall(.dxmt)
      #expect(!wineExists(h.root.appending(path: "wine/old-sentinel.txt")))
      #expect(wineExists(h.root.appending(path: "wineprefix/login-sentinel.txt")))
      #expect(await h.runtime.status(for: .dxmt) == .ready)
      #expect(h.downloader.requests.count == 1)  // the verified archive is reused
    }
  }

  @Test("WIN-006 ensureInstalled repairs a runtime without replacing the shared prefix")
  func ensureInstalledKeepsPrefix() async throws {
    try await withWineTempDirectory { dir in
      let h = try await makeInstalledWineHarness(in: dir)
      try h.writeFile("wine/stale.txt")
      try h.writeFile("wineprefix/login-sentinel.txt")
      try FileManager.default.removeItem(at: h.layout.stampFile)
      try await h.install()
      #expect(!wineExists(h.root.appending(path: "wine/stale.txt")))
      #expect(wineExists(h.root.appending(path: "wineprefix/login-sentinel.txt")))
      #expect(await h.runtime.status(for: .dxmt) == .ready)
    }
  }

  @Test("WIN-006 a failing wine download leaves existing wine and wineprefix untouched")
  func wineDownloadFailureKeepsOld() async throws {
    try await withWineTempDirectory { dir in
      var options = WineHarnessOptions()
      options.failingURLs = { [$0.distribution.url] }
      let h = try makeWineHarness(in: dir, options: options)
      try h.writeFile("wine/sentinel.txt")
      try h.writeFile("wineprefix/system.reg", "system")
      try h.writeFile("wineprefix/user.reg", "user")
      try FileManager.default.createDirectory(
        at: h.root.appending(path: "wineprefix/drive_c/windows/system32", directoryHint: .isDirectory),
        withIntermediateDirectories: true)
      try h.writeFile("wineprefix/login-sentinel.txt")
      try h.writeFile("wineprefix/sentinel.txt")
      await #expect(throws: WineStubDownloadFailure()) { try await h.install() }
      #expect(wineExists(h.root.appending(path: "wine/sentinel.txt")))
      #expect(wineExists(h.root.appending(path: "wineprefix/sentinel.txt")))
    }
  }

  @Test("WIN-006 ensureInstalled when already ready does nothing")
  func ensureInstalledNoop() async throws {
    try await withWineTempDirectory { dir in
      let h = try await makeInstalledWineHarness(in: dir)
      let downloads = h.downloader.requests.count
      let calls = h.runner.calls.count
      try await h.runtime.ensureInstalled(for: .dxmt)
      #expect(h.downloader.requests.count == downloads)
      #expect(h.runner.calls.count == calls)
    }
  }

  @Test("WIN-006 two concurrent ensureInstalled calls share one download of each archive")
  func concurrentEnsureInstalled() async throws {
    try await withWineTempDirectory { dir in
      var options = WineHarnessOptions()
      options.downloadDelay = .milliseconds(200)
      let h = try makeWineHarness(in: dir, options: options)
      // Plain Tasks, not `async let`: Xcode 26.6's runtime intermittently traps ("freed pointer was not the
      // last allocation") on the stack-allocated child tasks of an `async let`.
      let runtime = h.runtime
      let a = Task { try await runtime.ensureInstalled(for: .dxmt) }
      let b = Task { try await runtime.ensureInstalled(for: .dxmt) }
      try await a.value
      try await b.value
      #expect(h.downloader.count(of: h.fixtures.distribution.url) == 1)
      #expect(h.runner.wineCalls.filter { $0.arguments.first == "wineboot" }.count == 1)
      #expect(await h.runtime.status(for: .dxmt) == .ready)
    }
  }
}

@Suite("WIN-008/009 extraction and certificate") struct WineInstallExtractionTests {
  @Test("WIN-008 tar runs as /usr/bin/tar with -C <wine dir>, --strip-components=1 and the winePath operand")
  func tarArguments() async throws {
    try await withWineTempDirectory { dir in
      let h = try await makeInstalledWineHarness(in: dir)
      let call = try #require(
        h.runner.calls.first { call in
          guard call.executable == "/usr/bin/tar", let i = call.arguments.firstIndex(of: "-C"),
            i + 1 < call.arguments.count
          else { return false }
          return winePathsEqual(call.arguments[i + 1], h.layout.runtimeDirectory)
        })
      #expect(call.arguments.contains("--strip-components=1"))
      #expect(call.arguments.last == "wine")
      #expect(call.arguments.contains { $0.hasSuffix(".tar.xz") || $0.contains("wine") && $0 != "wine" })
    }
  }

  @Test("WIN-008 extraction yields wine/bin/wine and wine/share/wine/wine.inf")
  func extractedFiles() async throws {
    try await withWineTempDirectory { dir in
      let h = try await makeInstalledWineHarness(in: dir)
      #expect(try Data(contentsOf: h.root.appending(path: "wine/bin/wine")) == Data("loader".utf8))
      #expect(wineExists(h.root.appending(path: "wine/share/wine/wine.inf")))
      #expect(wineExists(h.root.appending(path: "wine/lib/wine/x86_64-unix/wine")))
      #expect(!wineExists(h.root.appending(path: "wine/wine")))
    }
  }

  @Test("WIN-008 with winePath nil there is no strip or operand and the whole archive is extracted")
  func noWinePath() async throws {
    try await withWineTempDirectory { dir in
      var options = WineHarnessOptions()
      options.fixture.winePath = nil
      let h = try makeWineHarness(in: dir, options: options)
      try await h.install()
      let call = try #require(
        h.runner.calls.first { call in
          call.executable == "/usr/bin/tar" && call.arguments.contains("-C")
            && call.arguments.contains { winePathsEqual($0, h.layout.runtimeDirectory) }
        })
      #expect(!call.arguments.contains { $0.hasPrefix("--strip-components") })
      #expect(call.arguments.last != "wine")
      #expect(wineExists(h.root.appending(path: "wine/bin/wine")))
      #expect(wineExists(h.root.appending(path: "wine/share/wine/wine.inf")))
    }
  }

  @Test("WIN-008 tar exiting non-zero throws extractionFailed with tar's output")
  func tarFailure() async throws {
    try await withWineTempDirectory { dir in
      var options = WineHarnessOptions()
      options.tarExitCode = 2
      let h = try makeWineHarness(in: dir, options: options)
      await #expect(throws: WineInstallError.extractionFailed(tool: "tar", exitCode: 2, output: "tar: stub failure")) {
        try await h.install()
      }
      #expect(!wineExists(h.layout.stampFile))
    }
  }

  @Test("WIN-009 installed wine.inf contains the certificate block")
  func infHasCertificate() async throws {
    try await withWineTempDirectory { dir in
      let h = try await makeInstalledWineHarness(in: dir)
      let inf = try String(contentsOf: h.root.appending(path: "wine/share/wine/wine.inf"), encoding: .utf8)
      #expect(inf.contains("; DWCA :xdd:"))
      #expect(inf.contains(thumbprint))
    }
  }

  @Test("WIN-009 the certificate is injected before wineboot runs")
  func injectedBeforeWineboot() async throws {
    try await withWineTempDirectory { dir in
      let h = try await makeInstalledWineHarness(in: dir)
      let atBoot = try #require(h.runner.infAtBoot)
      #expect(atBoot.contains(thumbprint))
    }
  }
}

@Suite("WIN-012 prefix initialisation") struct WineInstallPrefixTests {
  @Test("WIN-012 runs <loader> wineboot -u then <loader> winecfg -v win10")
  func commandSequence() async throws {
    try await withWineTempDirectory { dir in
      let h = try await makeInstalledWineHarness(in: dir)
      let wine = h.runner.wineCalls
      #expect(wine.map(\.arguments) == [["wineboot", "-u"], ["winecfg", "-v", "win10"]])
      for call in wine { #expect(winePathsEqual(call.executable, h.root.appending(path: "wine/bin/wine"))) }
    }
  }

  @Test("WIN-012 wine calls set WINEPREFIX to <data>/wineprefix and run in the data directory")
  func environmentAndCwd() async throws {
    try await withWineTempDirectory { dir in
      let h = try await makeInstalledWineHarness(in: dir)
      for call in h.runner.wineCalls {
        let prefix = try #require(call.environment["WINEPREFIX"])
        #expect(winePathsEqual(prefix, h.layout.prefixDirectory))
        let cwd = try #require(call.workingDirectory)
        #expect(winePathsEqual(cwd, h.root))
      }
    }
  }

  @Test("WIN-012 wineboot and winecfg output is written to wineboot.log and winecfg.log")
  func logs() async throws {
    try await withWineTempDirectory { dir in
      let h = try await makeInstalledWineHarness(in: dir)
      #expect(try String(contentsOf: h.layout.wineBootLog, encoding: .utf8).contains("wineboot-stub-output"))
      #expect(try String(contentsOf: h.layout.wineCfgLog, encoding: .utf8).contains("winecfg-stub-output"))
    }
  }

  @Test("WIN-012 wineboot exiting non-zero throws prefixInitializationFailed(wineboot.log) and writes no stamp")
  func winebootFailure() async throws {
    try await withWineTempDirectory { dir in
      var options = WineHarnessOptions()
      options.bootExitCode = 1
      let h = try makeWineHarness(in: dir, options: options)
      do {
        try await h.install()
        Issue.record("expected prefixInitializationFailed")
      } catch let WineInstallError.prefixInitializationFailed(logURL) {
        #expect(winePathsEqual(logURL.path, h.layout.wineBootLog))
      } catch {
        Issue.record("unexpected error \(error)")
      }
      #expect(!wineExists(h.layout.stampFile))
      #expect(await h.runtime.status(for: .dxmt) == .needsInstall(.interrupted))
      #expect(h.runner.wineCalls.map(\.arguments) == [["wineboot", "-u"]])
    }
  }

  @Test("WIN-012 winecfg exiting non-zero fails the install without a stamp")
  func winecfgFailure() async throws {
    try await withWineTempDirectory { dir in
      var options = WineHarnessOptions()
      options.winecfgExitCode = 1
      let h = try makeWineHarness(in: dir, options: options)
      await #expect(throws: (any Error).self) { try await h.install() }
      #expect(!wineExists(h.layout.stampFile))
      #expect(h.runner.wineCalls.map(\.arguments) == [["wineboot", "-u"], ["winecfg", "-v", "win10"]])
    }
  }
}

@Suite("WIN-020/021 DXMT installed once") struct WineInstallDXMTTests {
  @Test func WIN_020_theDXMTFilesInstalledAreTheOnesTheBuildScriptShips() throws {
    // scripts/dxmt-files is what scripts/build-dxmt puts into the app and what check-bundle and CI look for.
    let list = URL(filePath: #filePath).deletingLastPathComponent().appending(path: "../../scripts/dxmt-files")
    let shipped = try String(contentsOf: list, encoding: .utf8).split(separator: "\n").map(String.init)
      .filter { !$0.hasPrefix("#") && !$0.isEmpty }
    let windows = shipped.filter { $0.hasPrefix("x86_64-windows/") }.map { String($0.dropFirst("x86_64-windows/".count)) }
    #expect(windows == WineLayout.dxmtWindowsFiles)
    #expect(shipped.contains("x86_64-unix/winemetal.so"))
  }

  @Test("WIN-020 d3d10core, d3d11, dxgi, winemetal DLLs land in wine/lib/wine/x86_64-windows with DXMT contents")
  func windowsDlls() async throws {
    try await withWineTempDirectory { dir in
      let h = try await makeInstalledWineHarness(in: dir)
      for name in ["d3d10core.dll", "d3d11.dll", "dxgi.dll", "winemetal.dll"] {
        let url = h.layout.windowsLibraryDirectory.appending(path: name)
        #expect(try Data(contentsOf: url) == WineFixtureContent.dxmt(name), "\(name)")
      }
    }
  }

  @Test("WIN-020 winemetal.so lands in wine/lib/wine/x86_64-unix")
  func unixSo() async throws {
    try await withWineTempDirectory { dir in
      let h = try await makeInstalledWineHarness(in: dir)
      let url = h.layout.unixLibraryDirectory.appending(path: "winemetal.so")
      #expect(try Data(contentsOf: url) == WineFixtureContent.dxmt("winemetal.so"))
    }
  }

  @Test("WIN-020 winemetal.dll is also copied into the prefix system32")
  func systemDll() async throws {
    try await withWineTempDirectory { dir in
      let h = try await makeInstalledWineHarness(in: dir)
      let url = h.layout.prefixSystem32.appending(path: "winemetal.dll")
      #expect(try Data(contentsOf: url) == WineFixtureContent.dxmt("winemetal.dll"))
    }
  }

  @Test("WIN-020 nvngx.dll is copied nowhere")
  func nvngxNotCopied() async throws {
    try await withWineTempDirectory { dir in
      let h = try await makeInstalledWineHarness(in: dir)
      #expect(!wineRelativePaths(under: h.root).contains { $0.hasSuffix("nvngx.dll") })
    }
  }

  @Test("WIN-020 aarch64 and i386 DXMT files are ignored")
  func otherArchitecturesIgnored() async throws {
    try await withWineTempDirectory { dir in
      let h = try await makeInstalledWineHarness(in: dir)
      for relative in wineRelativePaths(under: h.root) {
        let url = h.root.appending(path: relative)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), !isDirectory.boolValue,
          let data = try? Data(contentsOf: url)
        else { continue }
        #expect(data != WineFixtureContent.wrongArch, "\(relative)")
      }
    }
  }

  @Test("WIN-020 DXMT is installed after wineboot: the stock d3d11.dll is still in place when wineboot runs")
  func installedAfterWineboot() async throws {
    try await withWineTempDirectory { dir in
      let h = try await makeInstalledWineHarness(in: dir)
      #expect(h.runner.d3d11AtBoot == WineFixtureContent.stock("d3d11.dll"))
      #expect(try Data(contentsOf: h.layout.windowsLibraryDirectory.appending(path: "d3d11.dll")) != WineFixtureContent.stock("d3d11.dll"))
    }
  }

  @Test("WIN-021 no .bak files are created anywhere and stock DLLs are replaced")
  func noBackups() async throws {
    try await withWineTempDirectory { dir in
      let h = try await makeInstalledWineHarness(in: dir)
      #expect(!wineRelativePaths(under: h.root).contains { $0.hasSuffix(".bak") })
      #expect(try Data(contentsOf: h.layout.windowsLibraryDirectory.appending(path: "dxgi.dll")) == WineFixtureContent.dxmt("dxgi.dll"))
    }
  }

  @Test("WIN-021 nothing touches DXMT after install: status and ensureInstalled start no process")
  func nothingAtLaunch() async throws {
    try await withWineTempDirectory { dir in
      let h = try await makeInstalledWineHarness(in: dir)
      let before = h.runner.calls
      let filesBefore = wineRelativePaths(under: h.root)
      _ = await h.runtime.status(for: .dxmt)
      try await h.runtime.ensureInstalled(for: .dxmt)
      #expect(h.runner.calls == before)
      #expect(wineRelativePaths(under: h.root) == filesBefore)
    }
  }

  @Test("WIN-020 a DXMT bundle without x86_64-windows throws dxmtBundleInvalid before anything is downloaded or deleted")
  func invalidDXMT() async throws {
    try await withWineTempDirectory { dir in
      var options = WineHarnessOptions()
      options.fixture.dxmtHasX64 = false
      let h = try makeWineHarness(in: dir, options: options)
      try h.writeFile("wine/sentinel.txt")
      await #expect(throws: WineInstallError.dxmtBundleInvalid) { try await h.install() }
      #expect(h.downloader.requests.isEmpty)
      #expect(wineExists(h.root.appending(path: "wine/sentinel.txt")))
      #expect(!wineExists(h.layout.stampFile))
    }
  }

  @Test("WIN-020 an app without DXMT cannot install Wine")
  func noBundle() async throws {
    try await withWineTempDirectory { dir in
      let h = try makeWineHarness(in: dir)
      let bare = WineRuntime(
        dataDirectory: DataDirectory(root: h.root), distribution: h.fixtures.distribution, dxmt: nil,
        downloader: h.downloader, runner: h.runner)
      await #expect(throws: WineInstallError.dxmtBundleInvalid) { try await bare.ensureInstalled(for: .dxmt) }
      #expect(h.downloader.requests.isEmpty)
    }
  }

  @Test("WIN-019 a newer DXMT in the app is copied over the old one; Wine, the prefix and the network stay out of it")
  func refreshOnlyDXMT() async throws {
    try await withWineTempDirectory { dir in
      let h = try await makeInstalledWineHarness(in: dir)
      try h.writeFile("wineprefix/user.reg", "player data")
      try h.writeFile("wine/bin/sentinel.txt")
      let downloads = h.downloader.requests.count
      let calls = h.runner.calls.count

      // The next app release ships another DXMT build.
      let newer = dir.appending(path: "dxmt-newer", directoryHint: .isDirectory)
      try FileManager.default.copyItem(at: h.fixtures.dxmt.directory, to: newer)
      for name in WineFixtureContent.dxmtWindowsFiles {
        try Data("NEWER-\(name)".utf8).write(to: newer.appending(path: "x86_64-windows/\(name)"))
      }
      try Data("NEWER-winemetal.so".utf8).write(to: newer.appending(path: "x86_64-unix/winemetal.so"))
      let bundle = DXMTBundle(directory: newer, version: "newer123")
      let updated = WineRuntime(
        dataDirectory: DataDirectory(root: h.root), distribution: h.fixtures.distribution, dxmt: bundle,
        downloader: h.downloader, runner: h.runner)
      #expect(await updated.status(for: .dxmt) == .needsInstall(.dxmtOutdated))

      let collector = WineProgressCollector()
      try await updated.ensureInstalled(for: .dxmt, progress: collector.callback)

      #expect(collector.collapsed == ["installingDXMT", "finalizing"])
      #expect(await updated.status(for: .dxmt) == .ready)
      #expect(try h.readStamp() == WineStamp(wineVersion: "test-wine-1", dxmtVersion: "newer123"))
      #expect(try Data(contentsOf: h.layout.windowsLibraryDirectory.appending(path: "d3d11.dll")) == Data("NEWER-d3d11.dll".utf8))
      #expect(try Data(contentsOf: h.layout.unixLibraryDirectory.appending(path: "winemetal.so")) == Data("NEWER-winemetal.so".utf8))
      #expect(try Data(contentsOf: h.layout.prefixSystem32.appending(path: "winemetal.dll")) == Data("NEWER-winemetal.dll".utf8))
      #expect(h.downloader.requests.count == downloads)
      #expect(h.runner.calls.count == calls)
      #expect(wineExists(h.root.appending(path: "wineprefix/user.reg")))
      #expect(wineExists(h.root.appending(path: "wine/bin/sentinel.txt")))
    }
  }
}

@Suite("WIN-014/015 stamp, storage and netbios") struct WineInstallStampTests {
  @Test("WIN-014 stamp decodes to schema 1 with the distribution id and DXMT version")
  func stampContents() async throws {
    try await withWineTempDirectory { dir in
      let h = try await makeInstalledWineHarness(in: dir)
      #expect(h.layout.stampFile.path.hasSuffix("wine/.genshin-launcher-wine-stamp.json"))
      #expect(try h.readStamp() == WineStamp(schemaVersion: 1, wineVersion: "test-wine-1", dxmtVersion: wineFixtureCommit))
    }
  }

  @Test("WIN-014 stamp is written last: no file under wine or wineprefix is newer")
  func stampWrittenLast() async throws {
    try await withWineTempDirectory { dir in
      let h = try await makeInstalledWineHarness(in: dir)
      let stampDate = try #require(
        try FileManager.default.attributesOfItem(atPath: h.layout.stampFile.path)[.modificationDate] as? Date)
      for base in [h.layout.runtimeDirectory, h.layout.prefixDirectory] {
        for relative in wineRelativePaths(under: base) {
          let path = base.appending(path: relative).path
          var isDirectory: ObjCBool = false
          guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), !isDirectory.boolValue else { continue }
          let date = try #require(try FileManager.default.attributesOfItem(atPath: path)[.modificationDate] as? Date)
          #expect(date <= stampDate, "\(relative)")
        }
      }
    }
  }

  @Test("WIN-014 install leaves only wine, wineprefix and the two logs in the data directory (no .storage, no state keys)")
  func dataDirectoryContents() async throws {
    try await withWineTempDirectory { dir in
      let h = try await makeInstalledWineHarness(in: dir)
      let top = try FileManager.default.contentsOfDirectory(atPath: h.root.path)
      #expect(Set(top) == ["downloads", "wine", "wineprefix", "wineboot.log", "winecfg.log"])
      #expect(!top.contains(".storage"))
    }
  }

  @Test("WIN-015 no process call carries a NETBIOS variable or a DESKTOP- name")
  func noNetbios() async throws {
    try await withWineTempDirectory { dir in
      let h = try await makeInstalledWineHarness(in: dir)
      #expect(!h.runner.calls.isEmpty)
      for call in h.runner.calls {
        for (key, value) in call.environment {
          #expect(!key.uppercased().contains("NETBIOS"))
          #expect(!value.uppercased().contains("NETBIOS"))
          #expect(!value.contains("DESKTOP-"))
        }
        for argument in call.arguments {
          #expect(!argument.uppercased().contains("NETBIOS"))
          #expect(!argument.contains("DESKTOP-"))
        }
      }
    }
  }

  @Test("WIN-014 progress arrives as the download, extracting, configuring, initializingPrefix, installingDXMT, finalizing")
  func progressOrder() async throws {
    try await withWineTempDirectory { dir in
      let h = try makeWineHarness(in: dir)
      let collector = WineProgressCollector()
      try await h.runtime.ensureInstalled(for: .dxmt, progress: collector.callback)
      #expect(
        collector.collapsed == [
          "downloadingWine", "extracting", "configuring", "initializingPrefix", "installingDXMT", "finalizing",
        ])
    }
  }
}
