import Foundation

/// Set when the awaiting task is cancelled, so blocking work on `Offload.queue` can stop early.
final class CancelFlag: @unchecked Sendable {
  private let lock = NSLock()
  private var value = false
  var isSet: Bool { lock.withLock { value } }
  func set() { lock.withLock { value = true } }
}

/// Runs blocking work on a dedicated concurrent queue and resumes when it has finished. Callers are
/// already bounded by their task groups, so the queue never holds more than that many items.
enum Offload {
  static let queue = DispatchQueue(label: "genshin-launcher.sophon.blocking", qos: .utility, attributes: .concurrent)

  static func run<T: Sendable>(_ work: @escaping @Sendable (CancelFlag) throws -> T) async throws -> T {
    try Task.checkCancellation()
    let flag = CancelFlag()
    let result = try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuation in
        queue.async { continuation.resume(with: Result { try work(flag) }) }
      }
    } onCancel: {
      flag.set()
    }
    // Work that finished without looking at the flag (a missing file) must not hide a pause.
    try Task.checkCancellation()
    return result
  }

  static func run<T: Sendable>(_ work: @escaping @Sendable (CancelFlag) -> T) async -> T {
    await withCheckedContinuation { continuation in
      queue.async { continuation.resume(returning: work(CancelFlag())) }
    }
  }
}
