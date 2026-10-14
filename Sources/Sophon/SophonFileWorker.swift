import Foundation

/// Downloads the chunks of one file into the cache, decompresses them into an assembly file and
/// moves the verified result into place. Paths in the temp directory come from a digest of the
/// relative path, so equal basenames in different folders never collide.
struct FileWorker: Sendable {
  let session: URLSession
  let chunkBase: String
  let chunkSuffix: String
  let gameDirectory: URL
  let tempDirectory: URL

  var chunkRoot: URL { SophonDownloaderLayout.chunkRoot(in: tempDirectory) }
  var assemblyRoot: URL { tempDirectory.appending(path: "assembling", directoryHint: .isDirectory) }

  func fetch(_ file: SophonFile, to destination: URL, reporter: ChunkProgress) async throws {
    let key = SophonDownloaderLayout.fileKey(for: file.path)
    let chunkDirectory = SophonDownloaderLayout.chunkDirectory(for: file.path, in: tempDirectory)
    let assembly = assemblyRoot.appending(path: key + ".part")
    let fileManager = FileManager.default
    try fileManager.createDirectory(at: chunkDirectory, withIntermediateDirectories: true)
    try fileManager.createDirectory(at: assemblyRoot, withIntermediateDirectories: true)
    try? fileManager.removeItem(at: assembly)
    guard fileManager.createFile(atPath: assembly.path, contents: nil) else {
      throw CocoaError(.fileWriteUnknown)
    }
    let handle = try FileHandle(forWritingTo: assembly)
    defer { try? handle.close() }
    try handle.truncate(atOffset: UInt64(file.size))

    for chunk in file.chunks {
      try Task.checkCancellation()
      let cached = chunkDirectory.appending(path: chunk.id)
      let compressed = try await downloadChunk(chunk, to: cached, reporter: reporter)
      // zstd and MD5 are blocking C-speed work: keep them off the cooperative pool (ADR 0002).
      let decoded = await Offload.run { _ in
        (try? Zstd.decompress(compressed, maxOutputSize: Int(SophonDownloaderLayout.maxChunkSize))).map { ($0, MD5Hasher.hex(of: $0)) }
      }
      // A chunk that fails a check is dropped from the cache and from the progress, so the retry fetches it again.
      func reject(_ error: SophonError) -> SophonError {
        try? fileManager.removeItem(at: cached)
        reporter.set(chunk.id, 0)
        return error
      }
      guard let (plain, plainMD5) = decoded else { throw reject(.checksumMismatch(path: file.path)) }
      guard plain.count == Int(chunk.uncompressedSize) else {
        throw reject(.invalidManifest("chunk \(chunk.id) does not hold \(chunk.uncompressedSize) bytes"))
      }
      guard plainMD5.caseInsensitiveCompare(chunk.md5) == .orderedSame else {
        throw reject(.checksumMismatch(path: file.path))
      }
      try handle.seek(toOffset: chunk.offset)
      try handle.write(contentsOf: plain)
    }
    try handle.synchronize()
    try handle.close()

    let assembledMD5 = try await Offload.run { try MD5Hasher.hex(ofFileAt: assembly, cancelled: $0) }
    guard assembledMD5.caseInsensitiveCompare(file.md5) == .orderedSame else {
      try? fileManager.removeItem(at: assembly)
      throw SophonError.checksumMismatch(path: file.path)
    }
    // Re-check right before the move: a symlink may have appeared since validation.
    let safe = try SophonPathPolicy.resolve(file.path, in: gameDirectory)
    try fileManager.createDirectory(at: safe.deletingLastPathComponent(), withIntermediateDirectories: true)
    _ = try SophonPathPolicy.resolve(file.path, in: gameDirectory)
    if fileManager.fileExists(atPath: safe.path) {
      _ = try fileManager.replaceItemAt(safe, withItemAt: assembly)
    } else {
      try fileManager.moveItem(at: assembly, to: safe)
    }
    try? fileManager.removeItem(at: chunkDirectory)
  }

  /// Makes `cached` hold the complete compressed chunk, resuming with `Range` when part of it is there.
  private func downloadChunk(_ chunk: SophonChunk, to cached: URL, reporter: ChunkProgress) async throws -> Data {
    try await ResourceFetcher(session: session).fetch(
      name: chunk.id, url: try SophonDownloaderLayout.resourceURL(base: chunkBase, name: chunk.id, suffix: chunkSuffix),
      expected: Int64(chunk.compressedSize), to: cached, reporter: reporter)
    return try Data(contentsOf: cached)
  }
}
