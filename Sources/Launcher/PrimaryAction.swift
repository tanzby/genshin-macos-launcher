import Foundation

/// What the main button does next. A pure function of the launcher's state.
package enum PrimaryAction: Sendable, Equatable {
  /// Wine is missing or damaged; nothing else can run until it is prepared.
  case prepareWine
  case install
  case update
  case launch

  package static func derive(_ status: GameStatus?) -> PrimaryAction {
    guard let status, status.localVersion != nil else { return .install }
    return status.canUpdate ? .update : .launch
  }
}
