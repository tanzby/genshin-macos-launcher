import Foundation

extension Error {
  /// The work was stopped, nothing failed: `CancellationError`, or a `URLSession` call that was cancelled.
  public var isCancellation: Bool { self is CancellationError || (self as? URLError)?.code == .cancelled }
}
