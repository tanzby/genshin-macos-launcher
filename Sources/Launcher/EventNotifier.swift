import Foundation

/// Something worth a system notification. The app turns each case into localized text.
public enum AppNotification: Sendable, Equatable {
  case jobFinished(GameJob)
  case jobFailed(GameJob, LauncherError)
  case launchFailed(LauncherError)
  case updateAvailable(version: String)
  case preDownloadAvailable(version: String)
}

/// The system notification centre behind a seam. `authorize` must never throw: a refusal (or any failure,
/// such as an ad-hoc signed app the system will not authorize) is just `false`.
public protocol NotificationDelivering: Sendable {
  func authorize() async -> Bool
  func deliver(_ notification: AppNotification) async
}

/// Turns `JobEvent`s and status changes into notifications. Without authorization it does nothing, silently.
@MainActor
public final class EventNotifier {
  private let delivery: any NotificationDelivering
  private let defaults: UserDefaults
  private var authorization: Bool?

  static let announcedUpdateKey = "announcedUpdateVersion"
  static let announcedPreDownloadKey = "announcedPreDownloadVersion"

  public init(delivery: any NotificationDelivering, defaults: UserDefaults = .standard) {
    self.delivery = delivery
    self.defaults = defaults
  }

  public func handle(_ event: JobEvent) async {
    switch event {
    case .finished(.repair): return  // the user is watching; nothing to announce
    case .finished(let job): await post(.jobFinished(job))
    case .failed(let job, let error): await post(.jobFailed(job, error))
    case .launchFailed(let error): await post(.launchFailed(error))
    }
  }

  /// Announces a new update or pre-download once per version, also across relaunches.
  public func observe(status: GameStatus?) async {
    guard let status, let version = status.remoteVersion, !version.isEmpty else { return }
    if status.canUpdate, defaults.string(forKey: Self.announcedUpdateKey) != version {
      if await post(.updateAvailable(version: version)) {
        defaults.set(version, forKey: Self.announcedUpdateKey)
      }
    }
    if status.canPreDownload, defaults.string(forKey: Self.announcedPreDownloadKey) != version {
      if await post(.preDownloadAvailable(version: version)) {
        defaults.set(version, forKey: Self.announcedPreDownloadKey)
      }
    }
  }

  /// True when the notification was handed to the system.
  @discardableResult
  private func post(_ notification: AppNotification) async -> Bool {
    if authorization == nil { authorization = await delivery.authorize() }
    guard authorization == true else { return false }
    await delivery.deliver(notification)
    return true
  }
}
