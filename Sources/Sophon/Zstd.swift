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

  /// The frame decompressed fine but does not hold the declared number of bytes.
  struct WrongSize: Error {}

  /// One decompression context reused across frames. Calls must not overlap: one file's chunks go through it in turn.
  final class Decoder: @unchecked Sendable {
    private let context: OpaquePointer

    init() throws {
      guard let context = ZSTD_createDCtx() else { throw SophonError.decompressionFailed }
      self.context = context
    }

    deinit { ZSTD_freeDCtx(context) }

    /// Decompresses one complete frame straight into a buffer of `size` bytes. Throws `WrongSize` when the frame
    /// holds more or fewer bytes, `SophonError.decompressionFailed` when it is corrupt or truncated.
    func decompress(_ input: Data, size: Int) throws -> Data {
      guard !input.isEmpty else { throw SophonError.decompressionFailed }
      var output = Data(count: size)
      let result = output.withUnsafeMutableBytes { out in
        input.withUnsafeBytes { raw in
          ZSTD_decompressDCtx(context, out.baseAddress, out.count, raw.baseAddress, raw.count)
        }
      }
      if ZSTD_isError(result) != 0 {
        if ZSTD_getErrorCode(result) == ZSTD_error_dstSize_tooSmall { throw WrongSize() }
        throw SophonError.decompressionFailed
      }
      guard result == size else { throw WrongSize() }
      return output
    }
  }
}
