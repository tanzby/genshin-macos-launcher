import Foundation

/// What a launch changed and how to put it back. Written before the first change and deleted after the
/// restore, so its presence on disk means the launcher died mid-game (ADR 0002 "崩溃恢复").
struct LaunchJournal: Codable, Equatable {
  static let currentSchemaVersion = 1

  var schemaVersion = currentSchemaVersion
  /// Original paths of the files renamed to `<path>.bak`.
  var movedAside: [String] = []
  var registry: [Entry] = []

  struct Entry: Codable, Equatable {
    var key: String
    var name: String
    /// `nil`: the value did not exist, so the restore deletes it.
    var original: RegistryValue?
  }
}
