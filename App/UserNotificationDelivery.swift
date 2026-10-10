import Foundation
import Launcher
import OSLog
import UserNotifications

/// `UNUserNotificationCenter` behind `NotificationDelivering`. Anything that goes wrong (no bundle, an
/// ad-hoc signed app the system refuses, a denied prompt) ends as "not authorized": no notifications, no error.
struct UserNotificationDelivery: NotificationDelivering {
  private static let log = Logger(subsystem: "io.github.tanzby.yaagl", category: "notifications")

  /// Shows banners while Yaagl is the frontmost app too.
  final class Presenter: NSObject, UNUserNotificationCenterDelegate {
    func userNotificationCenter(
      _ center: UNUserNotificationCenter, willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
      [.banner, .list]
    }
  }

  nonisolated(unsafe) private static let presenter = Presenter()

  func authorize() async -> Bool {
    guard Bundle.main.bundleIdentifier != nil else { return false }
    let center = UNUserNotificationCenter.current()
    center.delegate = Self.presenter
    do {
      let granted = try await center.requestAuthorization(options: [.alert, .sound])
      Self.log.info("notification authorization granted: \(granted)")
      return granted
    } catch {
      Self.log.info("notification authorization unavailable: \(error.localizedDescription)")
      return false
    }
  }

  func deliver(_ notification: AppNotification) async -> Bool {
    let content = UNMutableNotificationContent()
    content.title = String(localized: notification.title)
    content.body = String(localized: notification.body)
    content.sound = .default
    let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
    do {
      try await UNUserNotificationCenter.current().add(request)
      return true
    } catch {
      Self.log.info("notification not delivered: \(error.localizedDescription)")
      return false
    }
  }
}
