import Foundation
import Platform
import Synchronization
import Testing
import TestSupport

@testable import Launcher

@MainActor
private func makeController(
  status: GameStatus = GameStatus(localVersion: "5.0.0", remoteVersion: "5.0.0"),
  hosts: HostsBlocklist.Status = .current, startup: StartupSteps? = nil, gameDirectory: URL? = temporaryURL("genshin-launcher-mc")
) -> (MainController, FakeGameClient, SettingsModel) {
  let settings = SettingsModel(defaults: makeTemporaryDefaults("controller").defaults)
  settings.gameDirectory = gameDirectory
  let client = FakeGameClient(status: status)
  let launcher = LauncherModel(client: client, startup: startup, availableDiskSpace: { _ in Int64.max })
  let onboarding = OnboardingModel(hosts: FakeHosts(hosts), settings: settings)
  return (MainController(launcher: launcher, settings: settings, onboarding: onboarding), client, settings)
}

@MainActor @Suite struct MainControllerTests {
  @Test func APP_017_presentationFollowsTheLauncherAfterRefresh() async {
    let (controller, _, _) = makeController()
    #expect(controller.presentation.button == .install)
    #expect(!controller.hasLoaded)
    await controller.refresh()
    #expect(controller.hasLoaded)
    #expect(controller.presentation.button == .launch)
    #expect(controller.presentation.buttonEnabled)
  }

  @Test func APP_001_aMissingRosettaIsRetriedOnTheNextRefreshUntilItIsInstalled() async {
    let installed = Mutex(false)
    let steps = StartupSteps(rosettaInstalled: { installed.withLock { $0 } }, recoverSession: {})
    let (controller, client, _) = makeController(startup: steps)
    await controller.refresh()
    #expect(controller.launcher.isRosettaMissing)
    #expect(client.statusCalls == 0, "no game status before Rosetta is there")
    installed.withLock { $0 = true }
    await controller.refreshWhenIdle()
    #expect(!controller.launcher.isRosettaMissing)
    #expect(controller.launcher.hasBootstrapped)
    #expect(controller.presentation.button == .launch)
  }

  @Test func APP_010_reactivationRequeriesAfterAFailedFirstQuery() async {
    let (controller, client, _) = makeController()
    client.setStatusFailure(LauncherError.offline)
    await controller.refresh()
    #expect(!controller.presentation.buttonEnabled)
    client.setStatus(GameStatus(localVersion: "5.0.0", remoteVersion: "5.0.0"))
    await controller.refreshWhenIdle()
    #expect(controller.presentation.button == .launch)
    #expect(controller.presentation.buttonEnabled)
  }

  @Test func APP_010_reactivationLeavesARunningJobAlone() async throws {
    let (controller, client, _) = makeController(status: GameStatus())
    await controller.refresh()
    await controller.perform(.install)
    _ = try await client.nextRun()
    let calls = client.statusCalls
    await controller.refreshWhenIdle()
    #expect(client.statusCalls == calls)
    await controller.launcher.shutdown()
  }

  @Test func CFG_009_gameDirectoryIsHandedToTheLauncher() async {
    let (controller, _, settings) = makeController(gameDirectory: nil)
    await controller.refresh()
    #expect(controller.launcher.gameDirectory == nil)
    settings.gameDirectory = URL(filePath: "/tmp/elsewhere")
    await controller.refresh()
    #expect(controller.launcher.gameDirectory == URL(filePath: "/tmp/elsewhere"))
  }

  @Test func APP_017_installRightAfterPickingAFolderDoesNotWaitForARefresh() async throws {
    let (controller, client, settings) = makeController(status: GameStatus(), gameDirectory: nil)
    await controller.refresh()
    settings.gameDirectory = temporaryURL("genshin-launcher-mc")
    await controller.perform(.install)
    #expect(controller.actionError == nil)
    _ = try await client.nextRun()
    await controller.launcher.shutdown()
  }

  @Test func APP_017_installWithoutADirectoryAsksForOneInsteadOfFailing() async {
    let (controller, client, _) = makeController(status: GameStatus(), gameDirectory: nil)
    await controller.refresh()
    #expect(controller.needsGameDirectory(for: .install))
    await controller.perform(.install)
    #expect(client.runs.isEmpty)
    #expect(controller.actionError == .noGameDirectory)
  }

  @Test func APP_013_aRefusedStartSurfacesAsAnErrorInTheCapsule() async {
    let (controller, client, _) = makeController(
      status: GameStatus(localVersion: "5.0.0", remoteVersion: "5.0.0"))
    client.setRequiredDiskSpace(10 << 30, for: .repair)
    let tiny = LauncherModel(client: client, gameDirectory: URL(filePath: "/tmp/x"), availableDiskSpace: { _ in 1 << 30 })
    let c = MainController(launcher: tiny, settings: controller.settings, onboarding: controller.onboarding)
    await c.refresh()
    await c.repair()
    guard case .insufficientDiskSpace = c.actionError else {
      Issue.record("expected insufficientDiskSpace, got \(String(describing: c.actionError))")
      return
    }
    #expect(c.presentation.status == .error(c.actionError!))
  }

  @Test func APP_013_theNextActionClearsAStaleError() async {
    let (controller, _, _) = makeController(status: GameStatus(), gameDirectory: nil)
    await controller.refresh()
    await controller.perform(.install)
    #expect(controller.actionError == .noGameDirectory)
    await controller.perform(.pausing)  // a no-op button still starts from a clean slate
    #expect(controller.actionError == nil)
  }

  @Test func APP_017_pauseAndResumeGoThroughTheLauncher() async throws {
    let (controller, client, _) = makeController(status: GameStatus())
    await controller.refresh()
    await controller.perform(.install)
    let run = try await client.nextRun()
    client.yield(.running(done: 1, total: 10), run: run)
    #expect(controller.presentation.button == .pause)
    await controller.perform(.pause)
    #expect(controller.presentation.button == .resume)
    await controller.perform(.resume)
    _ = try await client.nextRun()
    #expect(client.runs == [.install, .install])
    await controller.launcher.shutdown()
  }

  @Test func WIN_011_launchIsRefusedWithoutTheHostsBlock() async {
    let (controller, client, _) = makeController(hosts: .missing)
    await controller.refresh()
    #expect(!controller.presentation.buttonEnabled)
    await controller.perform(.launch)
    #expect(client.launchOptions.isEmpty)
  }
}
