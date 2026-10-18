import Foundation
import Platform

/// Owns the pinned Wine runtimes and the shared prefix.
public actor WineRuntime {
  /// The one Wine version the app installs (ADR 0001).
  public static let pinnedVersion = "11.0-1-crossover-signed-experimental"

  public nonisolated let layout: WineLayout
  let distribution: WineDistribution
  let dxmt: DXMTBundle?
  let gptk4: GPTK4Bundle?
  let downloader: any Downloading
  package nonisolated let runner: any ProcessRunning
  let availableSpace: @Sendable (URL) -> Int64?
  private var installation: Task<Void, any Error>?

  /// Production: the pinned Wine build.
  public init(dataDirectory: DataDirectory, dxmt: DXMTBundle? = nil, gptk4: GPTK4Bundle? = nil) {
    self.init(dataDirectory: dataDirectory, distribution: .pinned, dxmt: dxmt, gptk4: gptk4)
  }

  package init(
    dataDirectory: DataDirectory,
    distribution: WineDistribution,
    dxmt: DXMTBundle? = nil,
    gptk4: GPTK4Bundle? = nil,
    downloader: any Downloading = Downloader(),
    runner: (any ProcessRunning)? = nil,
    availableSpace: @escaping @Sendable (URL) -> Int64? = WineRuntime.volumeAvailableSpace
  ) {
    let layout = WineLayout(root: dataDirectory.root)
    self.layout = layout
    self.distribution = distribution
    self.dxmt = dxmt
    self.gptk4 = gptk4
    self.downloader = downloader
    self.runner = runner ?? SystemProcessRunner(
      allowedRoots: GraphicsBackend.allCases.map { WineLayout(root: dataDirectory.root, backend: $0).runtimeDirectory })
    self.availableSpace = availableSpace
  }

  /// Free bytes on the volume holding `url`, counting what the system can purge. `nil` if it cannot be read.
  public static let volumeAvailableSpace: @Sendable (URL) -> Int64? = { url in
    try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
      .volumeAvailableCapacityForImportantUsage
  }

  public nonisolated func layout(for backend: GraphicsBackend) -> WineLayout {
    WineLayout(root: layout.root, backend: backend)
  }

  /// Installs the selected backend's runtime and initializes the shared prefix only when it does not exist.
  public func ensureInstalled(
    for backend: GraphicsBackend, progress: @escaping @Sendable (WineInstallProgress) -> Void = { _ in }
  ) async throws {
    // Wait out a running install (it may be the other backend's); its outcome shows in the status read next.
    if let installation { _ = try? await installation.value }
    switch status(for: backend) {
    case .ready: return
    case .needsInstall(.backendUnavailable): throw WineInstallError.gptk4BundleInvalid
    case .needsInstall(.prefixUnrecognized): throw WineInstallError.prefixUnrecognized(layout.prefixDirectory)
    case .needsInstall(.dxmtOutdated):
      try await runRefresh(progress: progress)
    case .needsInstall:
      try await runInstall(for: backend, progress: progress)
    }
  }

  /// Reinstalls only the selected runtime. The shared prefix is preserved.
  public func reinstall(
    _ backend: GraphicsBackend, progress: @escaping @Sendable (WineInstallProgress) -> Void = { _ in }
  ) async throws {
    if let installation { try await installation.value }
    try await runInstall(for: backend, progress: progress)
  }

  private func runInstall(for backend: GraphicsBackend, progress: @escaping @Sendable (WineInstallProgress) -> Void) async throws {
    try await share { try await self.performInstall(for: backend, progress: progress) }
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
