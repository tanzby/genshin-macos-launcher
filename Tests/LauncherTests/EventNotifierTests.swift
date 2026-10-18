import Foundation
import Synchronization
import Testing
import TestSupport

@testable import Launcher

@MainActor
private func notifier(_ delivery: FakeDelivery) -> EventNotifier {
  EventNotifier(delivery: delivery, defaults: makeTemporaryDefaults("notify").defaults)
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

  @Test func PRG_003_wineFailureNotifiesButWineReadyDoesNot() async {
    let delivery = FakeDelivery(granted: true)
    let notifier = notifier(delivery)
    await notifier.handle(.wineReady)
    await notifier.handle(.wineFailed(.client(.network)))
    #expect(delivery.delivered == [.wineFailed(.client(.network))])
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
    let preDownload = GameStatus(
      localVersion: "5.0.0", remoteVersion: "5.0.0", canPreDownload: true, preDownloadVersion: "5.1.0")
    await notifier.observe(status: preDownload)
    await notifier.observe(status: preDownload)
    await notifier.observe(status: nil)
    await notifier.observe(status: GameStatus(localVersion: "5.1.0", remoteVersion: "5.1.0"))
    #expect(delivery.delivered == [.updateAvailable(version: "5.1.0"), .preDownloadAvailable(version: "5.1.0")])
  }

  @Test func announcementsSurviveARelaunchWithoutRepeating() async {
    let defaults = makeTemporaryDefaults("notify").defaults
    let update = GameStatus(localVersion: "5.0.0", remoteVersion: "5.1.0", canUpdate: true)
    let first = FakeDelivery(granted: true)
    await EventNotifier(delivery: first, defaults: defaults).observe(status: update)
    let second = FakeDelivery(granted: true)
    await EventNotifier(delivery: second, defaults: defaults).observe(status: update)
    #expect(first.delivered.count == 1)
    #expect(second.delivered.isEmpty)
  }

  @Test func aDeniedAnnouncementIsNotMarkedAsSent() async {
    let defaults = makeTemporaryDefaults("notify").defaults
    let update = GameStatus(localVersion: "5.0.0", remoteVersion: "5.1.0", canUpdate: true)
    await EventNotifier(delivery: FakeDelivery(granted: false), defaults: defaults).observe(status: update)
    let later = FakeDelivery(granted: true)
    await EventNotifier(delivery: later, defaults: defaults).observe(status: update)
    #expect(later.delivered == [.updateAvailable(version: "5.1.0")])
  }

  @Test func aNotificationTheSystemRejectedIsAnnouncedAgainLater() async {
    let defaults = makeTemporaryDefaults("notify").defaults
    let update = GameStatus(localVersion: "5.0.0", remoteVersion: "5.1.0", canUpdate: true)
    await EventNotifier(delivery: FakeDelivery(granted: true, accepts: false), defaults: defaults)
      .observe(status: update)
    let later = FakeDelivery(granted: true)
    await EventNotifier(delivery: later, defaults: defaults).observe(status: update)
    #expect(later.delivered == [.updateAvailable(version: "5.1.0")])
  }

  @Test func concurrentObservationsOfTheSameVersionAnnounceOnce() async {
    let delivery = FakeDelivery(granted: true)
    let notifier = notifier(delivery)
    let update = GameStatus(localVersion: "5.0.0", remoteVersion: "5.1.0", canUpdate: true)
    async let first: Void = notifier.observe(status: update)
    async let second: Void = notifier.observe(status: update)
    _ = await (first, second)
    #expect(delivery.delivered == [.updateAvailable(version: "5.1.0")])
  }
}
