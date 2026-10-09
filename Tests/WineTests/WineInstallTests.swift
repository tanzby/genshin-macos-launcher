import Foundation
import Platform
import Testing

@testable import Wine

private let thumbprint = "F09065E2D57F005BBD975DDCF9EB63F570764F17"

@Suite("WIN-006/007 download, replace and cleanup") struct WineInstallDownloadTests {
  @Test("WIN-007 downloads wine from distribution.url and DXMT from zipURL, once each")
  func downloadsBoth() async throws {
    try await withWineTempDirectory { dir in
      let h = try await makeInstalledWineHarness(in: dir)
      #expect(h.downloader.count(of: h.fixtures.distribution.url) == 1)
      #expect(h.downloader.count(of: h.fixtures.dxmt.zipURL) == 1)
      #expect(h.downloader.requests.count == 2)
    }
  }

  @Test("WIN-007 requests pass the pinned sha256 for both archives")
  func passesChecksums() async throws {
    try await withWineTempDirectory { dir in
      let h = try await makeInstalledWineHarness(in: dir)
      let bySHA = Dictionary(uniqueKeysWithValues: h.downloader.requests.map { ($0.url, $0.sha256) })
      #expect(bySHA[h.fixtures.distribution.url] == h.fixtures.distribution.sha256)
      #expect(bySHA[h.fixtures.dxmt.zipURL] == h.fixtures.dxmt.sha256)
    }
  }

  @Test("WIN-007 downloads go below the data directory and are removed afterwards")
  func archivesCleanedUp() async throws {
    try await withWineTempDirectory { dir in
      let h = try await makeInstalledWineHarness(in: dir)
      for request in h.downloader.requests {
        #expect(request.destination.resolvingSymlinksInPath().path.hasPrefix(h.root.path + "/"))
        #expect(!wineExists(request.destination))
      }
      let top = try FileManager.default.contentsOfDirectory(atPath: h.root.path).sorted()
      #expect(top == ["wine", "wineboot.log", "wineprefix", "winecfg.log"].sorted())
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
      #expect(await h.runtime.status() == .needsInstall(.notInstalled))
      #expect(h.runner.wineCalls.isEmpty)
      // Only the finished DXMT archive stays, in downloads/, for the next attempt.
      #expect(try FileManager.default.contentsOfDirectory(atPath: h.root.path) == ["downloads"])
    }
  }

  @Test("WIN-006 reinstall removes old wine and wineprefix entirely and installs fresh")
  func reinstallReplaces() async throws {
    try await withWineTempDirectory { dir in
      let h = try await makeInstalledWineHarness(in: dir)
      try h.writeFile("wine/old-sentinel.txt")
      try h.writeFile("wineprefix/old-sentinel.txt")
      try await h.runtime.reinstall()
      #expect(!wineExists(h.root.appending(path: "wine/old-sentinel.txt")))
      #expect(!wineExists(h.root.appending(path: "wineprefix/old-sentinel.txt")))
      #expect(await h.runtime.status() == .ready)
      #expect(h.downloader.requests.count == 4)
    }
  }

  @Test("WIN-006 ensureInstalled from a non-ready state removes stale wine and wineprefix")
  func ensureInstalledReplacesStale() async throws {
    try await withWineTempDirectory { dir in
      let h = try makeWineHarness(in: dir)
      try h.writeFile("wine/stale.txt")
      try h.writeFile("wineprefix/stale.txt")
      try await h.install()
      #expect(!wineExists(h.root.appending(path: "wine/stale.txt")))
      #expect(!wineExists(h.root.appending(path: "wineprefix/stale.txt")))
      #expect(await h.runtime.status() == .ready)
    }
  }

  @Test("WIN-006 a failing wine download leaves existing wine and wineprefix untouched")
  func wineDownloadFailureKeepsOld() async throws {
    try await withWineTempDirectory { dir in
      var options = WineHarnessOptions()
      options.failingURLs = { [$0.distribution.url] }
      let h = try makeWineHarness(in: dir, options: options)
      try h.writeFile("wine/sentinel.txt")
      try h.writeFile("wineprefix/sentinel.txt")
      await #expect(throws: WineStubDownloadFailure()) { try await h.install() }
      #expect(wineExists(h.root.appending(path: "wine/sentinel.txt")))
      #expect(wineExists(h.root.appending(path: "wineprefix/sentinel.txt")))
    }
  }

  @Test("WIN-006 a failing DXMT download also leaves existing wine and wineprefix untouched")
  func dxmtDownloadFailureKeepsOld() async throws {
    try await withWineTempDirectory { dir in
      var options = WineHarnessOptions()
      options.failingURLs = { [$0.dxmt.zipURL] }
      let h = try makeWineHarness(in: dir, options: options)
      try h.writeFile("wine/sentinel.txt")
      try h.writeFile("wineprefix/sentinel.txt")
      await #expect(throws: WineStubDownloadFailure()) { try await h.install() }
      #expect(wineExists(h.root.appending(path: "wine/sentinel.txt")))
      #expect(wineExists(h.root.appending(path: "wineprefix/sentinel.txt")))
      #expect(h.runner.wineCalls.isEmpty)
    }
  }

  @Test("WIN-006 ensureInstalled when already ready does nothing")
  func ensureInstalledNoop() async throws {
    try await withWineTempDirectory { dir in
      let h = try await makeInstalledWineHarness(in: dir)
      let downloads = h.downloader.requests.count
      let calls = h.runner.calls.count
      try await h.runtime.ensureInstalled()
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
      async let a: Void = h.runtime.ensureInstalled()
      async let b: Void = h.runtime.ensureInstalled()
      try await a
      try await b
      #expect(h.downloader.count(of: h.fixtures.distribution.url) == 1)
      #expect(h.downloader.count(of: h.fixtures.dxmt.zipURL) == 1)
      #expect(h.runner.wineCalls.filter { $0.arguments.first == "wineboot" }.count == 1)
      #expect(await h.runtime.status() == .ready)
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
      #expect(await h.runtime.status() == .needsInstall(.interrupted))
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
      _ = await h.runtime.status()
      try await h.runtime.ensureInstalled()
      #expect(h.runner.calls == before)
      #expect(wineRelativePaths(under: h.root) == filesBefore)
    }
  }

  @Test("WIN-020 an invalid DXMT archive (no x86_64-windows) throws dxmtArchiveInvalid and leaves no stamp")
  func invalidDXMT() async throws {
    try await withWineTempDirectory { dir in
      var options = WineHarnessOptions()
      options.fixture.dxmtHasX64 = false
      let h = try makeWineHarness(in: dir, options: options)
      await #expect(throws: WineInstallError.dxmtArchiveInvalid) { try await h.install() }
      #expect(!wineExists(h.layout.stampFile))
      #expect(await h.runtime.status() == .needsInstall(.notInstalled))
    }
  }
}

@Suite("WIN-014/015 stamp, storage and netbios") struct WineInstallStampTests {
  @Test("WIN-014 stamp decodes to schema 1 with the distribution id and DXMT version")
  func stampContents() async throws {
    try await withWineTempDirectory { dir in
      let h = try await makeInstalledWineHarness(in: dir)
      #expect(h.layout.stampFile.path.hasSuffix("wine/.yaagl-wine-stamp.json"))
      #expect(try h.readStamp() == WineStamp(schemaVersion: 1, wineVersion: "test-wine-1", dxmtVersion: "abc1234"))
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
      #expect(Set(top) == ["wine", "wineprefix", "wineboot.log", "winecfg.log"])
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

  @Test("WIN-014 progress arrives as downloads (in parallel), extracting, configuring, initializingPrefix, installingDXMT, finalizing")
  func progressOrder() async throws {
    try await withWineTempDirectory { dir in
      let h = try makeWineHarness(in: dir)
      let collector = WineProgressCollector()
      try await h.runtime.ensureInstalled(progress: collector.callback)
      // The two downloads run at the same time, so their reports may interleave; both come first.
      let stages = collector.collapsed
      let downloads = stages.prefix { $0.hasPrefix("downloading") }
      #expect(Set(downloads) == ["downloadingWine", "downloadingDXMT"])
      #expect(
        Array(stages.dropFirst(downloads.count)) == [
          "extracting", "configuring", "initializingPrefix", "installingDXMT", "finalizing",
        ])
    }
  }
}
