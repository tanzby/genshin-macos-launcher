import Foundation

/// A value shared with `@Sendable` closures and fakes, guarded by a lock. For the counters, flags and recorded
/// calls a test reads after the code under test has run.
public final class Locked<Value: Sendable>: @unchecked Sendable {
  private let lock = NSLock()
  private var stored: Value

  public init(_ value: Value) { stored = value }

  public var value: Value {
    get { lock.withLock { stored } }
    set { lock.withLock { stored = newValue } }
  }

  public func mutate<R>(_ body: (inout Value) -> R) -> R { lock.withLock { body(&stored) } }
}
