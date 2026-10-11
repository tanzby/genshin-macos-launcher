import Foundation
import Testing

@testable import Sophon

@Suite struct SophonRetryTests {
  private let config = SophonDownloadConfiguration(maxAttempts: 3, retryDelay: .milliseconds(1))

  @Test func retriesUntilTheOperationSucceeds() async throws {
    let calls = Counter()
    try await SophonRetry.run(config) {
      if calls.next() < 3 { throw SophonError.http(status: 503) }
    }
    #expect(calls.value == 3)
  }

  @Test func givesUpAfterMaxAttempts() async {
    let calls = Counter()
    await #expect(throws: SophonError.self) {
      try await SophonRetry.run(config) {
        _ = calls.next()
        throw SophonError.http(status: 500)
      }
    }
    #expect(calls.value == 3)
  }

  @Test func doesNotRetryWhatAskingAgainCannotFix() async {
    let calls = Counter()
    await #expect(throws: SophonError.self) {
      try await SophonRetry.run(config) {
        _ = calls.next()
        throw SophonError.http(status: 404)
      }
    }
    #expect(calls.value == 1)
  }

  @Test func cancellationEndsItAtOnce() async {
    let calls = Counter()
    await #expect(throws: CancellationError.self) {
      try await SophonRetry.run(config) {
        _ = calls.next()
        throw URLError(.cancelled)
      }
    }
    #expect(calls.value == 1)
  }
}

private final class Counter: @unchecked Sendable {
  private let lock = NSLock()
  private(set) var value = 0
  func next() -> Int { lock.withLock { value += 1; return value } }
}
