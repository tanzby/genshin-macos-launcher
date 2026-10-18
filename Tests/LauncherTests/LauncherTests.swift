import Foundation
import Testing

@testable import Launcher

@Suite struct LauncherTests {
  @MainActor @Test func modelRefreshesFromClient() async {
    let model = LauncherModel(client: FakeGameClient(status: GameStatus(localVersion: "5.0.0")))
    #expect(model.primaryAction == .install)
    await model.refresh()
    #expect(model.primaryAction == .launch)
  }
}
