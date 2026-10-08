import Foundation
import Testing

@testable import Launcher

struct FakeGameClient: GameClient {
  var stubbedStatus = GameStatus()

  func status() async throws -> GameStatus { stubbedStatus }

  func run(_ job: GameJob) -> AsyncThrowingStream<JobProgress, Error> {
    AsyncThrowingStream { $0.finish() }
  }

  func launch(_ options: LaunchOptions) async throws -> LaunchOutcome { .exited }

  func backgroundImage() async -> BackgroundImage { .bundledDefault }
}

@Suite struct LauncherTests {
  @Test func primaryActionFollowsStatus() {
    #expect(PrimaryAction.derive(nil) == .install)
    #expect(PrimaryAction.derive(GameStatus(localVersion: "5.0.0")) == .launch)
    #expect(PrimaryAction.derive(GameStatus(localVersion: "5.0.0", canUpdate: true)) == .update)
  }

  @MainActor @Test func modelRefreshesFromClient() async {
    let model = LauncherModel(client: FakeGameClient(stubbedStatus: GameStatus(localVersion: "5.0.0")))
    #expect(model.primaryAction == .install)
    await model.refresh()
    #expect(model.primaryAction == .launch)
  }
}
