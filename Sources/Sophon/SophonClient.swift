import Foundation
import Synchronization
import os

private let log = Logger(subsystem: "io.github.tanzby.genshin-launcher", category: "sophon")

/// The entry of the Sophon module: it owns a game job from the server's answer to the version in `config.ini`.
/// Install, update, repair and pre-download, their order (INS-006: the version is written last), the ldiff-or-full
/// choice of an update and the pre-download bookkeeping all live here; the caller passes the game's names as a
/// `SophonGame`, a directory and a progress closure. Every job is idempotent: pausing is cancelling, and running
/// it again with the same arguments continues from what is on disk.
package struct SophonClient: Sendable {
  private let game: SophonGame
  private let api: SophonAPI
  private let downloader: SophonDownloader
  private let updater: SophonUpdater
  private let installation: SophonInstallation
  /// The chunk manifest the repair's disk-space check just downloaded, for the repair that follows it.
  private let repairManifest = ManifestHandOff()

  package init(
    game: SophonGame, session: URLSession = .shared, configuration: SophonDownloadConfiguration = .init()
  ) {
    self.game = game
    api = SophonAPI(endpoints: game.endpoints, session: session)
    downloader = SophonDownloader(session: session, configuration: configuration)
    updater = SophonUpdater(downloader: downloader)
    installation = SophonInstallation(game: game)
  }

  // MARK: - Status

  /// Local and remote versions. Offline (transport or server fault) the remote side stays empty; a broken or
  /// non-China install throws `brokenInstallation` (UPG-005) instead of reading as "no install".
  package func status(in directory: URL?) async throws -> SophonStatus {
    let installed = try directory.flatMap { try installation.installedVersion(in: $0) }
    let branches: SophonGameBranches
    do {
      branches = try await api.gameBranches()
    } catch where SophonError.isOffline(error) {
      return SophonStatus(installedVersion: installed)
    }
    guard let main = branches.main else { throw SophonError.malformedResponse }

    var status = SophonStatus(installedVersion: installed, remoteVersion: main.tag)
    guard let installed, let directory else { return status }
    status.canUpdate = SophonVersion.isOlder(installed, than: main.tag)
    if let pre = branches.preDownload, SophonVersion.isOlder(installed, than: pre.tag) {
      status.preDownloadVersion = pre.tag
      status.canPreDownload =
        pre.diffTags.contains(installed)
        && !SophonUpdater.isPredownloaded(pre.tag, from: installed, in: installation.tempDirectory(in: directory))
    }
    return status
  }

  // MARK: - Running jobs

  /// Runs `job` in `directory`. Reports `.preparing` first and `.finalizing` last; throws `CancellationError`
  /// when cancelled, after every worker has stopped.
  package func run(
    _ job: SophonJob, in directory: URL, progress: @escaping @Sendable (SophonProgress) -> Void
  ) async throws {
    // An install is only known to target a game directory once `prepareForInstall` accepted it.
    if job != .install { installation.removeLegacyTemporaryFolders(in: directory) }
    progress(.preparing)
    switch job {
    case .install: try await install(in: directory, progress: progress)
    case .repair: try await repair(in: directory, progress: progress)
    case .update: try await update(in: directory, progress: progress)
    case .preDownload: try await preDownload(in: directory, progress: progress)
    }
    progress(.finalizing)
  }

  private func install(in directory: URL, progress: @escaping @Sendable (SophonProgress) -> Void) async throws {
    try installation.prepareForInstall(in: directory)  // INS-005: refuses before any request
    installation.removeLegacyTemporaryFolders(in: directory)
    let (main, ref, manifest) = try await mainReleaseWithManifest()
    try await downloader.install(
      manifest.files, using: ref, into: directory, tempDirectory: installation.tempDirectory(in: directory),
      progress: progress)
    try SophonInstallation.verifySizes(of: manifest.files, in: directory)
    // INS-006: the version is written last, so an interrupted install is never taken for a finished one.
    try installation.writeVersion(main.tag, in: directory)
  }

  private func repair(in directory: URL, progress: @escaping @Sendable (SophonProgress) -> Void) async throws {
    let installed = try installedVersion(in: directory)
    let (main, ref) = try await mainRelease()
    // The release info is read again, the manifest only when it is not the one the disk-space check just fetched.
    let manifest: SophonManifest
    if let handedOver = repairManifest.take(matching: ref) {
      manifest = handedOver
    } else {
      manifest = try await api.manifest(for: ref)
    }
    guard installed == main.tag else { throw SophonError.outdated(installed: installed, latest: main.tag) }
    let damaged = try await downloader.findDamagedFiles(in: manifest.files, gameDirectory: directory, progress: progress)
    if !damaged.isEmpty {
      try await downloader.install(
        damaged, using: ref, into: directory, tempDirectory: installation.tempDirectory(in: directory),
        progress: progress)
    }
  }

  private func update(in directory: URL, progress: @escaping @Sendable (SophonProgress) -> Void) async throws {
    let installed = try installedVersion(in: directory)
    let (main, ref) = try await mainRelease()
    guard SophonVersion.isOlder(installed, than: main.tag) else { throw SophonError.noUpdate }
    let temp = installation.tempDirectory(in: directory)

    if main.diffTags.contains(installed) {
      // Both are needed for the plan; awaiting the chunk manifest first keeps its error the one reported.
      async let pendingDiff = diffManifest(for: main)
      let manifest = try await api.manifest(for: ref)
      let (diffRef, diff) = try await pendingDiff
      let plan = try await updater.plan(
        from: installed, diff: diff, manifest: manifest, gameDirectory: directory, progress: progress)
      try await updater.update(
        plan, diff: diffRef, chunks: ref, gameDirectory: directory, tempDirectory: temp, progress: progress)
    } else {
      // No patch from this version: sync every file against the chunk manifest. Intact files are skipped.
      let manifest = try await api.manifest(for: ref)
      try await downloader.install(manifest.files, using: ref, into: directory, tempDirectory: temp, progress: progress)
      try SophonInstallation.verifySizes(of: manifest.files, in: directory)
    }
    do {
      try installation.writeVersion(main.tag, in: directory)
    } catch SophonError.invalidConfig {
      // UPG-011: not exactly one `game_version=` line; the version still reads from globalgamemanagers.
      log.warning("config.ini has no single game_version line; left as it is")
    }
  }

  private func preDownload(in directory: URL, progress: @escaping @Sendable (SophonProgress) -> Void) async throws {
    let installed = try installedVersion(in: directory)
    // No `.bak` healing here: pre-download may overlap a running game, whose files are legitimately aside.
    guard let pre = try await api.gameBranches().preDownload, SophonVersion.isOlder(installed, than: pre.tag) else {
      throw SophonError.noPreDownload
    }
    guard pre.diffTags.contains(installed) else { throw SophonError.versionNotPatchable(installed) }
    async let pendingDiff = diffManifest(for: pre)
    let ref = try await chunkManifestRef(for: pre)
    let manifest = try await api.manifest(for: ref)
    let (diffRef, diff) = try await pendingDiff
    let plan = try await updater.plan(
      from: installed, diff: diff, manifest: manifest, gameDirectory: directory, progress: progress)
    try await updater.predownload(
      plan, targetVersion: pre.tag, diff: diffRef, chunks: ref, gameDirectory: directory,
      tempDirectory: installation.tempDirectory(in: directory), progress: progress)
  }

  // MARK: - Disk space

  /// The bytes `job` will write to the volume of `directory` (what the caller compares with the free space):
  /// the unpacked size for an install or a full sync, download plus result for a patch, the download for a
  /// pre-download, the damaged files for a repair. Writes nothing, not even a missing directory.
  package func requiredDiskSpace(for job: SophonJob, in directory: URL) async throws -> Int64 {
    switch job {
    case .install:
      try installation.validateInstallDirectory(directory)
      return try Self.sizes(of: await mainRelease().ref.stats).uncompressedSize
    case .repair:
      _ = try installedVersion(in: directory)
      let (_, ref, manifest) = try await mainReleaseWithManifest()
      repairManifest.put(manifest, for: ref)
      return try SophonInstallation.bytesToFetch(for: manifest.files, in: directory)
    case .update:
      let installed = try installedVersion(in: directory)
      guard let main = try await api.gameBranches().main else { throw SophonError.malformedResponse }
      guard SophonVersion.isOlder(installed, than: main.tag) else { return 0 }
      guard main.diffTags.contains(installed) else {
        return try Self.sizes(of: await chunkManifestRef(for: main).stats).uncompressedSize
      }
      let stats = try Self.sizes(of: await diffManifestRef(for: main).patchStats[installed])
      let downloaded = SophonUpdater.isPredownloaded(
        main.tag, from: installed, in: installation.tempDirectory(in: directory))
      return (downloaded ? 0 : stats.compressedSize) + stats.uncompressedSize
    case .preDownload:
      let installed = try installedVersion(in: directory)
      guard let pre = try await api.gameBranches().preDownload else { throw SophonError.noPreDownload }
      return try Self.sizes(of: await diffManifestRef(for: pre).patchStats[installed]).compressedSize
    }
  }

  /// A manifest without statistics is a contract break; reading it as 0 bytes would skip the disk check.
  private static func sizes(of stats: SophonStats?) throws -> SophonStats {
    guard let stats else { throw SophonError.malformedResponse }
    return stats
  }

  // MARK: - Shared steps

  private func installedVersion(in directory: URL) throws -> String {
    guard let version = try installation.installedVersion(in: directory) else { throw SophonError.notInstalled }
    return version
  }

  /// The main branch with the manifest of its `game` category (voice packs are not managed, UPG-014).
  private func mainRelease() async throws -> (branch: SophonGameBranch, ref: SophonManifestRef) {
    guard let main = try await api.gameBranches().main else { throw SophonError.malformedResponse }
    return (main, try await chunkManifestRef(for: main))
  }

  private func chunkManifestRef(for branch: SophonGameBranch) async throws -> SophonManifestRef {
    try await api.build(for: branch).manifest(matching: "game")
  }

  private func mainReleaseWithManifest() async throws -> (
    branch: SophonGameBranch, ref: SophonManifestRef, manifest: SophonManifest
  ) {
    let (main, ref) = try await mainRelease()
    return (main, ref, try await api.manifest(for: ref))
  }

  private func diffManifestRef(for branch: SophonGameBranch) async throws -> SophonManifestRef {
    try await api.patchBuild(for: branch).manifest(matching: "game")
  }

  private func diffManifest(for branch: SophonGameBranch) async throws -> (SophonManifestRef, SophonDiffManifest) {
    let ref = try await diffManifestRef(for: branch)
    return (ref, try await api.diffManifest(for: ref))
  }
}

/// One manifest handed from a disk-space check to the job after it, taken at most once and only for the same ref.
private final class ManifestHandOff: Sendable {
  private let slot = Mutex<(ref: SophonManifestRef, manifest: SophonManifest)?>(nil)

  func put(_ manifest: SophonManifest, for ref: SophonManifestRef) {
    slot.withLock { $0 = (ref, manifest) }
  }

  func take(matching ref: SophonManifestRef) -> SophonManifest? {
    slot.withLock { slot in
      defer { slot = nil }
      return slot?.ref == ref ? slot?.manifest : nil
    }
  }
}
