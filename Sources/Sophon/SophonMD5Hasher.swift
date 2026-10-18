import CryptoKit
import Foundation

enum MD5Hasher {
  static func hex(of data: Data) -> String {
    Insecure.MD5.hash(data: data).hexString
  }

  /// Streams the file in 1 MiB steps, checking for cancellation between steps.
  static func hex(ofFileAt url: URL, cancelled: CancelFlag) throws -> String {
    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }
    var hasher = Insecure.MD5()
    while let block = try handle.read(upToCount: 1 << 20), !block.isEmpty {
      if cancelled.isSet { throw CancellationError() }
      hasher.update(data: block)
    }
    return hasher.finalize().hexString
  }
}

extension MD5Hasher {
  /// Size and MD5 both match. A missing file does not match.
  static func matches(_ url: URL, size: Int64, md5: String, cancelled: CancelFlag) throws -> Bool {
    guard url.fileSize == size else { return false }
    return try hex(ofFileAt: url, cancelled: cancelled).isSameDigest(as: md5)
  }
}

extension String {
  /// Hex digests compare without regard to case.
  func isSameDigest(as other: String) -> Bool { caseInsensitiveCompare(other) == .orderedSame }
}

extension Digest {
  var hexString: String { map { String(format: "%02x", $0) }.joined() }
}
