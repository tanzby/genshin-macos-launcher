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

extension Digest {
  var hexString: String { map { String(format: "%02x", $0) }.joined() }
}
