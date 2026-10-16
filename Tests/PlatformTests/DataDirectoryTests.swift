import Foundation
import Testing
import TestSupport

@testable import Platform

@Suite struct DataDirectoryTests {
  /// Everything the TS launcher left behind that ADR 0001 says to delete.
  static let residue = [
    ".storage/game_install_dir.neustorage", "wine/bin/wine", "wineprefix/system.reg",
    "dxmt/d3d11.dll", "GenshinLauncherGame.app/Contents/Info.plist", "sidecar/aria2/aria2c",
    "resources.neu", "resources.neu.update", ".bundle-stamp", "neutralinojs.log",
    "aria2.session", "decompress.log", "winedrv_config.bat", "config.bat",
    "hk4e_resolution.reg", "GenshinImpact_d3d11.log", "GenshinImpact_dxgi.log",
    "wineboot.log", "winecfg.log", "wine.tar.xz", "icon.icns",
  ]
  static let kept = [
    "wine-gptk4/bin/wine", "wine-gptk4-native/bin/wine", "gptk4/lib/x", "logs/game_1.log", "unrelated.txt",
  ]

  @Test func APP_002_defaultRootIsGenshinLauncherUnderApplicationSupport() {
    let root = DataDirectory.defaultRoot
    #expect(root.lastPathComponent == "Genshin Launcher")
    #expect(root.deletingLastPathComponent().lastPathComponent == "Application Support")
  }

  @Test func APP_002_layoutResolvesUnderRoot() {
    let directory = DataDirectory(root: URL(filePath: "/data/Genshin Launcher"))
    #expect(directory.wine.path == "/data/Genshin Launcher/wine")
    #expect(directory.wineGPTK4.path == "/data/Genshin Launcher/wine-gptk4-native")
    #expect(directory.winePrefix.path == "/data/Genshin Launcher/wineprefix")
    #expect(directory.logs.path == "/data/Genshin Launcher/logs")
    #expect(directory.background.path == "/data/Genshin Launcher/background")
    #expect(directory.nativeMarker.path == "/data/Genshin Launcher/.genshin-launcher-native")
  }

  @Test func APP_002_firstLaunchWithoutMarkerWipesTSResidueAndKeepsUserData() throws {
    let temp = TempDir()
    for file in Self.residue + Self.kept { try temp.makeFile("Genshin Launcher/" + file) }
    let root = temp.path("Genshin Launcher")

    let directory = try DataDirectory.prepare(root: root, externalResidue: [])

    #expect(directory.root == root)
    for file in Self.residue {
      let top = file.split(separator: "/").first.map(String.init)!
      #expect(!temp.exists("Genshin Launcher/" + top), "\(top) should be gone")
    }
    for file in Self.kept { #expect(temp.exists("Genshin Launcher/" + file), "\(file) should stay") }
    #expect(temp.exists("Genshin Launcher/.genshin-launcher-native"))
  }

  @Test func APP_002_externalCachesAreRemovedToo() throws {
    let temp = TempDir()
    try temp.makeFile("Genshin Launcher/wine/x")
    try temp.makeFile("Caches/com.3shain.yaagl/Cache.db")
    try temp.makeFile("WebKit/com.3shain.yaagl/data")

    _ = try DataDirectory.prepare(
      root: temp.path("Genshin Launcher"),
      externalResidue: [temp.path("Caches", "com.3shain.yaagl"), temp.path("WebKit", "com.3shain.yaagl")])

    #expect(!temp.exists("Caches/com.3shain.yaagl"))
    #expect(!temp.exists("WebKit/com.3shain.yaagl"))
  }

  @Test func APP_002_freshInstallCreatesRootAndMarker() throws {
    let temp = TempDir()
    let root = temp.path("Genshin Launcher")

    let directory = try DataDirectory.prepare(root: root, externalResidue: [])

    let marker = try JSONDecoder().decode(
      DataDirectory.Marker.self, from: Data(contentsOf: directory.nativeMarker))
    #expect(marker.schemaVersion == DataDirectory.Marker.currentSchemaVersion)
  }

  @Test func APP_002_existingMarkerSkipsCleanup() throws {
    let temp = TempDir()
    let root = temp.path("Genshin Launcher")
    _ = try DataDirectory.prepare(root: root, externalResidue: [])
    try temp.makeFile("Genshin Launcher/wine/stamp")
    try temp.makeFile("Genshin Launcher/wineprefix/user.reg")

    _ = try DataDirectory.prepare(root: root, externalResidue: [])

    #expect(temp.exists("Genshin Launcher/wine/stamp"))
    #expect(temp.exists("Genshin Launcher/wineprefix/user.reg"))
  }

  @Test func APP_002_markerIgnoresUnknownFields() throws {
    let temp = TempDir()
    try temp.makeFile("Genshin Launcher/.genshin-launcher-native", contents: #"{"schemaVersion":1,"future":"x"}"#)
    try temp.makeFile("Genshin Launcher/wine/stamp")

    _ = try DataDirectory.prepare(root: temp.path("Genshin Launcher"), externalResidue: [])

    #expect(temp.exists("Genshin Launcher/wine/stamp"))
  }

  @Test func APP_002_unreadableMarkerIsAnErrorAndNeverWipes() throws {
    let temp = TempDir()
    try temp.makeFile("Genshin Launcher/.genshin-launcher-native", contents: "garbage")
    try temp.makeFile("Genshin Launcher/wine/stamp")

    #expect(throws: DataDirectory.PrepareError.self) {
      try DataDirectory.prepare(root: temp.path("Genshin Launcher"), externalResidue: [])
    }
    #expect(temp.exists("Genshin Launcher/wine/stamp"))
    #expect(try String(contentsOf: temp.path("Genshin Launcher/.genshin-launcher-native"), encoding: .utf8) == "garbage")
  }

  @Test func APP_002_markerFromNewerSchemaIsAnError() throws {
    let temp = TempDir()
    try temp.makeFile("Genshin Launcher/.genshin-launcher-native", contents: #"{"schemaVersion":999}"#)
    try temp.makeFile("Genshin Launcher/wine/stamp")

    #expect(throws: DataDirectory.PrepareError.self) {
      try DataDirectory.prepare(root: temp.path("Genshin Launcher"), externalResidue: [])
    }
    #expect(temp.exists("Genshin Launcher/wine/stamp"))
  }

  @Test func APP_002_cleanupIsIdempotentAfterInterruption() throws {
    // A previous run removed part of the residue and never wrote the marker.
    let temp = TempDir()
    try temp.makeFile("Genshin Launcher/sidecar/x")
    try temp.makeFile("Genshin Launcher/logs/game.log")

    _ = try DataDirectory.prepare(root: temp.path("Genshin Launcher"), externalResidue: [])

    #expect(!temp.exists("Genshin Launcher/sidecar"))
    #expect(temp.exists("Genshin Launcher/logs/game.log"))
    #expect(temp.exists("Genshin Launcher/.genshin-launcher-native"))
  }

  @Test func APP_002_symlinkResidueIsUnlinkedNotFollowed() throws {
    let temp = TempDir()
    try temp.makeFile("Elsewhere/keep.txt")
    try FileManager.default.createDirectory(at: temp.path("Genshin Launcher"), withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(
      at: temp.path("Genshin Launcher", "wine"), withDestinationURL: temp.path("Elsewhere"))

    _ = try DataDirectory.prepare(root: temp.path("Genshin Launcher"), externalResidue: [])

    #expect(!temp.exists("Genshin Launcher/wine"))
    #expect(temp.exists("Elsewhere/keep.txt"))
  }
}

@Suite struct DataDirectoryMarkerLinkTests {
  @Test func APP_002_danglingSymlinkMarkerIsNotTreatedAsMissing() throws {
    let temp = TempDir()
    try temp.makeFile("Genshin Launcher/wine/stamp")
    try FileManager.default.createSymbolicLink(
      at: temp.path("Genshin Launcher", ".genshin-launcher-native"), withDestinationURL: temp.path("nowhere"))
    #expect(throws: DataDirectory.PrepareError.self) {
      try DataDirectory.prepare(root: temp.path("Genshin Launcher"), externalResidue: [])
    }
    #expect(temp.exists("Genshin Launcher/wine/stamp"))
  }
}
