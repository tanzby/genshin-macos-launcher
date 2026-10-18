import Foundation
import Launcher
import Testing
import TestSupport

@testable import GenshinCN

@Suite struct GenshinCNTests {
  @Test func clientIsAGameClientAndFallsBackToTheBundledBackgroundWithoutAProvider() async {
    let rig = ClientRig()
    let client: any GameClient = rig.client
    #expect(await client.backgroundImage() == .bundledDefault)
  }

  @Test func APP_021_clientServesTheProvidersImageAndItsFallback() async throws {
    let cache = temporaryURL("bg")
    let (session, _) = BackgroundStub.session(BackgroundImageProviderTests.server())
    let rig = ClientRig()
    let client = GenshinCNClient(
      dataDirectory: rig.data, protonExtras: rig.protonExtras, launcher: { [launcher = rig.launcher] _ in launcher },
      background: BackgroundImageProvider(cacheDirectory: cache, session: session))

    guard case .remote(let file) = await client.backgroundImage() else {
      Issue.record("expected the downloaded image")
      return
    }
    #expect(try Data(contentsOf: file) == BackgroundImageProviderTests.png)

    let (offline, _) = BackgroundStub.session { _ in nil }
    let fallback = GenshinCNClient(
      dataDirectory: rig.data, protonExtras: rig.protonExtras, launcher: { [launcher = rig.launcher] _ in launcher },
      background: BackgroundImageProvider(
        cacheDirectory: cache.appending(path: "empty", directoryHint: .isDirectory), session: offline))
    #expect(await fallback.backgroundImage() == .bundledDefault)
  }
}

@Suite struct TelemetryHostsTests {
  @Test func WIN_011_blocksSixUniqueTelemetryDomains() {
    #expect(GenshinCN.telemetryDomains.count == 6)
    #expect(Set(GenshinCN.telemetryDomains).count == 6)
    #expect(GenshinCN.hostsBlocklist().domains == GenshinCN.telemetryDomains)
  }
}
