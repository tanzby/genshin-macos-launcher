import Launcher
import Testing

@testable import GenshinCN

@Suite struct GenshinCNTests {
  @Test func clientIsAGameClientWithoutImplementationYet() async {
    let client: any GameClient = GenshinCNClient()
    await #expect(throws: GenshinCNClientError.notImplemented) {
      try await client.status()
    }
    #expect(await client.backgroundImage() == .bundledDefault)
    #expect(GenshinCN.channel == "hk4ecn")
  }
}

@Suite struct TelemetryHostsTests {
  @Test func WIN_011_blocksSixUniqueTelemetryDomains() {
    #expect(GenshinCN.telemetryDomains.count == 6)
    #expect(Set(GenshinCN.telemetryDomains).count == 6)
    #expect(GenshinCN.hostsBlocklist().domains == GenshinCN.telemetryDomains)
  }
}
