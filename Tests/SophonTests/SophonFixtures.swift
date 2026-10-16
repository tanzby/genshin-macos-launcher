import Foundation
import Testing

@testable import Sophon

extension SophonEndpoints {
  /// The endpoints the recorded fixtures were taken from (Genshin Impact, CN). The real constants live in
  /// GenshinCN; its tests check them against the same values.
  static let recordedCN = SophonEndpoints(
    hypConnectBase: URL(string: "https://hyp-api.mihoyo.com/hyp/hyp-connect/api")!,
    downloaderBase: URL(string: "https://api-takumi.mihoyo.com/downloader/sophon_chunk/api")!,
    gameID: "1Z8W5NHUQb",
    launcherID: "jGHBHlcOq1")
}

enum Fixture {
  static func data(_ name: String, _ ext: String) throws -> Data {
    let url = try #require(
      Bundle.module.url(forResource: name, withExtension: ext, subdirectory: "Fixtures"))
    return try Data(contentsOf: url)
  }
}
