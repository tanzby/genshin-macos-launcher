import Foundation
import Launcher
import Sophon

extension GenshinCNClient {
  // MARK: - Running jobs

  public func run(_ job: GameJob) -> AsyncThrowingStream<JobProgress, Error> {
    let (stream, continuation) = AsyncThrowingStream<JobProgress, Error>.makeStream()
    // Fixed at call time: a job queued behind another must not follow a later `setGameDirectory`.
    let directory = gameDirectory
    let task = serializer.enqueue { [self] in
      // Paused before it began: do not touch the disk at all.
      if Task.isCancelled {
        continuation.finish(throwing: CancellationError())
        return
      }
      do {
        try await perform(job, in: directory) { continuation.yield($0) }
        continuation.finish()
      } catch {
        continuation.finish(throwing: Self.map(error))
      }
    }
    continuation.onTermination = { _ in task.cancel() }
    return stream
  }

  private func perform(
    _ job: GameJob, in directory: URL?, report: @escaping @Sendable (JobProgress) -> Void
  ) async throws {
    guard let directory else { throw GenshinCNClientError.noGameDirectory }
    // An install is only known to target a game directory once `prepareForInstall` accepted it.
    if job != .install { SophonInstallation.removeLegacyTemporaryFolders(in: directory) }
    let progress: @Sendable (SophonProgress) -> Void = { report(Self.jobProgress($0)) }
    report(.preparing)
    switch job {
    case .install: try await install(in: directory, progress: progress)
    case .repair: try await repair(in: directory, progress: progress)
    case .update: try await update(in: directory, progress: progress)
    case .preDownload: try await preDownload(in: directory, progress: progress)
    }
    report(.finalizing)
  }

  static func jobProgress(_ progress: SophonProgress) -> JobProgress {
    switch progress {
    case .preparing: .preparing
    case .downloading(let done, let total), .verifying(let done, let total), .patching(let done, let total):
      .running(done: done, total: total)
    case .finalizing: .finalizing
    }
  }

  // MARK: - Install

  private func install(
    in directory: URL, progress: @escaping @Sendable (SophonProgress) -> Void
  ) async throws {
    try SophonInstallation.prepareForInstall(in: directory)  // INS-005: refuses before any request
    SophonInstallation.removeLegacyTemporaryFolders(in: directory)
    let (main, ref, manifest) = try await mainReleaseWithManifest()
    try await downloader.install(
      manifest.files, using: ref, into: directory, tempDirectory: SophonInstallation.tempDirectory(in: directory),
      progress: progress)
    try SophonInstallation.verifySizes(of: manifest.files, in: directory)
    // INS-006: the version is written last, so an interrupted install is never taken for a finished one.
    try SophonInstallation.writeVersion(main.tag, in: directory)
  }

  // MARK: - Repair

  private func repair(
    in directory: URL, progress: @escaping @Sendable (SophonProgress) -> Void
  ) async throws {
    let installed = try installedVersion(in: directory)
    GenshinGameFiles.healBackups(in: directory)
    let (main, ref, manifest) = try await mainReleaseWithManifest()
    guard installed == main.tag else { throw GenshinCNClientError.outdated(installed: installed, latest: main.tag) }
    let damaged = try await downloader.findDamagedFiles(in: manifest.files, gameDirectory: directory, progress: progress)
    if !damaged.isEmpty {
      try await downloader.install(
        damaged, using: ref, into: directory, tempDirectory: SophonInstallation.tempDirectory(in: directory),
        progress: progress)
    }
  }

  // MARK: - Update

  private func update(
    in directory: URL, progress: @escaping @Sendable (SophonProgress) -> Void
  ) async throws {
    let installed = try installedVersion(in: directory)
    GenshinGameFiles.healBackups(in: directory)
    let (main, ref, manifest) = try await mainReleaseWithManifest()
    guard SophonVersion.isOlder(installed, than: main.tag) else { throw GenshinCNClientError.noUpdate }
    let temp = SophonInstallation.tempDirectory(in: directory)

    if main.diffTags.contains(installed) {
      let (diffRef, diff) = try await diffManifest(for: main)
      let plan = try await updater.plan(
        from: installed, diff: diff, manifest: manifest, gameDirectory: directory, progress: progress)
      try await updater.update(
        plan, diff: diffRef, chunks: ref, gameDirectory: directory, tempDirectory: temp, progress: progress)
    } else {
      // No patch from this version: sync every file against the chunk manifest. Intact files are skipped.
      try await downloader.install(manifest.files, using: ref, into: directory, tempDirectory: temp, progress: progress)
      try SophonInstallation.verifySizes(of: manifest.files, in: directory)
    }
    do {
      try SophonInstallation.writeVersion(main.tag, in: directory)
    } catch SophonError.invalidConfig {
      // UPG-011: not exactly one `game_version=` line; the version still reads from globalgamemanagers.
      log.warning("config.ini has no single game_version line; left as it is")
    }
  }

  // MARK: - Pre-download

  private func preDownload(
    in directory: URL, progress: @escaping @Sendable (SophonProgress) -> Void
  ) async throws {
    let installed = try installedVersion(in: directory)
    // No `.bak` healing here: pre-download may overlap a running game, whose files are legitimately aside.
    guard let pre = try await sophon.gameBranches().preDownload, SophonVersion.isOlder(installed, than: pre.tag) else {
      throw GenshinCNClientError.noPreDownload
    }
    guard pre.diffTags.contains(installed) else { throw SophonError.versionNotPatchable(installed) }
    let build = try await sophon.build(for: pre)
    let ref = try build.manifest(matching: "game")
    let manifest = try await sophon.manifest(for: ref)
    let (diffRef, diff) = try await diffManifest(for: pre)
    let plan = try await updater.plan(
      from: installed, diff: diff, manifest: manifest, gameDirectory: directory, progress: progress)
    try await updater.predownload(
      plan, targetVersion: pre.tag, diff: diffRef, chunks: ref, gameDirectory: directory,
      tempDirectory: SophonInstallation.tempDirectory(in: directory), progress: progress)
  }

  // MARK: - Disk space

  public func requiredDiskSpace(for job: GameJob) async throws -> Int64 {
    let directory = try requireGameDirectory()
    do {
      switch job {
      case .install:
        try SophonInstallation.validateInstallDirectory(directory)
        return try Self.sizes(of: await mainRelease().ref.stats).uncompressedSize
      case .repair:
        _ = try installedVersion(in: directory)
        let (_, _, manifest) = try await mainReleaseWithManifest()
        return try SophonInstallation.bytesToFetch(for: manifest.files, in: directory)
      case .update:
        let installed = try installedVersion(in: directory)
        let (main, ref) = try await mainRelease()
        guard SophonVersion.isOlder(installed, than: main.tag) else { return 0 }
        guard main.diffTags.contains(installed) else { return try Self.sizes(of: ref.stats).uncompressedSize }
        let stats = try Self.sizes(of: await diffManifestRef(for: main).patchStats[installed])
        let temp = SophonInstallation.tempDirectory(in: directory)
        let downloaded = SophonUpdater.isPredownloaded(main.tag, from: installed, in: temp)
        return (downloaded ? 0 : stats.compressedSize) + stats.uncompressedSize
      case .preDownload:
        let installed = try installedVersion(in: directory)
        guard let pre = try await sophon.gameBranches().preDownload else { throw GenshinCNClientError.noPreDownload }
        return try Self.sizes(of: await diffManifestRef(for: pre).patchStats[installed]).compressedSize
      }
    } catch {
      throw Self.map(error)
    }
  }

  /// A manifest without statistics is a contract break; reading it as 0 bytes would skip the disk check.
  private static func sizes(of stats: SophonStats?) throws -> SophonStats {
    guard let stats else { throw SophonError.malformedResponse }
    return stats
  }

  // MARK: - Shared steps

  private func installedVersion(in directory: URL) throws -> String {
    guard let version = try SophonInstallation.installedVersion(in: directory) else {
      throw GenshinCNClientError.notInstalled
    }
    return version
  }

  /// The main branch with the manifest of its `game` category (voice packs are not managed, UPG-014).
  private func mainRelease() async throws -> (branch: SophonGameBranch, ref: SophonManifestRef) {
    guard let main = try await sophon.gameBranches().main else { throw SophonError.malformedResponse }
    return (main, try await sophon.build(for: main).manifest(matching: "game"))
  }

  private func mainReleaseWithManifest() async throws -> (
    branch: SophonGameBranch, ref: SophonManifestRef, manifest: SophonManifest
  ) {
    let (main, ref) = try await mainRelease()
    return (main, ref, try await sophon.manifest(for: ref))
  }

  private func diffManifestRef(for branch: SophonGameBranch) async throws -> SophonManifestRef {
    try await sophon.patchBuild(for: branch).manifest(matching: "game")
  }

  private func diffManifest(for branch: SophonGameBranch) async throws -> (SophonManifestRef, SophonDiffManifest) {
    let ref = try await diffManifestRef(for: branch)
    return (ref, try await sophon.diffManifest(for: ref))
  }
}
