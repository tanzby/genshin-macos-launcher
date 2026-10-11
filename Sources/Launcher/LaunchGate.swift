import Synchronization

/// Decides atomically between "game process appeared" and "launch timeout expired".
final class LaunchGate: Sendable {
  private enum State { case waiting, started, expired }
  private let state = Mutex(State.waiting)

  /// True when the game process won the race against the timeout.
  func markStarted() -> Bool {
    state.withLock {
      if $0 == .waiting { $0 = .started }
      return $0 == .started
    }
  }

  /// True when the timeout won the race.
  func expire() -> Bool {
    state.withLock {
      guard $0 == .waiting else { return false }
      $0 = .expired
      return true
    }
  }

  var timedOut: Bool { state.withLock { $0 == .expired } }
}
