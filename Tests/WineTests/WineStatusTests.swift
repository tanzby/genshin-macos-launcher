import Foundation
import Platform
import Testing

@testable import Wine

@Suite("WIN-001..004 pinned versions and status") struct WineStatusTests {
  @Test("WIN-001 pinned distribution id equals WineRuntime.pinnedVersion")
  func pinnedDistributionId() {
    #expect(WineDistribution.pinned.id == "11.0-1-crossover-signed-experimental")
    #expect(WineRuntime.pinnedVersion == WineDistribution.pinned.id)
  }

  @Test("WIN-001 pinned distribution is an https .tar.xz with a 64-hex sha256")
  func pinnedDistributionShape() {
    let pinned = WineDistribution.pinned
    #expect(pinned.url.scheme == "https")
    #expect(pinned.url.lastPathComponent.hasSuffix(".tar.xz"))
    #expect(pinned.sha256.count == 64)
    #expect(pinned.sha256.allSatisfy { $0.isHexDigit })
    #expect(pinned.winePath == "wine")
  }

  @Test("WIN-002 pinned DXMT is 654f547 and its zip URL names the commit")
  func pinnedDXMT() {
    let dxmt = DXMTRelease.pinned
    #expect(dxmt.version == "654f547")
    #expect(dxmt.commit.hasPrefix(dxmt.version))
    #expect(dxmt.zipURL.absoluteString.contains(dxmt.commit))
    #expect(dxmt.zipURL.scheme == "https")
    #expect(dxmt.sha256.count == 64)
  }

  @Test("WIN-003 empty data directory needs install: notInstalled")
  func emptyDirectory() async throws {
    try await withWineTempDirectory { dir in
      let h = try makeWineHarness(in: dir)
      #expect(await h.runtime.status() == .needsInstall(.notInstalled))
    }
  }

  @Test("WIN-003 wine directory without stamp is interrupted")
  func wineWithoutStamp() async throws {
    try await withWineTempDirectory { dir in
      let h = try makeWineHarness(in: dir)
      try h.writeFile("wine/bin/wine")
      #expect(await h.runtime.status() == .needsInstall(.interrupted))
    }
  }

  @Test("WIN-003 status is ready after a successful install")
  func readyAfterInstall() async throws {
    try await withWineTempDirectory { dir in
      let h = try await makeInstalledWineHarness(in: dir)
      #expect(await h.runtime.status() == .ready)
    }
  }

  @Test("WIN-003 stamp for another wineVersion is versionMismatch")
  func otherWineVersion() async throws {
    try await withWineTempDirectory { dir in
      let h = try await makeInstalledWineHarness(in: dir)
      try JSONEncoder().encode(WineStamp(wineVersion: "other", dxmtVersion: h.fixtures.dxmt.version))
        .write(to: h.layout.stampFile)
      #expect(await h.runtime.status() == .needsInstall(.versionMismatch))
    }
  }

  @Test("WIN-019 WIN-003 stamp for another dxmtVersion is versionMismatch")
  func otherDXMTVersion() async throws {
    try await withWineTempDirectory { dir in
      let h = try await makeInstalledWineHarness(in: dir)
      try JSONEncoder().encode(WineStamp(wineVersion: h.fixtures.distribution.id, dxmtVersion: "0000000"))
        .write(to: h.layout.stampFile)
      #expect(await h.runtime.status() == .needsInstall(.versionMismatch))
    }
  }

  @Test("WIN-003 legacy TS tag 11.0-dxmt-signed-with-patches is versionMismatch")
  func legacyTag() async throws {
    try await withWineTempDirectory { dir in
      let h = try await makeInstalledWineHarness(in: dir)
      try JSONEncoder().encode(
        WineStamp(wineVersion: "11.0-dxmt-signed-with-patches", dxmtVersion: h.fixtures.dxmt.version)
      ).write(to: h.layout.stampFile)
      #expect(await h.runtime.status() == .needsInstall(.versionMismatch))
    }
  }

  @Test("WIN-003 garbage stamp is versionMismatch")
  func garbageStamp() async throws {
    try await withWineTempDirectory { dir in
      let h = try await makeInstalledWineHarness(in: dir)
      try Data("this is not json".utf8).write(to: h.layout.stampFile)
      #expect(await h.runtime.status() == .needsInstall(.versionMismatch))
    }
  }

  @Test(
    "WIN-004 deleting a required path after install is corrupt",
    arguments: [
      "wine/bin/wine",
      "wineprefix",
      "wineprefix/drive_c/windows/system32/winemetal.dll",
      "wine/lib/wine/x86_64-windows/d3d11.dll",
      "wine/lib/wine/x86_64-unix/winemetal.so",
    ])
  func missingRequiredPath(relative: String) async throws {
    try await withWineTempDirectory { dir in
      let h = try await makeInstalledWineHarness(in: dir)
      try FileManager.default.removeItem(at: h.root.appending(path: relative))
      let status = await h.runtime.status()
      guard case .needsInstall(.corrupt) = status else {
        Issue.record("expected .needsInstall(.corrupt) after deleting \(relative), got \(status)")
        return
      }
    }
  }

  @Test("WIN-004 status does not depend on lib/wine/x86_64-unix/wine")
  func unixWineBinaryIrrelevant() async throws {
    try await withWineTempDirectory { dir in
      let h = try await makeInstalledWineHarness(in: dir)
      let unixWine = h.layout.unixLibraryDirectory.appending(path: "wine")
      try? FileManager.default.removeItem(at: unixWine)
      #expect(await h.runtime.status() == .ready)
      try FileManager.default.createDirectory(
        at: h.layout.unixLibraryDirectory, withIntermediateDirectories: true)
      try Data("renamed".utf8).write(to: h.layout.unixLibraryDirectory.appending(path: "wine-renamed"))
      #expect(await h.runtime.status() == .ready)
    }
  }

  @Test("WIN-004 status does not depend on lib/wine/x86_64-unix/wine-host")
  func wineHostIrrelevant() async throws {
    try await withWineTempDirectory { dir in
      let h = try await makeInstalledWineHarness(in: dir)
      try? FileManager.default.removeItem(at: h.layout.unixLibraryDirectory.appending(path: "wine-host"))
      #expect(await h.runtime.status() == .ready)
    }
  }
}
