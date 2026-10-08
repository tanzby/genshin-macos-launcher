import CryptoKit
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
  private let configuration: URLSessionConfiguration

  public init(configuration: URLSessionConfiguration = .default) {
    self.configuration = configuration
  }

  public func download(
    from url: URL,
    to destination: URL,
    sha256: String?,
    progress: @escaping @Sendable (DownloadProgress) -> Void
  ) async throws {
    let observer = ProgressObserver(progress)
    let session = URLSession(configuration: configuration, delegate: nil, delegateQueue: nil)
    defer { session.finishTasksAndInvalidate() }

    let (temporary, response) = try await session.download(from: url, delegate: observer)
    defer { try? FileManager.default.removeItem(at: temporary) }

    if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
      throw DownloadError.httpStatus(http.statusCode)
    }
    if let expected = sha256?.lowercased() {
      let actual = try Self.sha256Hex(of: temporary)
      guard actual == expected else {
        throw DownloadError.checksumMismatch(expected: expected, actual: actual)
      }
    }

    let fileManager = FileManager.default
    try fileManager.createDirectory(
      at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
    if fileManager.fileExists(atPath: destination.path) {
      _ = try fileManager.replaceItemAt(destination, withItemAt: temporary)
    } else {
      try fileManager.moveItem(at: temporary, to: destination)
    }
    let size = (try? fileManager.attributesOfItem(atPath: destination.path)[.size] as? Int64) ?? nil
    if let size {
      let announced = response.expectedContentLength
      progress(DownloadProgress(completed: size, total: announced > 0 ? announced : -1))
    }
  }

  /// Streaming SHA-256 so a 450 MB archive is never held in memory.
  public static func sha256Hex(of file: URL) throws -> String {
    let handle = try FileHandle(forReadingFrom: file)
    defer { try? handle.close() }
    var hasher = SHA256()
    while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
      hasher.update(data: chunk)
    }
    return hasher.finalize().map { String(format: "%02x", $0) }.joined()
  }
}

private final class ProgressObserver: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
  private let report: @Sendable (DownloadProgress) -> Void

  init(_ report: @escaping @Sendable (DownloadProgress) -> Void) {
    self.report = report
  }

  func urlSession(
    _ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64
  ) {
    report(
      DownloadProgress(
        completed: totalBytesWritten,
        total: totalBytesExpectedToWrite > 0 ? totalBytesExpectedToWrite : -1))
  }

  func urlSession(
    _ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL
  ) {}
}
