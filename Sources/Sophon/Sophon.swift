import Foundation
import SwiftProtobuf

/// What a Sophon operation reports while it runs. Speed and ETA are computed by the caller.
public enum SophonProgress: Sendable, Equatable {
  case preparing
  case downloading(done: Int64, total: Int64)
  case verifying(done: Int64, total: Int64)
  case patching(done: Int64, total: Int64)
  case finalizing
}

/// Latest remote state of the game branch. `preDownload` is `nil` when the branch is null.
public struct SophonOnlineInfo: Sendable, Equatable {
  public var latestVersion: String
  public var installSize: Int64
  public var patchableVersions: [String]
  public var preDownload: String?

  public init(
    latestVersion: String,
    installSize: Int64,
    patchableVersions: [String] = [],
    preDownload: String? = nil
  ) {
    self.latestVersion = latestVersion
    self.installSize = installSize
    self.patchableVersions = patchableVersions
    self.preDownload = preDownload
  }
}

/// Entry point of the Sophon module. The implementation lands with the Sophon tickets.
public protocol SophonClient: Sendable {
  func onlineInfo() async throws -> SophonOnlineInfo
}
