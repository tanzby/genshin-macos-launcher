import Foundation
import Synchronization

@testable import Launcher

final class FakeDelivery: NotificationDelivering, Sendable {
  private let state = Mutex<(delivered: [AppNotification], authorizeCalls: Int)>((delivered: [], authorizeCalls: 0))
  let granted: Bool
  let accepts: Bool
  init(granted: Bool, accepts: Bool = true) {
    self.granted = granted
    self.accepts = accepts
  }
  var delivered: [AppNotification] { state.withLock { $0.delivered } }
  var authorizeCalls: Int { state.withLock { $0.authorizeCalls } }
  func authorize() async -> Bool {
    state.withLock { $0.authorizeCalls += 1 }
    return granted
  }
  func deliver(_ notification: AppNotification) async -> Bool {
    await Task.yield()  // lets a concurrent observe() interleave
    state.withLock { $0.delivered.append(notification) }
    return accepts
  }
}
