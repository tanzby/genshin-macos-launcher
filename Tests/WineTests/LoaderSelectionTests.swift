import Foundation
import Testing

@testable import Wine

@Suite struct LoaderSelectionTests {
  @Test func WIN_016_prefersWine64OverWine() async throws {
    try await withWineTempDirectory { root in
      let layout = WineLayout(root: root)
      let bin = layout.runtimeDirectory.appending(path: "bin", directoryHint: .isDirectory)
      try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
      try Data().write(to: bin.appending(path: "wine"))
      #expect(layout.loader.lastPathComponent == "wine")
      try Data().write(to: bin.appending(path: "wine64"))
      #expect(layout.loader.lastPathComponent == "wine64")
    }
  }

  @Test func WIN_016_launchEnvironmentIsExactlyPrefixDebugRecipeAndHostVariables() {
    #expect(GameSession.wineDebug == "fixme-all,err-unwind,+timestamp")
    #expect(GameSession.gameHostBundleIdentifier == "io.github.tanzby.yaagl.game")
  }
}
