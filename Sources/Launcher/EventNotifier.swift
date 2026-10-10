import Foundation

/// Something worth a system notification. The app turns each case into localized text.
public enum AppNotification: Sendable, Equatable {
  case jobFinished(GameJob)
  case jobFailed(GameJob, LauncherError)
  case launchFailed(LauncherError)
  case updateAvailable(version: String)
  case preDownloadAvailable(version: String?)
}

/// The system notification centre behind a seam. `authorize` must never throw: a refusal (or any failure,
/// such as an ad-hoc signed app the system will not authorize) is just `false`.
public protocol NotificationDelivering: Sendable {
  func authorize() async -> Bool
  /// True only when the system accepted the notification; a transient failure must not count as sent.
  func deliver(_ notification: AppNotification) async -> Bool
}

/// Turns `JobEvent`s and status changes into notifications. Without authorization it does nothing, silently.
@MainActor
public final class EventNotifier {
  private let delivery: any NotificationDelivering
  private let defaults: UserDefaults
  private var authorization: Bool?
  /// Versions whose announcement is being delivered; concurrent `observe` calls must not post twice.
  private var inFlight: Set<String> = []

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
    if status.canUpdate {
      await announce(.updateAvailable(version: version), key: Self.announcedUpdateKey, version: version)
    }
    if status.canPreDownload {
      let target = status.preDownloadVersion ?? version
      await announce(
        .preDownloadAvailable(version: status.preDownloadVersion), key: Self.announcedPreDownloadKey,
        version: target)
    }
  }

  private func announce(_ notification: AppNotification, key: String, version: String) async {
    let token = "\(key)/\(version)"
    guard defaults.string(forKey: key) != version, inFlight.insert(token).inserted else { return }
    defer { inFlight.remove(token) }
    if await post(notification) { defaults.set(version, forKey: key) }
  }

  /// True when the system accepted the notification.
  @discardableResult
  private func post(_ notification: AppNotification) async -> Bool {
    if authorization == nil { authorization = await delivery.authorize() }
    guard authorization == true else { return false }
    return await delivery.deliver(notification)
  }
}
