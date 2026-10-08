import Foundation
import Testing

@testable import Platform

@Suite struct DataDirectoryTests {
  /// Everything the TS launcher left behind that ADR 0001 says to delete.
  static let residue = [
    ".storage/game_install_dir.neustorage", "wine/bin/wine", "wineprefix/system.reg",
    "dxmt/d3d11.dll", "YaaglGame.app/Contents/Info.plist", "sidecar/aria2/aria2c",
    "resources.neu", "resources.neu.update", ".bundle-stamp", "neutralinojs.log",
    "aria2.session", "decompress.log", "winedrv_config.bat", "config.bat",
    "hk4e_resolution.reg", "GenshinImpact_d3d11.log", "GenshinImpact_dxgi.log",
    "wineboot.log", "winecfg.log", "wine.tar.xz", "icon.icns",
  ]
  static let kept = [
    "wine-gptk4/bin/wine", "gptk4/lib/x", "logs/game_1.log", "unrelated.txt",
  ]

  @Test func APP_002_defaultRootIsYaaglUnderApplicationSupport() {
    let root = DataDirectory.defaultRoot
    #expect(root.lastPathComponent == "Yaagl")
    #expect(root.deletingLastPathComponent().lastPathComponent == "Application Support")
  }

  @Test func APP_002_layoutResolvesUnderRoot() {
    let directory = DataDirectory(root: URL(filePath: "/data/Yaagl"))
    #expect(directory.wine.path == "/data/Yaagl/wine")
    #expect(directory.winePrefix.path == "/data/Yaagl/wineprefix")
    #expect(directory.logs.path == "/data/Yaagl/logs")
    #expect(directory.nativeMarker.path == "/data/Yaagl/.yaagl-native")
  }

  @Test func APP_002_firstLaunchWithoutMarkerWipesTSResidueAndKeepsUserData() throws {
    let temp = try TempDir()
    defer { temp.cleanup() }
    for file in Self.residue + Self.kept { try temp.makeFile("Yaagl/" + file) }
    let root = temp.path("Yaagl")

    let directory = try DataDirectory.prepare(root: root, externalResidue: [])

    #expect(directory.root == root)
    for file in Self.residue {
      let top = file.split(separator: "/").first.map(String.init)!
      #expect(!temp.exists("Yaagl/" + top), "\(top) should be gone")
    }
    for file in Self.kept { #expect(temp.exists("Yaagl/" + file), "\(file) should stay") }
    #expect(temp.exists("Yaagl/.yaagl-native"))
  }

  @Test func APP_002_externalCachesAreRemovedToo() throws {
    let temp = try TempDir()
    defer { temp.cleanup() }
    try temp.makeFile("Yaagl/wine/x")
    try temp.makeFile("Caches/com.3shain.yaagl/Cache.db")
    try temp.makeFile("WebKit/com.3shain.yaagl/data")

    _ = try DataDirectory.prepare(
      root: temp.path("Yaagl"),
      externalResidue: [temp.path("Caches", "com.3shain.yaagl"), temp.path("WebKit", "com.3shain.yaagl")])

    #expect(!temp.exists("Caches/com.3shain.yaagl"))
    #expect(!temp.exists("WebKit/com.3shain.yaagl"))
  }

  @Test func APP_002_freshInstallCreatesRootAndMarker() throws {
    let temp = try TempDir()
    defer { temp.cleanup() }
    let root = temp.path("Yaagl")

    let directory = try DataDirectory.prepare(root: root, externalResidue: [])

    let marker = try JSONDecoder().decode(
      DataDirectory.Marker.self, from: Data(contentsOf: directory.nativeMarker))
    #expect(marker.schemaVersion == DataDirectory.Marker.currentSchemaVersion)
  }

  @Test func APP_002_existingMarkerSkipsCleanup() throws {
    let temp = try TempDir()
    defer { temp.cleanup() }
    let root = temp.path("Yaagl")
    _ = try DataDirectory.prepare(root: root, externalResidue: [])
    try temp.makeFile("Yaagl/wine/stamp")
    try temp.makeFile("Yaagl/wineprefix/user.reg")

    _ = try DataDirectory.prepare(root: root, externalResidue: [])

    #expect(temp.exists("Yaagl/wine/stamp"))
    #expect(temp.exists("Yaagl/wineprefix/user.reg"))
  }

  @Test func APP_002_markerIgnoresUnknownFields() throws {
    let temp = try TempDir()
    defer { temp.cleanup() }
    try temp.makeFile("Yaagl/.yaagl-native", contents: #"{"schemaVersion":1,"future":"x"}"#)
    try temp.makeFile("Yaagl/wine/stamp")

    _ = try DataDirectory.prepare(root: temp.path("Yaagl"), externalResidue: [])

    #expect(temp.exists("Yaagl/wine/stamp"))
  }

  @Test func APP_002_unreadableMarkerIsAnErrorAndNeverWipes() throws {
    let temp = try TempDir()
    defer { temp.cleanup() }
    try temp.makeFile("Yaagl/.yaagl-native", contents: "garbage")
    try temp.makeFile("Yaagl/wine/stamp")

    #expect(throws: DataDirectory.PrepareError.self) {
      try DataDirectory.prepare(root: temp.path("Yaagl"), externalResidue: [])
    }
    #expect(temp.exists("Yaagl/wine/stamp"))
    #expect(try String(contentsOf: temp.path("Yaagl/.yaagl-native"), encoding: .utf8) == "garbage")
  }

  @Test func APP_002_markerFromNewerSchemaIsAnError() throws {
    let temp = try TempDir()
    defer { temp.cleanup() }
    try temp.makeFile("Yaagl/.yaagl-native", contents: #"{"schemaVersion":999}"#)
    try temp.makeFile("Yaagl/wine/stamp")

    #expect(throws: DataDirectory.PrepareError.self) {
      try DataDirectory.prepare(root: temp.path("Yaagl"), externalResidue: [])
    }
    #expect(temp.exists("Yaagl/wine/stamp"))
  }

  @Test func APP_002_cleanupIsIdempotentAfterInterruption() throws {
    // A previous run removed part of the residue and never wrote the marker.
    let temp = try TempDir()
    defer { temp.cleanup() }
    try temp.makeFile("Yaagl/sidecar/x")
    try temp.makeFile("Yaagl/logs/game.log")

    _ = try DataDirectory.prepare(root: temp.path("Yaagl"), externalResidue: [])

    #expect(!temp.exists("Yaagl/sidecar"))
    #expect(temp.exists("Yaagl/logs/game.log"))
    #expect(temp.exists("Yaagl/.yaagl-native"))
  }

  @Test func APP_002_symlinkResidueIsUnlinkedNotFollowed() throws {
    let temp = try TempDir()
    defer { temp.cleanup() }
    try temp.makeFile("Elsewhere/keep.txt")
    try FileManager.default.createDirectory(at: temp.path("Yaagl"), withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(
      at: temp.path("Yaagl", "wine"), withDestinationURL: temp.path("Elsewhere"))

    _ = try DataDirectory.prepare(root: temp.path("Yaagl"), externalResidue: [])

    #expect(!temp.exists("Yaagl/wine"))
    #expect(temp.exists("Elsewhere/keep.txt"))
  }
}

@Suite struct DataDirectoryMarkerLinkTests {
  @Test func APP_002_danglingSymlinkMarkerIsNotTreatedAsMissing() throws {
    let temp = try TempDir()
    defer { temp.cleanup() }
    try temp.makeFile("Yaagl/wine/stamp")
    try FileManager.default.createSymbolicLink(
      at: temp.path("Yaagl", ".yaagl-native"), withDestinationURL: temp.path("nowhere"))
    #expect(throws: DataDirectory.PrepareError.self) {
      try DataDirectory.prepare(root: temp.path("Yaagl"), externalResidue: [])
    }
    #expect(temp.exists("Yaagl/wine/stamp"))
  }
}
