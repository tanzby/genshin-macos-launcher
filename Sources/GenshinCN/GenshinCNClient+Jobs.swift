import Foundation
import Launcher
import Sophon
import os

private let log = Logger(subsystem: "io.github.tanzby.yaagl", category: "genshin")

extension GenshinCNClient {
  // MARK: - Running jobs

  public func run(_ job: GameJob) -> AsyncThrowingStream<JobProgress, Error> {
    let (stream, continuation) = AsyncThrowingStream<JobProgress, Error>.makeStream()
    let task = serializer.enqueue { [self] in
      // Paused before it began: do not touch the disk at all.
      if Task.isCancelled {
        continuation.finish(throwing: CancellationError())
        return
      }
      do {
        try await perform(job) { continuation.yield($0) }
        continuation.finish()
      } catch {
        continuation.finish(throwing: Self.map(error))
      }
    }
    continuation.onTermination = { _ in task.cancel() }
    return stream
  }

  private func perform(_ job: GameJob, report: @escaping @Sendable (JobProgress) -> Void) async throws {
    let directory = try requireGameDirectory()
    SophonInstallation.removeLegacyTemporaryFolders(in: directory)
    let sophonReport: @Sendable (SophonProgress) -> Void = { report(Self.jobProgress($0)) }
    switch job {
    case .install: try await install(in: directory, report: report, progress: sophonReport)
    case .repair: try await repair(in: directory, report: report, progress: sophonReport)
    case .update: try await update(in: directory, report: report, progress: sophonReport)
    case .preDownload: try await preDownload(in: directory, report: report, progress: sophonReport)
    }
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
    in directory: URL, report: @Sendable (JobProgress) -> Void, progress: @escaping @Sendable (SophonProgress) -> Void
  ) async throws {
    report(.preparing)
    try SophonInstallation.prepareForInstall(in: directory)  // INS-005: refuses before any request
    let (main, ref, manifest) = try await mainReleaseWithManifest()
    try await downloader.install(
      manifest.files, using: ref, into: directory, tempDirectory: SophonInstallation.tempDirectory(in: directory),
      progress: progress)
    try SophonInstallation.verifySizes(of: manifest.files, in: directory)
    // INS-006: the version is written last, so an interrupted install is never taken for a finished one.
    try SophonInstallation.writeVersion(main.tag, in: directory)
    report(.finalizing)
  }

  // MARK: - Repair

  private func repair(
    in directory: URL, report: @Sendable (JobProgress) -> Void, progress: @escaping @Sendable (SophonProgress) -> Void
  ) async throws {
    report(.preparing)
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
    report(.finalizing)
  }

  // MARK: - Update

  private func update(
    in directory: URL, report: @Sendable (JobProgress) -> Void, progress: @escaping @Sendable (SophonProgress) -> Void
  ) async throws {
    report(.preparing)
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
    report(.finalizing)
  }

  // MARK: - Pre-download

  private func preDownload(
    in directory: URL, report: @Sendable (JobProgress) -> Void, progress: @escaping @Sendable (SophonProgress) -> Void
  ) async throws {
    report(.preparing)
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
    report(.finalizing)
  }

  // MARK: - Disk space

  public func requiredDiskSpace(for job: GameJob) async throws -> Int64 {
    let directory = try requireGameDirectory()
    do {
      switch job {
      case .install:
        return try await mainRelease().ref.stats?.uncompressedSize ?? 0
      case .repair:
        _ = try installedVersion(in: directory)
        let (_, _, manifest) = try await mainReleaseWithManifest()
        return try SophonInstallation.bytesToFetch(for: manifest.files, in: directory)
      case .update:
        let installed = try installedVersion(in: directory)
        let (main, ref) = try await mainRelease()
        guard SophonVersion.isOlder(installed, than: main.tag) else { return 0 }
        guard main.diffTags.contains(installed) else { return ref.stats?.uncompressedSize ?? 0 }
        let stats = try await diffManifestRef(for: main).patchStats[installed]
        let temp = SophonInstallation.tempDirectory(in: directory)
        let downloaded = SophonUpdater.isPredownloaded(main.tag, from: installed, in: temp)
        return (downloaded ? 0 : stats?.compressedSize ?? 0) + (stats?.uncompressedSize ?? 0)
      case .preDownload:
        let installed = try installedVersion(in: directory)
        guard let pre = try await sophon.gameBranches().preDownload else { throw GenshinCNClientError.noPreDownload }
        return try await diffManifestRef(for: pre).patchStats[installed]?.compressedSize ?? 0
      }
    } catch {
      throw Self.map(error)
    }
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
