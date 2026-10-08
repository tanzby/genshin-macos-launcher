import Testing

@testable import Platform

@Suite struct PlatformTests {
  @Test func defaultRootIsYaaglUnderApplicationSupport() {
    let root = DataDirectory.defaultRoot
    #expect(root.lastPathComponent == "Yaagl")
    #expect(root.deletingLastPathComponent().lastPathComponent == "Application Support")
  }

  @Test func nativeMarkerLivesInRoot() {
    let directory = DataDirectory(root: DataDirectory.defaultRoot)
    #expect(directory.nativeMarker.lastPathComponent == ".yaagl-native")
  }
}
