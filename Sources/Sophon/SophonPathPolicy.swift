import Foundation

/// INS-011: manifest paths must stay inside the game directory. Build one per job: the root's real path is
/// resolved once, not for every file.
struct SophonPathPolicy: Sendable {
  let root: URL
  private let realRoot: String

  init(root: URL) {
    self.root = root
    realRoot = root.resolvingSymlinksInPath().standardizedFileURL.path
  }

  /// The absolute destination of `path` under `root`, or `SophonError.unsafePath`.
  func resolve(_ path: String) throws -> URL {
    // Same rule as the TS launcher (no `..`, no leading `/`) plus the ways to say the same thing.
    guard !path.isEmpty, !path.hasPrefix("/"), !path.contains(".."), !path.contains("\\"),
      !path.contains("\0")
    else { throw SophonError.unsafePath(path) }
    let destination = root.appending(path: path)
    let realParent = destination.deletingLastPathComponent().resolvingSymlinksInPath().standardizedFileURL.path
    guard realParent == realRoot || realParent.hasPrefix(realRoot + "/") else {
      throw SophonError.unsafePath(path)
    }
    return destination
  }
}

extension URL {
  /// Size in bytes, or nil when nothing is there (a dangling link counts as nothing).
  var fileSize: Int64? {
    ((try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? NSNumber)?.int64Value
  }
}
