import Foundation

/// Downloads one resource (a chunk or an ldiff file) into `cached`, resuming with `Range` when part of
/// it is already there. On return the file holds exactly `expected` bytes.
struct ResourceFetcher: Sendable {
  let session: URLSession

  func fetch(name: String, url: URL, expected: Int64, to cached: URL, reporter: ChunkProgress) async throws {
    let fileManager = FileManager.default
    var have = cached.fileSize ?? 0
    if have > expected {
      try? fileManager.removeItem(at: cached)
      have = 0
    }
    if have == expected {
      reporter.set(name, expected)
      return
    }

    var request = URLRequest(url: url)
    request.timeoutInterval = 30
    if have > 0 { request.setValue("bytes=\(have)-", forHTTPHeaderField: "Range") }

    // Cached bytes count as done from the start, so the corrections below stay consistent.
    reporter.set(name, have)
    let stream = ChunkStream(session: session, request: request, expected: expected, have: have, name: name)
    defer { stream.cancel() }
    var handle: FileHandle?
    var written: Int64 = 0
    defer { try? handle?.close() }
    do {
      for try await event in stream.events {
        switch event {
        case .response(let http):
          switch http.statusCode {
          case 206 where have > 0: break
          case 200:
            // The server ignored Range (or we asked for everything): start over.
            reporter.set(name, 0)
            have = 0
          case 416:
            try? fileManager.removeItem(at: cached)
            reporter.set(name, 0)
            throw SophonError.http(status: 416)
          default:
            throw SophonError.http(status: http.statusCode)
          }
          if have == 0 { fileManager.createFile(atPath: cached.path, contents: nil) }
          written = have
          let opened = try FileHandle(forWritingTo: cached)
          try opened.seek(toOffset: UInt64(have))
          handle = opened
        case .data(let block):
          try Task.checkCancellation()
          // A body longer than the manifest says is not this chunk: stop before it fills the disk.
          written += Int64(block.count)
          guard written <= expected else {
            // The catch below closes and removes the file.
            reporter.set(name, 0)
            throw SophonError.checksumMismatch(path: name)
          }
          // Written as it arrives: after a broken connection the next attempt resumes from here.
          try handle?.write(contentsOf: block)
          reporter.set(name, written)
        }
      }
    } catch let error as URLError {
      throw SophonError.from(error)
    } catch SophonError.checksumMismatch(let name) {
      // The body outgrew the chunk: what is on disk is not a prefix worth resuming.
      try? handle?.close()
      handle = nil
      try? fileManager.removeItem(at: cached)
      throw SophonError.checksumMismatch(path: name)
    }
    try handle?.close()
    handle = nil

    guard cached.fileSize == expected else {
      // Short or long body: drop it so the next attempt starts clean.
      try? fileManager.removeItem(at: cached)
      reporter.set(name, 0)
      throw SophonError.checksumMismatch(path: name)
    }
  }
}

/// One streaming GET. A delegate hands over each network block; `bytes(for:)` would cost an async
/// hop per byte. Cancelling the consuming task cancels the request.
final class ChunkStream: NSObject, URLSessionDataDelegate, @unchecked Sendable {
  enum Event: Sendable {
    case response(HTTPURLResponse)
    case data(Data)
  }

  let events: AsyncThrowingStream<Event, any Error>
  private let continuation: AsyncThrowingStream<Event, any Error>.Continuation

  private let task: URLSessionDataTask

  private let expected: Int64
  private var byteLimit: Int64
  private let name: String
  private var received: Int64 = 0

  init(session: URLSession, request: URLRequest, expected: Int64, have: Int64, name: String) {
    self.expected = expected
    byteLimit = expected - have
    self.name = name
    (events, continuation) = AsyncThrowingStream.makeStream()
    task = session.dataTask(with: request)
    super.init()
    task.delegate = self
    continuation.onTermination = { [task] _ in task.cancel() }
    task.resume()
  }

  /// Stops the request and releases the delegate; safe to call after it has finished.
  func cancel() {
    task.cancel()
    continuation.finish()
  }

  func urlSession(
    _ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
  ) {
    guard let http = response as? HTTPURLResponse else {
      continuation.finish(throwing: SophonError.malformedResponse)
      completionHandler(.cancel)
      return
    }
    // A 200 carries the whole chunk even when we asked to resume.
    if http.statusCode == 200 { byteLimit = expected }
    continuation.yield(.response(http))
    completionHandler(.allow)
  }

  func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
    // Delegate callbacks are serial. Stop a body that outgrows the chunk before it piles up in the stream.
    received += Int64(data.count)
    if received > byteLimit && byteLimit >= 0 {
      continuation.finish(throwing: SophonError.checksumMismatch(path: name))
      dataTask.cancel()
      return
    }
    continuation.yield(.data(data))
  }

  func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
    continuation.finish(throwing: error)
  }
}
