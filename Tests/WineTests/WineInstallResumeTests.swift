import Foundation
import Platform
import Testing

@testable import Wine

// Ticket #27: space preflight, concurrent downloads, resumable archive location, tool output on failure.

@Suite("WIN-006/007/008 preflight, concurrency and diagnostics") struct WineInstallResumeTests {
  @Test("WIN-006 too little free space throws insufficientDiskSpace before any download or deletion")
  func insufficientSpace() async throws {
    try await withWineTempDirectory { dir in
      var options = WineHarnessOptions()
      options.availableBytes = 1_000_000_000
      let h = try makeWineHarness(in: dir, options: options)
      try h.writeFile("wine/sentinel.txt")
      try h.writeFile("wineprefix/sentinel.txt")

      let required = wineFixtureArchiveSize + 4 * wineFixtureDXMTArchiveSize + wineFixtureInstalledSize
      await #expect(
        throws: WineInstallError.insufficientDiskSpace(required: required, available: 1_000_000_000)
      ) { try await h.install() }

      #expect(h.downloader.requests.isEmpty)
      #expect(wineExists(h.root.appending(path: "wine/sentinel.txt")))
      #expect(wineExists(h.root.appending(path: "wineprefix/sentinel.txt")))
      #expect(h.runner.calls.isEmpty)
    }
  }

  @Test("WIN-006 exactly the required free space is enough")
  func exactSpaceIsEnough() async throws {
    try await withWineTempDirectory { dir in
      var options = WineHarnessOptions()
      options.availableBytes = wineFixtureArchiveSize + 4 * wineFixtureDXMTArchiveSize + wineFixtureInstalledSize
      let h = try makeWineHarness(in: dir, options: options)
      try await h.install()
      #expect(await h.runtime.status() == .ready)
    }
  }

  @Test("WIN-006 an unknown free-space reading does not block the install")
  func unknownSpaceDoesNotBlock() async throws {
    try await withWineTempDirectory { dir in
      var options = WineHarnessOptions()
      options.availableBytes = nil
      let h = try makeWineHarness(in: dir, options: options)
      try await h.install()
      #expect(await h.runtime.status() == .ready)
    }
  }

  @Test("WIN-006 a ready runtime does not look at free space at all")
  func readyRuntimeSkipsPreflight() async throws {
    try await withWineTempDirectory { dir in
      let h = try await makeInstalledWineHarness(in: dir)
      let tight = WineRuntime(
        dataDirectory: DataDirectory(root: h.root), distribution: h.fixtures.distribution, dxmt: h.fixtures.dxmt,
        downloader: h.downloader, runner: h.runner, availableSpace: { _ in 0 })
      try await tight.ensureInstalled()
    }
  }

  @Test("WIN-007 the Wine and DXMT archives download at the same time")
  func concurrentDownloads() async throws {
    try await withWineTempDirectory { dir in
      var options = WineHarnessOptions()
      options.downloadDelay = .milliseconds(100)
      let h = try makeWineHarness(in: dir, options: options)
      try await h.install()
      #expect(h.downloader.maxConcurrentDownloads == 2)
    }
  }

  @Test("WIN-007 a failing download cancels the other one and still installs nothing")
  func failureCancelsTheOtherDownload() async throws {
    try await withWineTempDirectory { dir in
      var options = WineHarnessOptions()
      options.failingURLs = { [$0.dxmt.zipURL] }
      options.downloadDelay = .milliseconds(20)
      let h = try makeWineHarness(in: dir, options: options)
      await #expect(throws: WineStubDownloadFailure()) { try await h.install() }
      #expect(await h.runtime.status() == .needsInstall(.notInstalled))
      #expect(h.runner.calls.isEmpty)
    }
  }

  @Test("WIN-007 archives keep the same path across attempts so a partial download can resume")
  func stableArchivePaths() async throws {
    try await withWineTempDirectory { dir in
      var options = WineHarnessOptions()
      options.failingURLs = { [$0.distribution.url] }
      let h = try makeWineHarness(in: dir, options: options)
      await #expect(throws: WineStubDownloadFailure()) { try await h.install() }
      h.downloader.setFailing([])
      try await h.install()

      let wine = h.downloader.requests.filter { $0.url == h.fixtures.distribution.url }
      #expect(wine.count == 2)
      #expect(Set(wine.map(\.destination)).count == 1)
      let dxmt = h.downloader.requests.filter { $0.url == h.fixtures.dxmt.zipURL }
      #expect(Set(dxmt.map(\.destination)).count == 1)
      for request in h.downloader.requests {
        #expect(
          request.destination.deletingLastPathComponent().resolvingSymlinksInPath().path
            == h.layout.downloadsDirectory.resolvingSymlinksInPath().path)
      }
      #expect(!wineExists(h.layout.downloadsDirectory))  // gone once the install succeeded
    }
  }

  @Test("WIN-007 the progress of each archive grows across several reports")
  func progressGrows() async throws {
    try await withWineTempDirectory { dir in
      let h = try makeWineHarness(in: dir)
      let collector = WineProgressCollector()
      try await h.runtime.ensureInstalled(progress: collector.callback)

      for reports in [collector.wineDownloads, collector.dxmtDownloads] {
        #expect(reports.count >= 3)
        #expect(Set(reports.map(\.total)).count == 1)
        #expect(zip(reports, reports.dropFirst()).allSatisfy { $0.completed < $1.completed })
        #expect(reports.last?.completed == reports.last?.total)
      }
    }
  }

  @Test("WIN-008 extractionFailed carries the tool's output")
  func extractionOutput() async throws {
    try await withWineTempDirectory { dir in
      var options = WineHarnessOptions()
      options.tarExitCode = 1
      options.tarOutput = "tar: Unrecognized archive format"
      let h = try makeWineHarness(in: dir, options: options)
      await #expect(
        throws: WineInstallError.extractionFailed(
          tool: "tar", exitCode: 1, output: "tar: Unrecognized archive format")
      ) { try await h.install() }
    }
  }

  @Test("WIN-008 a very long tool output is cut to its last 2000 characters")
  func extractionOutputIsBounded() async throws {
    try await withWineTempDirectory { dir in
      var options = WineHarnessOptions()
      options.tarExitCode = 1
      options.tarOutput = String(repeating: "x", count: 10_000) + "THE-END"
      let h = try makeWineHarness(in: dir, options: options)
      do {
        try await h.install()
        Issue.record("expected extractionFailed")
      } catch WineInstallError.extractionFailed(_, _, let output) {
        #expect(output.count == 2000)
        #expect(output.hasSuffix("THE-END"))
      }
    }
  }
}
