import Launcher
import Testing

@testable import GenshinCN

@Suite struct GenshinCNTests {
  @Test func clientIsAGameClientAndKeepsTheBundledBackgroundUntilTicket39() async {
    let rig = ClientRig(main: .game("5.6.0"))
    let client: any GameClient = rig.client
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
