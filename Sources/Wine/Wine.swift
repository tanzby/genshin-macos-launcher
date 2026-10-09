import Foundation
import Platform

/// Owns the pinned Wine runtime and prefix.
public actor WineRuntime {
  /// The one Wine version the app installs (ADR 0001).
  public static let pinnedVersion = "11.0-1-crossover-signed-experimental"

  public nonisolated let layout: WineLayout
  let distribution: WineDistribution
  let dxmt: DXMTRelease
  let downloader: any Downloading
  let runner: any ProcessRunning
  let availableSpace: @Sendable (URL) -> Int64?
  private var installation: Task<Void, any Error>?

  public init(
    dataDirectory: DataDirectory,
    distribution: WineDistribution = .pinned,
    dxmt: DXMTRelease = .pinned,
    downloader: any Downloading = Downloader(),
    runner: (any ProcessRunning)? = nil,
    availableSpace: @escaping @Sendable (URL) -> Int64? = WineRuntime.volumeAvailableSpace
  ) {
    let layout = WineLayout(root: dataDirectory.root)
    self.layout = layout
    self.distribution = distribution
    self.dxmt = dxmt
    self.downloader = downloader
    self.runner = runner ?? SystemProcessRunner(allowedRoots: [layout.runtimeDirectory])
    self.availableSpace = availableSpace
  }

  /// Free bytes on the volume holding `url`, counting what the system can purge. `nil` if it cannot be read.
  public static let volumeAvailableSpace: @Sendable (URL) -> Int64? = { url in
    try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
      .volumeAvailableCapacityForImportantUsage
  }

  public nonisolated var runtimeDirectory: URL { layout.runtimeDirectory }
  public nonisolated var prefixDirectory: URL { layout.prefixDirectory }

  /// Whether the pinned Wine and DXMT are installed and intact. Looks at the disk, not just the stamp.
  public func status() -> WineStatus {
    currentStatus()
  }

  /// Installs Wine + DXMT + prefix when `status()` is not `.ready`. Concurrent callers share one install.
  public func ensureInstalled(progress: @escaping @Sendable (WineInstallProgress) -> Void = { _ in }) async throws {
    if installation == nil, currentStatus() == .ready { return }
    try await runInstall(progress: progress)
  }

  /// Installs unconditionally, replacing `wine/` and `wineprefix/`.
  public func reinstall(progress: @escaping @Sendable (WineInstallProgress) -> Void = { _ in }) async throws {
    try await runInstall(progress: progress)
  }

  private func runInstall(progress: @escaping @Sendable (WineInstallProgress) -> Void) async throws {
    if let running = installation {
      try await running.value
      return
    }
    let task = Task { try await performInstall(progress: progress) }
    installation = task
    defer { installation = nil }
    // The install is its own Task so concurrent callers can share it; forward cancellation to it.
    try await withTaskCancellationHandler {
      try await task.value
    } onCancel: {
      task.cancel()
    }
  }
}
