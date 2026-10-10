import Foundation
import Synchronization
import Testing

@testable import Launcher

final class FakeDelivery: NotificationDelivering, Sendable {
  private let state = Mutex<(delivered: [AppNotification], authorizeCalls: Int)>((delivered: [], authorizeCalls: 0))
  let granted: Bool
  init(granted: Bool) { self.granted = granted }
  var delivered: [AppNotification] { state.withLock { $0.delivered } }
  var authorizeCalls: Int { state.withLock { $0.authorizeCalls } }
  func authorize() async -> Bool {
    state.withLock { $0.authorizeCalls += 1 }
    return granted
  }
  func deliver(_ notification: AppNotification) async {
    state.withLock { $0.delivered.append(notification) }
  }
}

@MainActor
private func notifier(_ delivery: FakeDelivery) -> EventNotifier {
  let suite = "yaagl-notify-\(UUID().uuidString)"
  let defaults = UserDefaults(suiteName: suite)!
  defaults.removePersistentDomain(forName: suite)
  return EventNotifier(delivery: delivery, defaults: defaults)
}

@MainActor @Suite struct EventNotifierTests {
  @Test func PRG_003_jobEventsBecomeNotifications() async {
    let delivery = FakeDelivery(granted: true)
    let notifier = notifier(delivery)
    await notifier.handle(.finished(.update))
    await notifier.handle(.failed(.install, .client(.network)))
    await notifier.handle(.launchFailed(.launchTimeout))
    #expect(
      delivery.delivered == [
        .jobFinished(.update), .jobFailed(.install, .client(.network)), .launchFailed(.launchTimeout),
      ])
  }

  @Test func PRG_003_aFinishedRepairIsNotWorthANotification() async {
    let delivery = FakeDelivery(granted: true)
    await notifier(delivery).handle(.finished(.repair))
    #expect(delivery.delivered.isEmpty)
  }

  @Test func notificationAuthorizationDeniedDegradesSilently() async {
    let delivery = FakeDelivery(granted: false)
    let notifier = notifier(delivery)
    await notifier.handle(.failed(.update, .client(.verificationFailed)))
    await notifier.handle(.finished(.install))
    #expect(delivery.delivered.isEmpty)
    #expect(delivery.authorizeCalls == 1, "authorization is asked once, not on every event")
  }

  @Test func updateAndPreDownloadAreAnnouncedOncePerVersion() async {
    let delivery = FakeDelivery(granted: true)
    let notifier = notifier(delivery)
    let update = GameStatus(localVersion: "5.0.0", remoteVersion: "5.1.0", canUpdate: true)
    await notifier.observe(status: update)
    await notifier.observe(status: update)
    let preDownload = GameStatus(localVersion: "5.0.0", remoteVersion: "5.0.0", canPreDownload: true)
    await notifier.observe(status: preDownload)
    await notifier.observe(status: preDownload)
    await notifier.observe(status: nil)
    await notifier.observe(status: GameStatus(localVersion: "5.1.0", remoteVersion: "5.1.0"))
    #expect(delivery.delivered == [.updateAvailable(version: "5.1.0"), .preDownloadAvailable(version: "5.0.0")])
  }

  @Test func announcementsSurviveARelaunchWithoutRepeating() async {
    let suite = "yaagl-notify-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defaults.removePersistentDomain(forName: suite)
    let update = GameStatus(localVersion: "5.0.0", remoteVersion: "5.1.0", canUpdate: true)
    let first = FakeDelivery(granted: true)
    await EventNotifier(delivery: first, defaults: defaults).observe(status: update)
    let second = FakeDelivery(granted: true)
    await EventNotifier(delivery: second, defaults: defaults).observe(status: update)
    #expect(first.delivered.count == 1)
    #expect(second.delivered.isEmpty)
  }

  @Test func aDeniedAnnouncementIsNotMarkedAsSent() async {
    let suite = "yaagl-notify-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defaults.removePersistentDomain(forName: suite)
    let update = GameStatus(localVersion: "5.0.0", remoteVersion: "5.1.0", canUpdate: true)
    await EventNotifier(delivery: FakeDelivery(granted: false), defaults: defaults).observe(status: update)
    let later = FakeDelivery(granted: true)
    await EventNotifier(delivery: later, defaults: defaults).observe(status: update)
    #expect(later.delivered == [.updateAvailable(version: "5.1.0")])
  }
}
