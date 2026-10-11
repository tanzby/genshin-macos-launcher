import Foundation
import SwiftProtobuf

/// One zstd-compressed piece of a file, as listed in a chunk manifest.
package struct SophonChunk: Sendable, Equatable {
  /// Chunk file name; also the URL suffix after `chunk_download.url_prefix`.
  package let id: String
  /// MD5 of the decompressed chunk.
  package let md5: String
  /// Where the decompressed bytes go in the target file.
  package let offset: UInt64
  package let compressedSize: UInt32
  package let uncompressedSize: UInt32
  package let xxhash: UInt64
  /// MD5 of the compressed bytes.
  package let compressedMD5: String
}

package struct SophonFile: Sendable, Equatable {
  /// Path relative to the game directory, `/` separated.
  package let path: String
  package let isDirectory: Bool
  package let size: Int64
  package let md5: String
  package let chunks: [SophonChunk]
}

/// A decoded chunk manifest.
package struct SophonManifest: Sendable, Equatable {
  package let files: [SophonFile]

  /// Total download size: the sum of every chunk's compressed size.
  package var totalCompressedSize: Int64 {
    files.reduce(Int64(0)) { sum, file in
      file.chunks.reduce(sum) { $0 + Int64($1.compressedSize) }
    }
  }

  init(files: [SophonFile]) { self.files = files }

  package init(zstdCompressed data: Data) throws {
    let raw = try Zstd.decompress(data)
    do {
      try self.init(raw: PbManifest(serializedBytes: raw))
    } catch let error as SophonError {
      throw error
    } catch {
      throw SophonError.invalidManifest("not a manifest")
    }
  }

  init(raw: PbManifest) throws {
    files = try raw.files.map { file in
      let isDirectory: Bool
      switch file.flags {
      case 0: isDirectory = false
      case 64: isDirectory = true
      default: throw SophonError.invalidManifest("unknown flags \(file.flags) for \(file.filename)")
      }
      return SophonFile(
        path: file.filename,
        isDirectory: isDirectory,
        size: try checkedSize(file.size, name: file.filename),
        md5: file.md5,
        chunks: file.chunks.map {
          SophonChunk(
            id: $0.chunkID, md5: $0.md5, offset: $0.offset, compressedSize: $0.compressedSize,
            uncompressedSize: $0.uncompressedSize, xxhash: $0.xxhash, compressedMD5: $0.compressedMd5)
        }
      )
    }
  }
}

/// One ldiff section that turns an old file into the new one.
package struct SophonPatch: Sendable, Equatable {
  /// ldiff file name; also the URL suffix after `diff_download.url_prefix`.
  package let patchID: String
  /// Size of the whole ldiff file (many patches are concatenated in it).
  package let patchSize: Int64
  /// This file's section inside the ldiff file.
  package let offset: Int64
  package let length: Int64
  package let originalPath: String
  package let originalSize: Int64
  package let originalMD5: String
  package let buildID: String
}

package struct SophonDiffFile: Sendable, Equatable {
  package let path: String
  package let size: Int64
  /// MD5 of the file after patching.
  package let md5: String
  /// Patches keyed by the old version they upgrade from. Empty means a new file.
  package let patches: [String: SophonPatch]
}

package struct SophonDeletedFile: Sendable, Equatable {
  package let path: String
  package let size: Int64
  package let md5: String
}

/// A decoded ldiff manifest.
package struct SophonDiffManifest: Sendable, Equatable {
  package let files: [SophonDiffFile]
  /// Files to delete, keyed by the old version being upgraded from.
  package let deletions: [String: [SophonDeletedFile]]

  init(files: [SophonDiffFile], deletions: [String: [SophonDeletedFile]]) {
    self.files = files
    self.deletions = deletions
  }

  package init(zstdCompressed data: Data) throws {
    let raw = try Zstd.decompress(data)
    do {
      try self.init(raw: PbDiffManifest(serializedBytes: raw))
    } catch let error as SophonError {
      throw error
    } catch {
      throw SophonError.invalidManifest("not a diff manifest")
    }
  }

  init(raw: PbDiffManifest) throws {
    files = try raw.files.map { file in
      var patches: [String: SophonPatch] = [:]
      for patch in file.patches {
        let info = patch.info
        patches[patch.key] = SophonPatch(
          patchID: info.patchID, patchSize: info.patchSize, offset: info.patchOffset,
          length: info.patchLength, originalPath: info.originalName, originalSize: info.originalSize,
          originalMD5: info.originalHash, buildID: info.buildID)
      }
      return SophonDiffFile(
        path: file.filename, size: try checkedSize(file.size, name: file.filename), md5: file.hash,
        patches: patches)
    }
    var deletions: [String: [SophonDeletedFile]] = [:]
    for group in raw.filesDelete {
      deletions[group.key, default: []].append(
        contentsOf: group.info.list.map {
          SophonDeletedFile(path: $0.filename, size: $0.size, md5: $0.hash)
        })
    }
    self.deletions = deletions
  }
}

/// The manifests declare sizes as `int32`; a negative value means the field overflowed.
private func checkedSize(_ size: Int32, name: String) throws -> Int64 {
  guard size >= 0 else { throw SophonError.invalidManifest("negative size for \(name)") }
  return Int64(size)
}
