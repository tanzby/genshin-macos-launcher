import Foundation

// Every temporary file or directory a test makes lives under one root per test process, which is removed when the
// process exits. Tests therefore never clean up after themselves. A process that crashes skips `atexit`; the next
// test process removes such leftovers. The root is symlink-resolved (/private/var/...), so paths match what the code
// under test resolves to.

private let rootPrefix = "genshin-launcher-tests-"
private let root: URL = makeRoot()

private func makeRoot() -> URL {
  let temp = FileManager.default.temporaryDirectory
  removeRootsOfExitedProcesses(in: temp)
  let url = temp.appending(path: "\(rootPrefix)\(getpid())-\(UUID().uuidString)", directoryHint: .isDirectory)
  try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
  atexit { try? FileManager.default.removeItem(at: root) }
  return url.resolvingSymlinksInPath()
}

/// Roots are named `genshin-launcher-tests-<pid>-<uuid>`; one whose process is gone was left by a crash.
private func removeRootsOfExitedProcesses(in temp: URL) {
  let names = (try? FileManager.default.contentsOfDirectory(atPath: temp.path)) ?? []
  for name in names where name.hasPrefix(rootPrefix) {
    guard let pid = Int32(name.dropFirst(rootPrefix.count).prefix { $0 != "-" }) else { continue }
    if kill(pid, 0) != 0 && errno == ESRCH { try? FileManager.default.removeItem(at: temp.appending(path: name)) }
  }
}

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
