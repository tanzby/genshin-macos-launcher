import Foundation
import Platform
import os

private let log = Logger(subsystem: "io.github.tanzby.genshin-launcher", category: "wine")

/// Launch Mutations of a recipe (move-aside files, prefix copies, registry edits) and the journal that
/// lets `restore()` put everything back, also after a crash (ADR 0002).
struct LaunchMutations: Sendable {
  let commands: WinePrefixCommands

  private var layout: WineLayout { commands.layout }

  /// Journals the originals, then applies the recipe's mutations and lets the registry settle (LCH-009).
  func apply(_ recipe: LaunchRecipe) async throws {
    // Items a previous restore could not finish stay in the journal with their real originals; the
    // values on disk now are not the player's.
    var journal = readJournal() ?? LaunchJournal()
    for path in recipe.moveAside.map(\.path) where !journal.movedAside.contains(path) {
      journal.movedAside.append(path)
    }
    for edit in recipe.registry where edit.restoresOnExit {
      if journal.registry.contains(where: { $0.key == edit.key && $0.name == edit.name }) { continue }
      journal.registry.append(
        .init(key: edit.key, name: edit.name, original: try await commands.query(key: edit.key, name: edit.name)))
    }
    try writeJournal(journal)

    for file in recipe.moveAside { try moveAside(file) }
    try applyPrefixCopies(recipe.prefixCopies)
    for edit in recipe.registry { try await apply(edit) }
    _ = try? await commands.wineserver("-w")
  }

  private func moveAside(_ file: URL) throws {
    let fileManager = FileManager.default
    let backup = URL(filePath: file.path + ".bak")
    guard fileManager.fileExists(atPath: file.path) else { return }  // already aside, or never there
    // The live file wins over a stale .bak (a repair re-downloads the original).
    if fileManager.fileExists(atPath: backup.path) { try fileManager.removeItem(at: backup) }
    try fileManager.moveItem(at: file, to: backup)
  }

  private func applyPrefixCopies(_ copies: [PrefixCopy]) throws {
    let fileManager = FileManager.default
    for copy in copies {
      let destination = layout.prefixWindows.appending(path: copy.destination, directoryHint: .notDirectory)
      if fileManager.fileExists(atPath: destination.path),
        fileManager.contentsEqual(atPath: copy.source.path, andPath: destination.path)
      {
        continue
      }
      try fileManager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
      if fileManager.fileExists(atPath: destination.path) { try fileManager.removeItem(at: destination) }
      try fileManager.copyItem(at: copy.source, to: destination)
    }
  }

  private func writeJournal(_ journal: LaunchJournal) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try encoder.encode(journal).write(to: layout.launchJournal, options: .atomic)
  }

  private func readJournal() -> LaunchJournal? {
    guard let data = try? Data(contentsOf: layout.launchJournal) else { return nil }
    if let journal = try? JSONDecoder().decode(LaunchJournal.self, from: data) { return journal }
    log.error("unreadable launch journal, set aside for inspection")
    let aside = layout.launchJournal.deletingLastPathComponent().appending(path: "launch-journal.corrupt.json")
    try? FileManager.default.removeItem(at: aside)
    try? FileManager.default.moveItem(at: layout.launchJournal, to: aside)
    return nil
  }

  /// Puts everything the journal records back, item by item against the disk's actual state. Items that
  /// fail stay in the journal for the next `recover()`; it is deleted only when nothing is left.
  func restore() async {
    let fileManager = FileManager.default
    guard let journal = readJournal() else { return }
    var remaining = LaunchJournal()
    for path in journal.movedAside {
      let backup = path + ".bak"
      guard fileManager.fileExists(atPath: backup) else { continue }
      do {
        if fileManager.fileExists(atPath: path) {
          try fileManager.removeItem(atPath: backup)  // the live file wins
        } else {
          try fileManager.moveItem(atPath: backup, toPath: path)
        }
      } catch {
        log.error("could not restore \(path, privacy: .public): \(String(describing: error), privacy: .public)")
        remaining.movedAside.append(path)
      }
    }
    for entry in journal.registry {
      let restored =
        if let original = entry.original {
          (try? await commands.set(entry.key, entry.name, original))?.exitCode == 0
        } else {
          // Deleting a value that is not there exits non-zero; only a launch failure counts as not restored.
          (try? await commands.delete(entry.key, entry.name)) != nil
        }
      if !restored { remaining.registry.append(entry) }
    }
    if !journal.registry.isEmpty { _ = try? await commands.wineserver("-w") }
    if remaining.movedAside.isEmpty && remaining.registry.isEmpty {
      try? fileManager.removeItem(at: layout.launchJournal)
    } else {
      try? writeJournal(remaining)
    }
  }

  private func apply(_ edit: RegistryEdit) async throws {
    switch edit.action {
    case .set(let value):
      let result = try await commands.set(edit.key, edit.name, value)
      guard result.exitCode == 0 else { throw LaunchError.registryWriteFailed(key: edit.key, name: edit.name) }
    case .delete:
      _ = try await commands.delete(edit.key, edit.name)  // deleting a value that is not there exits non-zero and is fine
    }
  }
}

enum LaunchError: Error, Equatable {
  case registryWriteFailed(key: String, name: String)
}
