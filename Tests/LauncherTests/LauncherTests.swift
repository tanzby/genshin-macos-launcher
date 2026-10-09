import Foundation
import Testing

@testable import Launcher

@Suite struct LauncherTests {
  @Test func primaryActionFollowsStatus() {
    #expect(PrimaryAction.derive(nil) == .install)
    #expect(PrimaryAction.derive(GameStatus(localVersion: "5.0.0")) == .launch)
    #expect(PrimaryAction.derive(GameStatus(localVersion: "5.0.0", canUpdate: true)) == .update)
  }

  @MainActor @Test func modelRefreshesFromClient() async {
    let model = LauncherModel(client: FakeGameClient(status: GameStatus(localVersion: "5.0.0")))
    #expect(model.primaryAction == .install)
    await model.refresh()
    #expect(model.primaryAction == .launch)
  }
}
