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

/// URLSession implementation. Bytes stream into `<destination>.part`, which survives errors and
/// cancellation; with a `sha256` the next call resumes it with a `Range` request (WIN-007).
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
    let fileManager = FileManager.default
    try fileManager.createDirectory(
      at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
    let expected = sha256?.lowercased()
    let partial = URL(filePath: destination.path + ".part")

    // A finished archive from an earlier, interrupted install is reused instead of fetched again.
    if let expected, fileManager.fileExists(atPath: destination.path),
      (try? Self.sha256Hex(of: destination)) == expected
    {
      let size = Self.fileSize(destination)
      progress(DownloadProgress(completed: size, total: size))
      return
    }

    // Only a download that can be verified is resumed; without a checksum a stale partial is dropped.
    var mayResume = expected != nil
    var total: Int64 = -1
    while true {
      if !mayResume { try? fileManager.removeItem(at: partial) }
      let offset = mayResume ? Self.fileSize(partial) : 0
      do {
        total = try await fetch(from: url, into: partial, offset: offset, progress: progress)
      } catch DownloadRestart.fromScratch where offset > 0 {
        mayResume = false
        continue
      }
      if let expected {
        let actual = try Self.sha256Hex(of: partial)
        guard actual == expected else {
          try? fileManager.removeItem(at: partial)
          if offset > 0 {  // the partial file was stale or damaged: one clean attempt
            mayResume = false
            continue
          }
          throw DownloadError.checksumMismatch(expected: expected, actual: actual)
        }
      }
      break
    }

    if fileManager.fileExists(atPath: destination.path) {
      _ = try fileManager.replaceItemAt(destination, withItemAt: partial)
    } else {
      try fileManager.moveItem(at: partial, to: destination)
    }
    progress(DownloadProgress(completed: Self.fileSize(destination), total: total))
  }

  /// One request, appending to (or rewriting) `partial`. Returns the announced total size or -1.
  private func fetch(
    from url: URL,
    into partial: URL,
    offset: Int64,
    progress: @escaping @Sendable (DownloadProgress) -> Void
  ) async throws -> Int64 {
    var request = URLRequest(url: url)
    if offset > 0 { request.setValue("bytes=\(offset)-", forHTTPHeaderField: "Range") }
    let delegate = StreamingDelegate(partial: partial, offset: offset, progress: progress)
    let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
    defer { session.invalidateAndCancel() }
    let task = session.dataTask(with: request)
    try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
        delegate.start(continuation)
        task.resume()
      }
    } onCancel: {
      task.cancel()
    }
    return delegate.total
  }

  public static func fileSize(_ url: URL) -> Int64 {
    ((try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? nil) ?? 0
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

/// The server's answer to a `Range` request cannot be used; start again without it.
private enum DownloadRestart: Error { case fromScratch }

/// Receives one response and writes it to the partial file as it arrives.
private final class StreamingDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
  private let partial: URL
  private let offset: Int64
  private let report: @Sendable (DownloadProgress) -> Void

  private let lock = NSLock()
  private var continuation: CheckedContinuation<Void, any Error>?
  private var handle: FileHandle?
  private var completed: Int64
  private var failure: (any Error)?
  private var finishedWithoutBody = false
  private var _total: Int64 = -1

  init(partial: URL, offset: Int64, progress: @escaping @Sendable (DownloadProgress) -> Void) {
    self.partial = partial
    self.offset = offset
    self.report = progress
    self.completed = offset
  }

  var total: Int64 { lock.withLock { _total } }

  func start(_ continuation: CheckedContinuation<Void, any Error>) {
    lock.withLock { self.continuation = continuation }
  }

  func urlSession(
    _ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
  ) {
    guard let http = response as? HTTPURLResponse else {
      fail(URLError(.badServerResponse), dataTask, completionHandler)
      return
    }
    do {
      switch http.statusCode {
      case 206:
        let range = Self.parseContentRange(http.value(forHTTPHeaderField: "Content-Range"))
        guard let range, range.start == offset else { throw DownloadRestart.fromScratch }
        lock.withLock { _total = range.total ?? -1 }
        try openHandle(truncate: false)
      case 200:
        // Either a plain download or a server that ignored Range: write from the beginning.
        lock.withLock {
          completed = 0
          _total = response.expectedContentLength > 0 ? response.expectedContentLength : -1
        }
        try openHandle(truncate: true)
      case 416 where offset > 0:
        let range = Self.parseContentRange(http.value(forHTTPHeaderField: "Content-Range"))
        guard range?.total == offset else { throw DownloadRestart.fromScratch }
        lock.withLock {
          _total = offset
          finishedWithoutBody = true
        }
      default:
        throw DownloadError.httpStatus(http.statusCode)
      }
      completionHandler(finishedWithoutBody ? .cancel : .allow)
    } catch {
      fail(error, dataTask, completionHandler)
    }
  }

  func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
    do {
      try handle?.write(contentsOf: data)
    } catch {
      lock.withLock { failure = failure ?? error }
      dataTask.cancel()
      return
    }
    let (done, total) = lock.withLock { () -> (Int64, Int64) in
      completed += Int64(data.count)
      return (completed, _total)
    }
    report(DownloadProgress(completed: done, total: total))
  }

  func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
    try? handle?.close()
    let (continuation, failure, noBody) = lock.withLock { () -> (CheckedContinuation<Void, any Error>?, (any Error)?, Bool) in
      defer { self.continuation = nil }
      return (self.continuation, self.failure, finishedWithoutBody)
    }
    if let failure {
      continuation?.resume(throwing: failure)
    } else if let error, !noBody {
      continuation?.resume(throwing: error)
    } else {
      continuation?.resume()
    }
  }

  private func fail(
    _ error: any Error, _ task: URLSessionDataTask,
    _ completionHandler: (URLSession.ResponseDisposition) -> Void
  ) {
    lock.withLock { failure = failure ?? error }
    completionHandler(.cancel)
  }

  private func openHandle(truncate: Bool) throws {
    let fileManager = FileManager.default
    if truncate || !fileManager.fileExists(atPath: partial.path) {
      guard fileManager.createFile(atPath: partial.path, contents: nil) else { throw CocoaError(.fileWriteUnknown) }
    }
    let handle = try FileHandle(forWritingTo: partial)
    if !truncate { try handle.seekToEnd() }
    self.handle = handle
  }

  /// `bytes <start>-<end>/<total>` or `bytes */<total>`.
  static func parseContentRange(_ header: String?) -> (start: Int64, total: Int64?)? {
    guard let header, header.hasPrefix("bytes ") else { return nil }
    let value = header.dropFirst(6)
    let parts = value.split(separator: "/", maxSplits: 1)
    guard parts.count == 2 else { return nil }
    let total = Int64(parts[1])
    if parts[0] == "*" { return (start: -1, total: total) }
    guard let start = parts[0].split(separator: "-").first.flatMap({ Int64($0) }) else { return nil }
    return (start, total)
  }
}
