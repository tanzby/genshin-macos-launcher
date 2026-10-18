import Foundation
import Testing
import TestSupport

@testable import Sophon

extension SophonEndpoints {
  /// The endpoints the recorded fixtures were taken from (Genshin Impact, CN). The real constants live in
  /// GenshinCN; its tests check them against the same values.
  static let recordedCN = SophonEndpoints(
    hypConnectBase: URL(string: "https://hyp-api.mihoyo.com/hyp/hyp-connect/api")!,
    downloaderBase: URL(string: "https://api-takumi.mihoyo.com/downloader/sophon_chunk/api")!,
    gameID: "1Z8W5NHUQb",
    launcherID: "jGHBHlcOq1")
}

enum Fixture {
  static func data(_ name: String, _ ext: String) throws -> Data {
    let url = try #require(
      Bundle.module.url(forResource: name, withExtension: ext, subdirectory: "Fixtures"))
    return try Data(contentsOf: url)
  }
}

/// Deterministic pseudo-random bytes. Different seeds give different content.
func syntheticBytes(seed: Int, count: Int) -> Data {
  var state = UInt64(truncatingIfNeeded: seed) &* 0x9E37_79B9_7F4A_7C15 | 1
  var bytes = [UInt8]()
  bytes.reserveCapacity(count)
  for _ in 0..<count {
    state ^= state << 13
    state ^= state >> 7
    state ^= state << 17
    bytes.append(UInt8(truncatingIfNeeded: state >> 24))
  }
  return Data(bytes)
}

/// Relative paths (and sizes) of every regular file below `directory`.
func regularFiles(in directory: URL) -> [String: Int] {
  var result: [String: Int] = [:]
  let base = directory.standardizedFileURL.path
  guard
    let walker = FileManager.default.enumerator(
      at: directory, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey])
  else { return result }
  for case let url as URL in walker {
    let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
    guard values?.isRegularFile == true else { continue }
    result[String(url.standardizedFileURL.path.dropFirst(base.count + 1))] = values?.fileSize ?? 0
  }
  return result
}

/// `N` of a single `Range: bytes=N-` header.
func rangeStart(of request: URLRequest) -> Int? {
  guard let header = request.value(forHTTPHeaderField: "Range"), header.hasPrefix("bytes="),
    header.hasSuffix("-"), !header.dropFirst(6).dropLast().contains(",")
  else { return nil }
  return Int(header.dropFirst(6).dropLast())
}

/// What a healthy server answers to `Range: bytes=start-` on `blob`: the tail (206), or 416 past the end.
func rangedReply(blob: Data, start: Int, delay: Duration = .zero) -> StubReply {
  if start >= blob.count {
    return .response(status: 416, body: Data(), headers: ["Content-Range": "bytes */\(blob.count)"])
  }
  return .response(
    status: 206, body: Data(blob[start...]),
    headers: ["Content-Range": "bytes \(start)-\(blob.count - 1)/\(blob.count)"], delay: delay)
}
