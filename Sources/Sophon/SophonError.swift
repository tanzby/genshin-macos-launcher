import Foundation

/// Why a Sophon request or parse failed. Never carries a URL or a password.
public enum SophonError: Error, Equatable, Sendable {
  /// The server answered with something other than 200.
  case http(status: Int)
  /// The request never completed (`URLError.Code.rawValue`).
  case transport(code: Int)
  /// `retcode` was not 0.
  case api(retcode: Int, message: String)
  /// The body was not the JSON shape we expect.
  case malformedResponse
  case noMatchingCategory(String)
  case ambiguousCategory(String)
  case decompressionFailed
  case invalidManifest(String)
  /// A manifest path is absolute or escapes the game directory (INS-011).
  case unsafePath(String)
  /// A decompressed chunk or an assembled file did not match its manifest digest or size.
  case checksumMismatch(path: String)
}

extension SophonError: LocalizedError {
  public var errorDescription: String? {
    switch self {
    case .http(let status): "Sophon server answered HTTP \(status)"
    case .transport(let code): "Sophon request failed (network error \(code))"
    case .api(let retcode, let message): "Sophon API error \(retcode): \(message)"
    case .malformedResponse: "Sophon response could not be read"
    case .noMatchingCategory(let name): "No Sophon category matches \(name)"
    case .ambiguousCategory(let name): "More than one Sophon category matches \(name)"
    case .decompressionFailed: "Sophon data could not be decompressed"
    case .invalidManifest(let reason): "Invalid Sophon manifest: \(reason)"
    case .unsafePath(let path): "Sophon manifest path escapes the game directory: \(path)"
    case .checksumMismatch(let path): "File is corrupt after download: \(path)"
    }
  }
}
