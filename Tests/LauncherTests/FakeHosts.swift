import Foundation
import Platform
import Synchronization

@testable import Launcher

final class FakeHosts: HostsBlocking, Sendable {
  private let state: Mutex<(status: Result<HostsBlocklist.Status, any Error>, applyCalls: Int, applyError: (any Error)?)>
  init(_ status: HostsBlocklist.Status, applyError: (any Error)? = nil) {
    state = Mutex((status: .success(status), applyCalls: 0, applyError: applyError))
  }
  var applyCalls: Int { state.withLock { $0.applyCalls } }
  func setStatus(_ status: Result<HostsBlocklist.Status, any Error>) { state.withLock { $0.status = status } }
  func status() throws -> HostsBlocklist.Status { try state.withLock { try $0.status.get() } }
  func apply() async throws {
    let error = state.withLock { s -> (any Error)? in
      s.applyCalls += 1
      if s.applyError == nil { s.status = .success(.current) }
      return s.applyError
    }
    if let error { throw error }
  }
}

struct PasswordCancelled: Error {}

extension GameDirectoryRules {
  static let test = GameDirectoryRules(gameExecutable: "Game.exe", isSupportedPath: { !$0.path.contains("\"") })
}
