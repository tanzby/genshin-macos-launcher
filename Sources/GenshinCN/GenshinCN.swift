import Foundation
import Launcher
import Sophon

public enum GenshinCN {
  package static let channel = "hk4ecn"
  public static let executableName = "YuanShen.exe"

  /// What Sophon needs to know about Genshin Impact, CN server. The ids are public identifiers (from
  /// DGP-Studio/Snap.Hutao, MIT).
  package static let sophonGame = SophonGame(
    endpoints: SophonEndpoints(
      hypConnectBase: URL(string: "https://hyp-api.mihoyo.com/hyp/hyp-connect/api")!,
      downloaderBase: URL(string: "https://api-takumi.mihoyo.com/downloader/sophon_chunk/api")!,
      gameID: "1Z8W5NHUQb",
      launcherID: "jGHBHlcOq1"),
    dataFolder: "YuanShen_Data",
    executableName: executableName,
    // Bilibili builds carry PCGameSDK.dll; only the China official release is supported.
    foreignBuildMarkers: ["YuanShen_Data/Plugins/PCGameSDK.dll"],
    tempDirectoryName: PendingJobStore.directoryName)
}
