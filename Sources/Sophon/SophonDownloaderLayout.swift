import Foundation

enum SophonDownloaderLayout {
  /// Temp-directory name of one file: a digest of the whole relative path, never the basename.
  static func fileKey(for path: String) -> String { MD5Hasher.hex(of: Data(path.utf8)) }

  /// Where downloaded chunks wait: `<temp>/chunks/`, one folder per file.
  static func chunkRoot(in tempDirectory: URL) -> URL {
    tempDirectory.appending(path: "chunks", directoryHint: .isDirectory)
  }

  static func chunkDirectory(for path: String, in tempDirectory: URL) -> URL {
    chunkRoot(in: tempDirectory).appending(path: fileKey(for: path), directoryHint: .isDirectory)
  }

  static let maxChunkSize: UInt32 = 64 << 20

  /// REP-003: checking is disk and CPU bound, so it uses about as many workers as there are cores.
  static var verifyWorkers: Int { max(2, ProcessInfo.processInfo.activeProcessorCount - 4) }

  /// A manifest's URL prefix without trailing slashes; it must be an https URL.
  static func httpsBase(_ prefix: String?) throws -> String {
    guard var prefix else { throw SophonError.malformedResponse }
    while prefix.hasSuffix("/") { prefix.removeLast() }
    guard URL(string: prefix)?.scheme == "https" else { throw SophonError.malformedResponse }
    return prefix
  }

  /// `<base>/<name><suffix>` with the name percent-encoded; `base` has no trailing slash.
  static func resourceURL(base: String, name: String, suffix: String) throws -> URL {
    guard let id = name.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
      let url = URL(string: "\(base)/\(id)\(suffix)")
    else { throw SophonError.malformedResponse }
    return url
  }

  static func isSafeName(_ name: String) -> Bool {
    !name.isEmpty && !name.contains("/") && !name.contains("\\") && !name.contains("..")
      && !name.contains("\0")
  }
}
