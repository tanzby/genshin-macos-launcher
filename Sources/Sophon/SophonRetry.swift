import Foundation

/// Exponential-backoff retry policy shared by every download step.
enum SophonRetry {
  /// Runs `operation` up to `maxAttempts` times with exponential backoff (INS-010). Cancellation and
  /// errors that asking again cannot fix end it at once.
  static func run(_ config: SophonDownloadConfiguration, _ operation: () async throws -> Void) async throws {
    var delay = config.retryDelay
    var attempt = 1
    while true {
      try Task.checkCancellation()
      do {
        try await operation()
        return
      } catch {
        if error is CancellationError || (error as? URLError)?.code == .cancelled {
          throw CancellationError()
        }
        guard attempt < config.maxAttempts, isRetryable(error) else { throw error }
        attempt += 1
        try await Task.sleep(for: delay)
        delay *= 2
      }
    }
  }

  /// 4xx other than "slow down" will not change by asking again; path and manifest errors neither.
  static func isRetryable(_ error: any Error) -> Bool {
    switch error {
    case SophonError.http(let status): return status >= 500 || status == 408 || status == 416 || status == 429
    case SophonError.unsafePath, SophonError.invalidManifest, SophonError.noMatchingCategory,
      SophonError.ambiguousCategory:
      return false
    default: return true
    }
  }
}
