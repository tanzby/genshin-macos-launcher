import Foundation
import Platform
import Testing

@testable import Wine

@Suite struct WineTests {
  @Test func runtimeLivesInDataDirectory() {
    let root = URL(filePath: "/tmp/yaagl-data", directoryHint: .isDirectory)
    let runtime = WineRuntime(dataDirectory: DataDirectory(root: root))
    #expect(runtime.runtimeDirectory.path == "/tmp/yaagl-data/wine")
    #expect(WineRuntime.pinnedVersion == "11.0-1-crossover-signed-experimental")
  }
}
