import Foundation
import Synchronization
import Testing
import Wine

@testable import Launcher

// ADR 0002 startup order, as far as `LauncherModel` owns it (ticket #37): Rosetta check before any Wine work,
// `GameSession.recover()` once Wine is ready and before the game status is read. The hosts check lives in
// `OnboardingModel`. Also the "launch says Wine is broken" path back to Wine preparation.

private let installed = GameStatus(localVersion: "5.0.0", remoteVersion: "5.0.0")
private let missing = WineStatus.needsInstall(.notInstalled)

/// Scriptable `StartupSteps`; records what the game client and Wine had seen when `recover` ran.
private final class StepsProbe: Sendable {
  private struct State {
    var rosetta = true
    var rosettaChecks = 0
    var recoveries: [Int] = []  // game-status reads seen at each recovery
  }
  private let state = Mutex(State())
  private let fake: FakeGameClient

  init(fake: FakeGameClient, rosetta: Bool = true) {
    self.fake = fake
    state.withLock { $0.rosetta = rosetta }
  }

  func setRosetta(_ installed: Bool) { state.withLock { $0.rosetta = installed } }
  var rosettaChecks: Int { state.withLock { $0.rosettaChecks } }
  var recoveries: [Int] { state.withLock { $0.recoveries } }

  var steps: StartupSteps {
    StartupSteps(
      rosettaInstalled: { [self] in
        state.withLock {
          $0.rosettaChecks += 1
          return $0.rosetta
        }
      },
      recoverSession: { [self] in
        let reads = fake.statusCalls
        state.withLock { $0.recoveries.append(reads) }
      })
  }
}

@MainActor
private struct Harness {
  let wine: FakeWinePreparer
  let fake: FakeGameClient
  let probe: StepsProbe
  let model: LauncherModel
  let directory: URL

  init(wine wineStatus: WineStatus, rosetta: Bool = true) {
    wine = FakeWinePreparer(status: wineStatus)
    fake = FakeGameClient(status: installed)
    probe = StepsProbe(fake: fake, rosetta: rosetta)
    directory = FileManager.default.temporaryDirectory.appending(path: "LauncherStartupTests-\(UUID().uuidString)")
    try! FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    model = LauncherModel(
      client: fake, wine: wine, startup: probe.steps, gameDirectory: directory, chunkTempMargin: 0)
  }

  func cleanUp() { try? FileManager.default.removeItem(at: directory) }

  func bootstrapUntilPreparing() async throws -> (task: Task<Void, Never>, install: Int) {
    let model = model
    let task = Task { @MainActor in await model.bootstrap() }
    return (task, try await wine.nextInstall())
  }
}

@MainActor @Suite struct APP_001_StartupOrderTests {
  @Test func APP_001_missingRosettaStopsBeforeAnyWineWork() async throws {
    let h = Harness(wine: missing, rosetta: false)
    defer { h.cleanUp() }
    await h.model.bootstrap()
    #expect(h.wine.statusCalls == 0)
    #expect(h.wine.installCount == 0)
    #expect(h.fake.statusCalls == 0)
    #expect(h.probe.recoveries.isEmpty)
    #expect(h.model.isRosettaMissing)
    #expect(!h.model.hasBootstrapped)
    #expect(h.model.lastError == .rosettaMissing)
    #expect(h.model.phase == .idle)
    await #expect(throws: LauncherError.rosettaMissing) { try await h.model.prepareWine() }
    #expect(h.wine.installCount == 0)
  }

  @Test func APP_001_bootstrapContinuesOnceRosettaIsInstalled() async throws {
    let h = Harness(wine: .ready, rosetta: false)
    defer { h.cleanUp() }
    await h.model.bootstrap()
    h.probe.setRosetta(true)
    await h.model.bootstrap()
    #expect(!h.model.isRosettaMissing)
    #expect(h.model.hasBootstrapped)
    #expect(h.model.lastError == nil)
    #expect(h.model.status == installed)
    #expect(h.probe.recoveries == [0])
  }

  @Test func APP_001_recoverRunsAfterWineIsReadyAndBeforeTheGameStatusRead() async throws {
    let h = Harness(wine: .ready)
    defer { h.cleanUp() }
    await h.model.bootstrap()
    #expect(h.probe.recoveries == [0], "recover must have run before the first game status read")
    #expect(h.fake.statusCalls == 1)
    #expect(h.model.hasBootstrapped)
  }

  @Test func APP_001_recoverRunsAfterAWinePreparationToo() async throws {
    let h = Harness(wine: missing)
    defer { h.cleanUp() }
    let (task, install) = try await h.bootstrapUntilPreparing()
    #expect(h.probe.recoveries.isEmpty, "no recovery while Wine is missing: there is no wineserver yet")
    h.wine.finish(install: install)
    await task.value
    #expect(h.probe.recoveries == [0])
    #expect(h.fake.statusCalls == 1)
  }

  @Test func APP_001_failedPreparationRecoversNothing() async throws {
    let h = Harness(wine: missing)
    defer { h.cleanUp() }
    let (task, install) = try await h.bootstrapUntilPreparing()
    h.wine.fail(install: install, throwing: WineInstallError.dxmtArchiveInvalid)
    await task.value
    #expect(h.probe.recoveries.isEmpty)
  }

  @Test func APP_001_recoverRunsOncePerRun() async throws {
    let h = Harness(wine: .ready)
    defer { h.cleanUp() }
    await h.model.bootstrap()
    h.wine.setStatus(missing)
    await h.model.refreshWine()
    try await h.model.prepareWine()
    let install = try await h.wine.nextInstall()
    h.wine.finish(install: install)
    await h.model.waitUntilIdle()
    await h.model.bootstrap()
    #expect(h.probe.recoveries == [0], "a later preparation must not replay the journal of a game that may run")
  }

  @Test func APP_001_launcherWithoutStartupStepsSkipsThem() async throws {
    let model = LauncherModel(client: FakeGameClient(status: installed), wine: FakeWinePreparer(status: .ready))
    await model.bootstrap()
    #expect(model.hasBootstrapped)
    #expect(!model.isRosettaMissing)
  }
}

@MainActor @Suite struct WIN_005_ReinstallTests {
  private func failLaunchWithReinstall(_ h: Harness) async throws {
    await h.model.bootstrap()
    try await h.model.launch()
    try await h.fake.nextLaunch()
    h.fake.failLaunch(GameClientError.wineReinstallRequired)
    await h.model.waitUntilIdle()
  }

  @Test func WIN_005_wineReinstallRequiredReturnsToPreparation() async throws {
    let h = Harness(wine: .ready)
    defer { h.cleanUp() }
    try await failLaunchWithReinstall(h)
    #expect(h.model.primaryAction == .prepareWine)
    #expect(h.model.wineStatus != .ready)
    await #expect(throws: LauncherError.wineNotReady) { try await h.model.launch() }

    // the disk still says "ready"; re-reading it must not undo the request
    await h.model.refreshWine()
    #expect(h.model.primaryAction == .prepareWine)

    try await h.model.prepareWine()
    let install = try await h.wine.nextInstall()
    #expect(h.wine.isReinstall(install: install), "ensureInstalled would return at once on a ready stamp")
    h.wine.finish(install: install)
    await h.model.waitUntilIdle()
    #expect(h.model.wineStatus == .ready)
    #expect(h.model.primaryAction == .launch)

    // satisfied: later refreshes follow the disk again
    h.wine.setStatus(missing)
    await h.model.refreshWine()
    h.wine.setStatus(.ready)
    await h.model.refreshWine()
    #expect(h.model.primaryAction == .launch)
  }

  @Test func WIN_005_aFailedReinstallStaysRequired() async throws {
    let h = Harness(wine: .ready)
    defer { h.cleanUp() }
    try await failLaunchWithReinstall(h)
    try await h.model.prepareWine()
    let first = try await h.wine.nextInstall()
    h.wine.fail(install: first, throwing: WineInstallError.dxmtArchiveInvalid)
    await h.model.waitUntilIdle()
    #expect(h.model.primaryAction == .prepareWine)

    try await h.model.resume()
    let second = try await h.wine.nextInstall()
    #expect(h.wine.isReinstall(install: second))
    h.wine.finish(install: second)
    await h.model.waitUntilIdle()
    #expect(h.model.primaryAction == .launch)
  }
}

extension WIN_005_ReinstallTests {
  @Test func WIN_005_aPausedReinstallStaysRequired() async throws {
    let h = Harness(wine: .ready)
    defer { h.cleanUp() }
    await h.model.bootstrap()
    try await h.model.launch()
    try await h.fake.nextLaunch()
    h.fake.failLaunch(GameClientError.wineReinstallRequired)
    await h.model.waitUntilIdle()
    try await h.model.prepareWine()
    _ = try await h.wine.nextInstall()
    await h.model.pause()
    #expect(h.model.primaryAction == .prepareWine)
    try await h.model.resume()
    let second = try await h.wine.nextInstall()
    #expect(h.wine.isReinstall(install: second))
    h.wine.finish(install: second)
    await h.model.waitUntilIdle()
  }
}

@MainActor @Suite struct WIN_005_RefreshWineTests {
  @Test func WIN_005_preparationReadsTheWineStatusOnceAfterAnyOutcome() async throws {
    for finish in [true, false] {
      let h = Harness(wine: missing)
      defer { h.cleanUp() }
      let (task, install) = try await h.bootstrapUntilPreparing()
      let before = h.wine.statusCalls
      if finish {
        h.wine.finish(install: install)
      } else {
        h.wine.fail(install: install, throwing: WineInstallError.dxmtArchiveInvalid)
      }
      await task.value
      #expect(h.wine.statusCalls - before == 1)
    }
  }
}
