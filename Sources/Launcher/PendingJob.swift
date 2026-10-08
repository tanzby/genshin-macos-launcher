import Foundation

/// A game job that was paused or interrupted before finishing. Persisted at
/// `<game>/.yaagl-tmp/job.json` so the main button can offer "continue" after a restart.
public struct PendingJob: Codable, Sendable, Equatable {
  public var schemaVersion = 1
  public var kind: GameJob
  public var targetVersion: String?

  public init(kind: GameJob, targetVersion: String? = nil) {
    self.kind = kind
    self.targetVersion = targetVersion
  }
}

/// Reads and writes `job.json`. Unknown fields are ignored; an unreadable file counts as absent.
struct PendingJobStore: Sendable {
  static let directoryName = ".yaagl-tmp"
  static let fileName = "job.json"

  let gameDirectory: URL

  var fileURL: URL {
    gameDirectory.appending(path: Self.directoryName).appending(path: Self.fileName)
  }

  func load() -> PendingJob? {
    guard let data = try? Data(contentsOf: fileURL) else { return nil }
    return try? JSONDecoder().decode(PendingJob.self, from: data)
  }

  func save(_ job: PendingJob) throws {
    try FileManager.default.createDirectory(
      at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    try JSONEncoder().encode(job).write(to: fileURL, options: .atomic)
  }

  func clear() {
    try? FileManager.default.removeItem(at: fileURL)
  }
}
