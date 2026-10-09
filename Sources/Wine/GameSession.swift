import Foundation
import Platform

/// Executes a `LaunchRecipe`: launch mutations, run, wait, restore.
public struct GameSession: Sendable {
  /// Bundle id of `YaaglGame.app` (UPD-017). `codesign -i` must use the same id.
  public static let gameHostBundleIdentifier = "io.github.tanzby.yaagl.game"

  let layout: WineLayout
  let runner: any ProcessRunning
  let processes: any ProcessTable
  let launchServices: any LaunchServicesRegistering
  let helpers: GameHostHelpers?
  let timing: LaunchTiming

  public init(
    layout: WineLayout,
    runner: any ProcessRunning,
    processes: any ProcessTable = SystemProcessTable(),
    launchServices: any LaunchServicesRegistering,
    helpers: GameHostHelpers?,
    timing: LaunchTiming = LaunchTiming()
  ) {
    self.layout = layout
    self.runner = runner
    self.processes = processes
    self.launchServices = launchServices
    self.helpers = helpers
    self.timing = timing
  }

  /// Runs the game and restores everything afterwards. Never throws: the outcome is the result.
  public func launch(_ recipe: LaunchRecipe) async -> LaunchResult {
    .failedToLaunch(reason: "not implemented")
  }

  /// Kills what is left of the prefix and replays the journal of a crashed launch (ADR 0002).
  public func recover() async {}
}
