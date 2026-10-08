import SwiftProtobuf
import Testing

@testable import Sophon

@Suite struct SophonTests {
  @Test func onlineInfoDefaultsToNoPreDownload() {
    let info = SophonOnlineInfo(latestVersion: "5.0.0", installSize: 1)
    #expect(info.preDownload == nil)
  }

  @Test func protobufRoundTrips() throws {
    var message = Google_Protobuf_StringValue()
    message.value = "sophon"
    let decoded = try Google_Protobuf_StringValue(serializedBytes: message.serializedBytes() as [UInt8])
    #expect(decoded.value == "sophon")
  }
}
