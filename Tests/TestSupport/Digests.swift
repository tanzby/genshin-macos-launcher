import CryptoKit
import Foundation

/// Lowercase hex SHA-256 of `data`, the form `Downloader` takes as its checksum.
public func sha256Hex(_ data: Data) -> String {
  SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}
