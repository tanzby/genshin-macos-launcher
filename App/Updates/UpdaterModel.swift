import Combine
import Sparkle
import SwiftUI

/// SwiftUI-facing wrapper around `SPUUpdater`: the menu command observes
/// `canCheckForUpdates`, the Settings toggle edits `automaticallyChecksForUpdates`.
@MainActor
@Observable
final class UpdaterModel {
  private(set) var canCheckForUpdates = false

  var automaticallyChecksForUpdates: Bool {
    didSet {
      guard automaticallyChecksForUpdates != updater.automaticallyChecksForUpdates else { return }
      updater.automaticallyChecksForUpdates = automaticallyChecksForUpdates
    }
  }

  @ObservationIgnored private let updater: SPUUpdater
  @ObservationIgnored private var subscriptions: Set<AnyCancellable> = []

  init(updater: SPUUpdater) {
    self.updater = updater
    automaticallyChecksForUpdates = updater.automaticallyChecksForUpdates
    updater.publisher(for: \.canCheckForUpdates)
      .receive(on: DispatchQueue.main)
      .sink { [weak self] value in
        MainActor.assumeIsolated { self?.canCheckForUpdates = value }
      }
      .store(in: &subscriptions)
    updater.publisher(for: \.automaticallyChecksForUpdates)
      .receive(on: DispatchQueue.main)
      .sink { [weak self] value in
        MainActor.assumeIsolated {
          guard let self, self.automaticallyChecksForUpdates != value else { return }
          self.automaticallyChecksForUpdates = value
        }
      }
      .store(in: &subscriptions)
  }

  func checkForUpdates() {
    updater.checkForUpdates()
  }
}
