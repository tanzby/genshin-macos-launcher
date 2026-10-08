import Foundation

public struct DownloadProgress: Sendable, Equatable {
  public var completed: Int64
  /// -1 when the server did not announce a length.
  public var total: Int64

  public init(completed: Int64, total: Int64) {
    self.completed = completed
    self.total = total
  }
}

public enum DownloadError: Error, Equatable {
  case httpStatus(Int)
  case checksumMismatch(expected: String, actual: String)
}

/// Port for fetching one file. `Downloader` is the URLSession implementation; tests stub it.
public protocol Downloading: Sendable {
  /// Downloads `url` to `destination` (replacing any existing file, creating parent directories).
  /// With `sha256` set, a mismatch deletes the download and throws; `destination` is untouched.
  func download(
    from url: URL,
    to destination: URL,
    sha256: String?,
    progress: @escaping @Sendable (DownloadProgress) -> Void
  ) async throws
}

public struct Downloader: Downloading {
  public init(configuration: URLSessionConfiguration = .default) {}

  public func download(
    from url: URL,
    to destination: URL,
    sha256: String?,
    progress: @escaping @Sendable (DownloadProgress) -> Void
  ) async throws {
    throw CocoaError(.featureUnsupported)
  }
}
