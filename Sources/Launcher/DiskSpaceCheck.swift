import Foundation
import Platform
import Wine

/// The free-space preflight of a game job: the client says how many bytes the job needs, plus a margin
/// for the chunk cache and files being assembled next to the finished ones.
struct DiskSpaceCheck: Sendable {
  /// Room for the chunk cache and files being assembled next to the finished ones.
  static let defaultMargin: Int64 = 2 << 30

  let margin: Int64
  let availableSpace: @Sendable (URL) -> Int64?

  /// Free bytes on the volume holding `url`, or on its nearest existing ancestor when it does not exist yet.
  static func systemAvailableCapacity(at url: URL) -> Int64? {
    var probe = url
    while !FileManager.default.fileExists(atPath: probe.path), probe.pathComponents.count > 1 {
      probe.deleteLastPathComponent()
    }
    return WineRuntime.volumeAvailableSpace(probe)
  }

  /// Throws `insufficientDiskSpace` when `required` plus the margin does not fit.
  func verify(required bytes: Int64, in directory: URL) throws {
    guard bytes > 0 else { return }
    let required = bytes + margin
    if let available = availableSpace(directory), available < required {
      throw LauncherError.insufficientDiskSpace(required: required, available: available)
    }
  }
}
