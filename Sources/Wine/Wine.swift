import Foundation
import Platform

/// Owns the pinned Wine runtime and prefix.
public actor WineRuntime {
  /// The one Wine version the app installs (ADR 0001).
  public static let pinnedVersion = "11.0-1-crossover-signed-experimental"

  public nonisolated let layout: WineLayout
  let distribution: WineDistribution
  let dxmt: DXMTBundle?
  let downloader: any Downloading
  let runner: any ProcessRunning
  let availableSpace: @Sendable (URL) -> Int64?
  private var installation: Task<Void, any Error>?

  /// Production: the pinned Wine build.
  public init(dataDirectory: DataDirectory, dxmt: DXMTBundle? = nil) {
    self.init(dataDirectory: dataDirectory, distribution: .pinned, dxmt: dxmt)
  }

  package init(
    dataDirectory: DataDirectory,
    distribution: WineDistribution,
    dxmt: DXMTBundle? = nil,
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

  /// Installs Wine + DXMT + prefix when `status()` is not `.ready`; when only DXMT is outdated (an app update
  /// brought a newer one) it just copies the new files. Concurrent callers share one install.
  public func ensureInstalled(progress: @escaping @Sendable (WineInstallProgress) -> Void = { _ in }) async throws {
    if installation == nil {
      switch status() {
      case .ready: return
      case .needsInstall(.dxmtOutdated): return try await runRefresh(progress: progress)
      case .needsInstall: break
      }
    }
    try await runInstall(progress: progress)
  }

  /// Installs unconditionally, replacing `wine/` and `wineprefix/`.
  public func reinstall(progress: @escaping @Sendable (WineInstallProgress) -> Void = { _ in }) async throws {
    try await runInstall(progress: progress)
  }

  private func runInstall(progress: @escaping @Sendable (WineInstallProgress) -> Void) async throws {
    try await share { try await self.performInstall(progress: progress) }
  }

  private func runRefresh(progress: @escaping @Sendable (WineInstallProgress) -> Void) async throws {
    try await share { try await self.refreshDXMT(progress: progress) }
  }

  private func share(_ work: @escaping @Sendable () async throws -> Void) async throws {
    if let running = installation {
      try await running.value
      return
    }
    let task = Task { try await work() }
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
