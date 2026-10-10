import Foundation
import os

private let log = Logger(subsystem: "io.github.tanzby.yaagl", category: "genshin")

/// The files the launch moves aside as `<file>.bak` (LCH-014). A crash can leave them aside; this puts them back
/// before anything verifies, patches or launches the game.
enum GenshinGameFiles {
  /// A `.bak` with no live file is the original: move it back. A `.bak` next to a live file is stale (a repair
  /// downloaded the original again): the live file wins and the backup goes. Returns the files that were fixed.
  @discardableResult
  static func healBackups(in gameDirectory: URL) -> [String] {
    let fileManager = FileManager.default
    var healed: [String] = []
    for path in GenshinLaunchRecipe.movedAside {
      let live = gameDirectory.appending(path: path)
      let backup = gameDirectory.appending(path: path + ".bak")
      guard fileManager.fileExists(atPath: backup.path) else { continue }
      do {
        if fileManager.fileExists(atPath: live.path) {
          try fileManager.removeItem(at: backup)
        } else {
          try fileManager.moveItem(at: backup, to: live)
        }
        healed.append(path)
      } catch {
        log.error("could not heal \(path, privacy: .public): \(String(describing: error), privacy: .public)")
      }
    }
    return healed
  }
}
