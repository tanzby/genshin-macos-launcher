import Foundation

/// Checks a chunk manifest before the first request: hostile paths, chunk ids, sizes and aliases.
enum SophonManifestValidator {
  /// Checks every entry (paths, chunk ids and sizes, aliases) and returns the files to download.
  static func validate(_ files: [SophonFile], using ref: SophonManifestRef, into gameDirectory: URL) throws
    -> (chunkBase: String, targets: [(file: SophonFile, destination: URL)])
  {
    let chunkBase = try chunkBase(of: ref)
    var targets: [(file: SophonFile, destination: URL)] = []
    var seen: [String: String] = [:]  // standardised destination -> file MD5
    for file in files {
      let destination = try SophonPathPolicy.resolve(file.path, in: gameDirectory)
      if file.isDirectory { continue }
      // Every entry is checked, also a repeated path: only the first one is downloaded.
      for chunk in file.chunks {
        // A chunk id becomes a file name; it must not be able to leave the cache directory.
        guard SophonDownloaderLayout.isSafeName(chunk.id) else {
          throw SophonError.invalidManifest("unsafe chunk id for \(file.path)")
        }
        // Chunks are read and decoded whole; real ones are about 1 MiB, so anything big is hostile.
        guard chunk.compressedSize <= SophonDownloaderLayout.maxChunkSize,
          chunk.uncompressedSize <= SophonDownloaderLayout.maxChunkSize
        else { throw SophonError.invalidManifest("chunk \(chunk.id) is too large") }
        let (end, overflow) = chunk.offset.addingReportingOverflow(UInt64(chunk.uncompressedSize))
        guard !overflow, end <= UInt64(file.size) else {
          throw SophonError.invalidManifest("chunk \(chunk.id) exceeds the size of \(file.path)")
        }
      }
      // `a/b`, `a/./b` and `a//b` are one file. Equal entries collapse; conflicting ones are refused.
      // macOS volumes are case-insensitive by default, so `A.bin` and `a.bin` are one file too.
      let key = destination.standardizedFileURL.path.lowercased()
      if let existing = seen[key] {
        guard existing.caseInsensitiveCompare(file.md5) == .orderedSame else {
          throw SophonError.invalidManifest("conflicting entries for \(file.path)")
        }
      } else {
        seen[key] = file.md5
        targets.append((file, destination))
      }
    }
    // A file cannot also be a folder: `a` together with `a/b` can never both land on disk.
    let taken = Set(seen.keys)
    for key in taken {
      var ancestor = (key as NSString).deletingLastPathComponent
      while ancestor.count > 1 {
        if taken.contains(ancestor) { throw SophonError.invalidManifest("\(ancestor) is both a file and a folder") }
        ancestor = (ancestor as NSString).deletingLastPathComponent
      }
    }
    return (chunkBase, targets)
  }

  static func chunkBase(of ref: SophonManifestRef) throws -> String {
    try SophonDownloaderLayout.httpsBase(ref.chunkURLPrefix)
  }

  static func compressedSize(of file: SophonFile) -> Int64 {
    file.chunks.reduce(Int64(0)) { $0 + Int64($1.compressedSize) }
  }
}
