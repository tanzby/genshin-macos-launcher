import Foundation

// Every temporary file or directory a test makes lives under one root per test process, which is removed when the
// process exits. Tests therefore never clean up after themselves, and none can leak into the system temp dir.
// The root is symlink-resolved (/private/var/...), so paths match what the code under test resolves to.

private let root: URL = makeRoot()

private func makeRoot() -> URL {
  let url = FileManager.default.temporaryDirectory
    .appending(path: "yaagl-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
  try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
  atexit { removeRoot() }
  return url.resolvingSymlinksInPath()
}

private func removeRoot() { try? FileManager.default.removeItem(at: root) }

/// A unique path under the test root that does not exist yet; its parent does. `name` only helps reading failures.
public func temporaryURL(_ name: String = "tmp") -> URL {
  root.appending(path: "\(name)-\(UUID().uuidString)")
}

/// A new, empty directory under the test root.
public func makeTemporaryDirectory(_ name: String = "tmp") -> URL {
  let url = temporaryURL(name)
  try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
  return url
}
