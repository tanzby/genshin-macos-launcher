import Darwin
import Foundation

/// Removes `com.apple.quarantine` from files the user owns. `removexattr(2)` needs no
/// administrator rights, unlike the TS launcher's `sudo xattr`.
package enum Quarantine {
  private static let attribute = "com.apple.quarantine"

  package struct RemovalError: Error, Equatable {
    package var path: String
    package var errno: Int32
  }

  /// Walks `root` without following symlinks. A file without the attribute is fine.
  package static func remove(from root: URL, fileManager: FileManager = .default) throws {
    var info = stat()
    guard lstat(root.path, &info) == 0 else {
      throw RemovalError(path: root.path, errno: errno)
    }
    try removeAttribute(at: root)
    guard let walker = fileManager.enumerator(atPath: root.path) else { return }
    for case let relative as String in walker {
      try removeAttribute(at: root.appending(path: relative))
    }
  }

  private static func removeAttribute(at url: URL) throws {
    guard removexattr(url.path, attribute, XATTR_NOFOLLOW) != 0 else { return }
    let code = errno
    // ENOATTR: nothing to remove. ENOTSUP: filesystem without xattrs (e.g. some network shares).
    if code == ENOATTR || code == ENOTSUP { return }
    throw RemovalError(path: url.path, errno: code)
  }
}
