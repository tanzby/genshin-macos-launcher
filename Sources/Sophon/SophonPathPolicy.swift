import Foundation

/// INS-011: manifest paths must stay inside the game directory.
enum SophonPathPolicy {
  /// The absolute destination of `path` under `root`, or `SophonError.unsafePath`.
  static func resolve(_ path: String, in root: URL) throws -> URL {
    // Same rule as the TS launcher (no `..`, no leading `/`) plus the ways to say the same thing.
    guard !path.isEmpty, !path.hasPrefix("/"), !path.contains(".."), !path.contains("\\"),
      !path.contains("\0")
    else { throw SophonError.unsafePath(path) }
    let destination = root.appending(path: path)
    let realRoot = root.resolvingSymlinksInPath().standardizedFileURL.path
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
