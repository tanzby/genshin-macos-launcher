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
  /// The installed version is not one the patch build upgrades from, so ldiff cannot be used.
  case versionNotPatchable(String)
  /// Applying an ldiff patch did not produce the file the manifest describes.
  case patchFailed(path: String)
  /// After an update a file is missing, has the wrong size, or an old file is still there (UPG-011).
  case verificationFailed(path: String)
  /// The game directory is not a recognisable China-release install (UPG-005).
  case brokenInstallation
  /// A fresh install needs an empty directory, or one left by an interrupted install (INS-005).
  case installDirectoryNotEmpty
  /// `config.ini` is missing or its `game_version` line is not exactly one (INS-006, UPG-011).
  case invalidConfig
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
    case .versionNotPatchable(let version): "Version \(version) cannot be updated with ldiff patches"
    case .patchFailed(let path): "Could not patch \(path)"
    case .verificationFailed(let path): "File is missing, has the wrong size, or should be gone after the update: \(path)"
    case .brokenInstallation: "Broken script or corrupted game installation"
    case .installDirectoryNotEmpty: "The specified install path is not empty"
    case .invalidConfig: "Invalid config.ini format"
    }
  }
}
