import CZstd
import Foundation

/// Thin streaming wrapper over the vendored libzstd decompressor.
enum Zstd {
  /// Manifests are tens of MB at most; this stops a hostile frame from exhausting memory.
  static let defaultMaxOutputSize = 512 << 20

  /// Decompresses one complete zstd frame. Truncated or corrupt input throws.
  static func decompress(_ input: Data, maxOutputSize: Int = defaultMaxOutputSize) throws -> Data {
    guard !input.isEmpty, let stream = ZSTD_createDStream() else {
      throw SophonError.decompressionFailed
    }
    defer { ZSTD_freeDStream(stream) }

    var output = Data()
    var buffer = [UInt8](repeating: 0, count: ZSTD_DStreamOutSize())
    let finished: Bool = try input.withUnsafeBytes { raw in
      var inBuffer = ZSTD_inBuffer(src: raw.baseAddress, size: raw.count, pos: 0)
      while true {
        var result = 0
        let produced: Int = buffer.withUnsafeMutableBytes { out in
          var outBuffer = ZSTD_outBuffer(dst: out.baseAddress, size: out.count, pos: 0)
          result = ZSTD_decompressStream(stream, &outBuffer, &inBuffer)
          return outBuffer.pos
        }
        if ZSTD_isError(result) != 0 { throw SophonError.decompressionFailed }
        output.append(contentsOf: buffer[0..<produced])
        if output.count > maxOutputSize { throw SophonError.decompressionFailed }
        if result == 0 { return true }
        // Output buffer not full and input drained: the frame is incomplete.
        if produced < buffer.count && inBuffer.pos == inBuffer.size { return false }
      }
    }
    guard finished else { throw SophonError.decompressionFailed }
    return output
  }
}
