import Foundation
import SwiftProtobuf

/// What a Sophon operation reports while it runs. Speed and ETA are computed by the caller.
package enum SophonProgress: Sendable, Equatable {
  case preparing
  case downloading(done: Int64, total: Int64)
  case verifying(done: Int64, total: Int64)
  case patching(done: Int64, total: Int64)
  case finalizing
}

/// The game-specific facts Sophon needs, handed in by the game's module (ADR 0002: names, ids and the
/// foreign-build list belong to `GenshinCN`, not to Sophon).
package struct SophonGame: Sendable {
  package var endpoints: SophonEndpoints
  /// The folder holding `globalgamemanagers`, relative to the game directory.
  package var dataFolder: String
  package var executableName: String
  /// Files (relative to the game directory) whose presence means a build of another channel, which is not
  /// supported (UPG-005).
  package var foreignBuildMarkers: [String]
  /// Chunk cache, ldiff files, assembly folders and the launcher's `job.json`, inside the game directory.
  package var tempDirectoryName: String

  package init(
    endpoints: SophonEndpoints, dataFolder: String, executableName: String, foreignBuildMarkers: [String],
    tempDirectoryName: String
  ) {
    self.endpoints = endpoints
    self.dataFolder = dataFolder
    self.executableName = executableName
    self.foreignBuildMarkers = foreignBuildMarkers
    self.tempDirectoryName = tempDirectoryName
  }
}

/// The four jobs Sophon runs in a game directory.
package enum SophonJob: Sendable, Equatable {
  case install, update, repair, preDownload
}

/// What the game directory and the server say about each other. Offline, only the local side is known.
package struct SophonStatus: Sendable, Equatable {
  package var installedVersion: String?
  package var remoteVersion: String?
  package var canUpdate = false
  /// The pre-download branch's version while it is newer than the installed one, offered or already done.
  package var preDownloadVersion: String?
  /// A newer pre-download that can be patched from the installed version and is not downloaded yet.
  package var canPreDownload = false

  package init(installedVersion: String? = nil, remoteVersion: String? = nil) {
    self.installedVersion = installedVersion
    self.remoteVersion = remoteVersion
  }
}
