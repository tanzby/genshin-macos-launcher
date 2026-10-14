import CryptoKit
import Foundation

/// Downloads the chunks of one file into the cache, decompresses them into an assembly file and
/// moves the verified result into place. Paths in the temp directory come from a digest of the
/// relative path, so equal basenames in different folders never collide.
struct FileWorker: Sendable {
  let session: URLSession
  let chunkBase: String
  let chunkSuffix: String
  let paths: SophonPathPolicy
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

    let decoder = try Zstd.Decoder()
    // The whole-file MD5, fed chunk by chunk while the chunks follow each other in offset order without a gap.
    // nil once they do not: the assembled file is then read back to hash it.
    var running: Insecure.MD5? = Insecure.MD5()
    var end: UInt64 = 0
    for chunk in file.chunks {
      try Task.checkCancellation()
      let cached = chunkDirectory.appending(path: chunk.id)
      let compressed = try await downloadChunk(chunk, to: cached, reporter: reporter)
      let inOrder = chunk.offset == end ? running : nil
      // zstd and MD5 are blocking C-speed work: keep them off the cooperative pool (ADR 0002).
      let decoded = await Offload.run { _ -> DecodedChunk in
        do {
          let plain = try decoder.decompress(compressed, size: Int(chunk.uncompressedSize))
          var hasher = inOrder
          hasher?.update(data: plain)
          return .decoded(plain, md5: MD5Hasher.hex(of: plain), running: hasher)
        } catch is Zstd.WrongSize {
          return .wrongSize
        } catch {
          return .corrupt
        }
      }
      // A chunk that fails a check is dropped from the cache and from the progress, so the retry fetches it again.
      func reject(_ error: SophonError) -> SophonError {
        try? fileManager.removeItem(at: cached)
        reporter.set(chunk.id, 0)
        return error
      }
      switch decoded {
      case .corrupt:
        throw reject(.checksumMismatch(path: file.path))
      case .wrongSize:
        throw reject(.invalidManifest("chunk \(chunk.id) does not hold \(chunk.uncompressedSize) bytes"))
      case .decoded(let plain, let plainMD5, let hasher):
        guard plainMD5.caseInsensitiveCompare(chunk.md5) == .orderedSame else {
          throw reject(.checksumMismatch(path: file.path))
        }
        try handle.seek(toOffset: chunk.offset)
        try handle.write(contentsOf: plain)
        running = hasher
        end = chunk.offset + UInt64(chunk.uncompressedSize)
      }
    }
    try handle.synchronize()
    try handle.close()

    let assembledMD5: String
    if let running, end == UInt64(file.size) {
      assembledMD5 = running.finalize().hexString
    } else {
      assembledMD5 = try await Offload.run { try MD5Hasher.hex(ofFileAt: assembly, cancelled: $0) }
    }
    guard assembledMD5.caseInsensitiveCompare(file.md5) == .orderedSame else {
      try? fileManager.removeItem(at: assembly)
      throw SophonError.checksumMismatch(path: file.path)
    }
    // Re-check right before the move: a symlink may have appeared since validation.
    let safe = try paths.resolve(file.path)
    try fileManager.createDirectory(at: safe.deletingLastPathComponent(), withIntermediateDirectories: true)
    // And after it: the folders just created must not have been swapped for a symlink either.
    _ = try paths.resolve(file.path)
    if fileManager.fileExists(atPath: safe.path) {
      _ = try fileManager.replaceItemAt(safe, withItemAt: assembly)
    } else {
      try fileManager.moveItem(at: assembly, to: safe)
    }
    try? fileManager.removeItem(at: chunkDirectory)
  }

  private enum DecodedChunk: Sendable {
    case decoded(Data, md5: String, running: Insecure.MD5?)
    case wrongSize
    case corrupt
  }

  /// Makes `cached` hold the complete compressed chunk, resuming with `Range` when part of it is there.
  private func downloadChunk(_ chunk: SophonChunk, to cached: URL, reporter: ChunkProgress) async throws -> Data {
    try await ResourceFetcher(session: session).fetch(
      name: chunk.id, url: try SophonDownloaderLayout.resourceURL(base: chunkBase, name: chunk.id, suffix: chunkSuffix),
      expected: Int64(chunk.compressedSize), to: cached, reporter: reporter)
    return try Data(contentsOf: cached)
  }
}
