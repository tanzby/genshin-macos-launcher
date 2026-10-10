import Foundation

/// One file the update turns from the installed version into the new one with an ldiff patch.
public struct SophonPlannedPatch: Sendable, Equatable {
  public let file: SophonDiffFile
  public let patch: SophonPatch
  /// The same file in the chunk manifest: used when the patch cannot be applied (UPG-009).
  public let fallback: SophonFile
}

/// What an update from one installed version has to do. Built by `SophonUpdater.plan`.
public struct SophonUpdatePlan: Sendable, Equatable {
  public let fromVersion: String
  /// Files patched in place from the ldiff files.
  public let patches: [SophonPlannedPatch]
  /// New, missing or damaged files, downloaded as chunks (UPG-010).
  public let downloads: [SophonFile]
  /// Old files the new version no longer has (UPG-007).
  public let deletions: [SophonDeletedFile]
  /// Every file of the diff manifest; the update is checked against it at the end (UPG-011).
  public let expectedFiles: [SophonDiffFile]

  /// The ldiff files to download, each once, in first-use order.
  public var ldiffs: [SophonLdiffFile] {
    var seen = Set<String>()
    return patches.compactMap { planned in
      seen.insert(planned.patch.patchID).inserted
        ? SophonLdiffFile(id: planned.patch.patchID, size: planned.patch.patchSize) : nil
    }
  }

  public var ldiffSize: Int64 { ldiffs.reduce(0) { $0 + $1.size } }

  /// Compressed bytes of every chunk of the files in `downloads`.
  public var chunkSize: Int64 {
    downloads.reduce(Int64(0)) { sum, file in file.chunks.reduce(sum) { $0 + Int64($1.compressedSize) } }
  }

  /// Nothing to download or patch (deletions may still be left).
  public var isUpToDate: Bool { patches.isEmpty && downloads.isEmpty }
}

/// Which pre-download the temp directory holds. State lives with the data it describes: deleting the
/// temp directory forgets it, and it is recorded per target version, not as one yes/no flag (PRE-001).
public struct SophonPredownloadRecord: Sendable, Equatable, Codable {
  public let targetVersion: String
  public let fromVersion: String
  /// `false` while the download is under way; set after the last ldiff and chunk is in place.
  public let complete: Bool

  static func url(in tempDirectory: URL) -> URL { tempDirectory.appending(path: "predownload.json") }

  static func read(from tempDirectory: URL) -> SophonPredownloadRecord? {
    guard let data = try? Data(contentsOf: url(in: tempDirectory)) else { return nil }
    return try? JSONDecoder().decode(SophonPredownloadRecord.self, from: data)
  }

  func write(to tempDirectory: URL) throws {
    try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
    try JSONEncoder().encode(self).write(to: Self.url(in: tempDirectory), options: .atomic)
  }
}

/// ldiff incremental update and pre-download (UPG-007..012, PRE-001/002). Every step is idempotent:
/// pausing is cancelling, and calling again with the same arguments continues from what is on disk.
public struct SophonUpdater: Sendable {
  private let downloader: SophonDownloader

  public init(session: URLSession = .shared, configuration: SophonDownloadConfiguration = .init()) {
    downloader = SophonDownloader(session: session, configuration: configuration)
  }

  // MARK: - Pre-download record

  /// Whether `targetVersion` has been pre-downloaded completely into `tempDirectory`.
  public static func isPredownloaded(_ targetVersion: String, in tempDirectory: URL) -> Bool {
    guard let record = SophonPredownloadRecord.read(from: tempDirectory) else { return false }
    return record.complete && record.targetVersion == targetVersion
  }

  // MARK: - Plan

  /// Decides, file by file, how to get from `installedVersion` to the version of `diff` (UPG-008).
  /// The installed files are hashed once: a file that already matches the new version is skipped, so
  /// running the update again after a pause or a crash never patches twice.
  ///
  /// | local file | action |
  /// |---|---|
  /// | diff has no patches | chunk download (new file) |
  /// | diff has no patch for `installedVersion` | untouched |
  /// | MD5 and size match the new file | untouched (already updated) |
  /// | size and MD5 match `original_hash` | patch |
  /// | missing, or anything else | chunk download |
  public func plan(
    from installedVersion: String,
    diff: SophonDiffManifest,
    manifest: SophonManifest,
    gameDirectory: URL,
    progress: @escaping @Sendable (SophonProgress) -> Void = { _ in }
  ) async throws -> SophonUpdatePlan {
    // Every file lacking a patch for this version would read as "not modified": an update that
    // succeeds without doing anything. Refuse versions the patch build does not know.
    let known =
      diff.files.contains { $0.patches[installedVersion] != nil } || diff.deletions[installedVersion] != nil
    guard known else { throw SophonError.versionNotPatchable(installedVersion) }

    let chunkFiles = Dictionary(manifest.files.map { ($0.path, $0) }, uniquingKeysWith: { first, _ in first })
    func chunkFile(_ path: String) throws -> SophonFile {
      guard let file = chunkFiles[path], !file.isDirectory else {
        throw SophonError.invalidManifest("\(path) is not in the chunk manifest")
      }
      return file
    }

    enum Verdict: Sendable {
      case untouched
      /// A new file: it may already be in place, which the pass below finds out.
      case newFile(SophonFile)
      /// Checked above and not matching: missing, damaged or not the file the patch needs.
      case download(SophonFile)
      case patch(SophonPlannedPatch)
    }
    struct Candidate: Sendable {
      let file: SophonDiffFile
      let patch: SophonPatch?
      let destination: URL
      let original: URL?
    }

    var candidates: [Candidate] = []
    for file in diff.files {
      let destination = try SophonPathPolicy.resolve(file.path, in: gameDirectory)
      if file.patches.isEmpty {
        candidates.append(Candidate(file: file, patch: nil, destination: destination, original: nil))
      } else if let patch = file.patches[installedVersion] {
        let originalPath = patch.originalPath.isEmpty ? file.path : patch.originalPath
        let original = try SophonPathPolicy.resolve(originalPath, in: gameDirectory)
        candidates.append(Candidate(file: file, patch: patch, destination: destination, original: original))
      }
    }
    // A deletion names a file. One that is a folder holding new files would wipe them (and `removeItem`
    // is recursive), so a hostile manifest is refused before the first request.
    let newPaths = diff.files.map { $0.path.lowercased() }
    for deleted in diff.deletions[installedVersion] ?? [] {
      _ = try SophonPathPolicy.resolve(deleted.path, in: gameDirectory)
      var folder = deleted.path.lowercased()
      while folder.hasSuffix("/") { folder.removeLast() }
      if newPaths.contains(where: { $0.hasPrefix(folder + "/") }) {
        throw SophonError.invalidManifest("\(deleted.path) is a folder of the new version")
      }
    }

    let total = candidates.reduce(Int64(0)) { $0 + max($1.file.size, $1.patch?.originalSize ?? 0) }
    let counter = VerifyCounter(total: total, interval: .milliseconds(250), report: progress)
    progress(.verifying(done: 0, total: total))
    let limit = max(2, ProcessInfo.processInfo.activeProcessorCount - 4)
    var verdicts = [Verdict](repeating: .untouched, count: candidates.count)
    let chunkOf = chunkFiles
    try await withThrowingTaskGroup(of: (Int, Verdict).self) { group in
      var next = 0
      func submit() {
        guard next < candidates.count, !Task.isCancelled else { return }
        let index = next
        next += 1
        let candidate = candidates[index]
        group.addTask {
          let verdict: Verdict = try await Offload.run { cancelled in
            let newFile = candidate.file
            // Patchless entries are new files: the chunk download skips the ones already in place.
            guard let patch = candidate.patch else {
              guard let chunks = chunkOf[newFile.path], !chunks.isDirectory else {
                throw SophonError.invalidManifest("\(newFile.path) is not in the chunk manifest")
              }
              return .newFile(chunks)
            }
            guard let chunks = chunkOf[newFile.path], !chunks.isDirectory else {
              throw SophonError.invalidManifest("\(newFile.path) is not in the chunk manifest")
            }
            // One read serves both questions when the patch rewrites the file in place.
            let inPlace = candidate.original == candidate.destination
            let size = Self.size(of: candidate.destination)
            let digest = (size == newFile.size || (inPlace && size == patch.originalSize))
              ? try MD5Hasher.hex(ofFileAt: candidate.destination, cancelled: cancelled) : nil
            if size == newFile.size, digest?.caseInsensitiveCompare(newFile.md5) == .orderedSame {
              return .untouched
            }
            let originalMatches: Bool
            if inPlace {
              originalMatches =
                size == patch.originalSize && digest?.caseInsensitiveCompare(patch.originalMD5) == .orderedSame
            } else if let original = candidate.original {
              originalMatches = try Self.matches(
                original, size: patch.originalSize, md5: patch.originalMD5, cancelled: cancelled)
            } else {
              originalMatches = false
            }
            return originalMatches
              ? .patch(SophonPlannedPatch(file: newFile, patch: patch, fallback: chunks)) : .download(chunks)
          }
          counter.add(max(candidate.file.size, candidate.patch?.originalSize ?? 0))
          return (index, verdict)
        }
      }
      for _ in 0..<limit { submit() }
      while let (index, verdict) = try await group.next() {
        verdicts[index] = verdict
        submit()
      }
    }
    try Task.checkCancellation()
    progress(.verifying(done: total, total: total))

    var patches: [SophonPlannedPatch] = []
    var downloads: [SophonFile] = []
    var newFiles: [SophonFile] = []
    for verdict in verdicts {
      switch verdict {
      case .untouched: break
      case .newFile(let file): newFiles.append(file)
      case .download(let file): downloads.append(file)
      case .patch(let planned): patches.append(planned)
      }
    }
    // New files may already be on disk and intact: leave those out of the totals.
    var seenNew = Set<String>()
    let uniqueNew = newFiles.filter { seenNew.insert($0.path).inserted }
    let destinations = try uniqueNew.map { ($0, try SophonPathPolicy.resolve($0.path, in: gameDirectory)) }
    let missing: [SophonFile] = try await Offload.run { cancelled in
      try destinations.filter { file, url in
        !(try Self.matches(url, size: file.size, md5: file.md5, cancelled: cancelled))
      }.map(\.0)
    }
    try Self.validate(patches: patches)
    return SophonUpdatePlan(
      fromVersion: installedVersion, patches: patches, downloads: downloads + missing,
      deletions: diff.deletions[installedVersion] ?? [], expectedFiles: diff.files)
  }

  // MARK: - Pre-download

  /// PRE-002: downloads the ldiff files and the chunks of the new files into `tempDirectory`. The game
  /// directory is not touched: nothing is deleted, patched or replaced. The record that makes
  /// `isPredownloaded` true is written last.
  public func predownload(
    _ plan: SophonUpdatePlan,
    targetVersion: String,
    diff diffRef: SophonManifestRef,
    chunks chunkRef: SophonManifestRef,
    gameDirectory: URL,
    tempDirectory: URL,
    progress: @escaping @Sendable (SophonProgress) -> Void
  ) async throws {
    try Self.validate(patches: plan.patches)
    progress(.preparing)
    let fileManager = FileManager.default
    if let record = SophonPredownloadRecord.read(from: tempDirectory), record.targetVersion != targetVersion {
      // Data of an older target is useless now; the same target keeps what it has (resume).
      try? fileManager.removeItem(at: Self.ldiffDirectory(in: tempDirectory))
      try? fileManager.removeItem(at: tempDirectory.appending(path: "chunks", directoryHint: .isDirectory))
    }
    try SophonPredownloadRecord(targetVersion: targetVersion, fromVersion: plan.fromVersion, complete: false)
      .write(to: tempDirectory)

    let total = plan.ldiffSize + plan.chunkSize
    let reporter = ProgressReporter(total: total, interval: downloader.configuration.progressInterval, report: progress)
    try await downloader.fetchLdiffs(
      plan.ldiffs, using: diffRef, into: Self.ldiffDirectory(in: tempDirectory), reporter: reporter)
    if !plan.downloads.isEmpty {
      try await downloader.prefetch(
        plan.downloads, using: chunkRef, into: gameDirectory, tempDirectory: tempDirectory, reporter: reporter)
    }
    reporter.finish(.downloading(done: total, total: total))
    try SophonPredownloadRecord(targetVersion: targetVersion, fromVersion: plan.fromVersion, complete: true)
      .write(to: tempDirectory)
  }

  // MARK: - Update

  /// Brings the game directory from `plan.fromVersion` to the new version. Order: download the ldiff
  /// files (the ones from a pre-download are reused), patch, delete old files, download the rest,
  /// check. Old files go only after patching because a patch may read a file the new version drops.
  /// Writing the new version into `config.ini` is left to the caller.
  public func update(
    _ plan: SophonUpdatePlan,
    diff diffRef: SophonManifestRef,
    chunks chunkRef: SophonManifestRef,
    gameDirectory: URL,
    tempDirectory: URL,
    progress: @escaping @Sendable (SophonProgress) -> Void
  ) async throws {
    try Self.validate(patches: plan.patches)
    progress(.preparing)
    let ldiffDirectory = Self.ldiffDirectory(in: tempDirectory)

    if !plan.patches.isEmpty {
      let reporter = ProgressReporter(
        total: plan.ldiffSize, interval: downloader.configuration.progressInterval, report: progress)
      try await downloader.fetchLdiffs(plan.ldiffs, using: diffRef, into: ldiffDirectory, reporter: reporter)
      reporter.finish(.downloading(done: plan.ldiffSize, total: plan.ldiffSize))
    }

    // UPG-009: a patch that fails any check leaves the file alone and moves it to the chunk downloads.
    var downloads = plan.downloads
    let patchTotal = plan.patches.reduce(Int64(0)) { $0 + $1.file.size }
    var patchDone: Int64 = 0
    progress(.patching(done: 0, total: patchTotal))
    let patchDirectory = tempDirectory.appending(path: "patching", directoryHint: .isDirectory)
    for planned in plan.patches {
      try Task.checkCancellation()
      let applied = try await Self.apply(
        planned, ldiffDirectory: ldiffDirectory, patchDirectory: patchDirectory, gameDirectory: gameDirectory)
      if !applied { downloads.append(planned.fallback) }
      patchDone += planned.file.size
      progress(.patching(done: patchDone, total: patchTotal))
    }

    // UPG-007: files the new version no longer has.
    let keep = Set(plan.expectedFiles.map { $0.path.lowercased() })
    for deleted in plan.deletions where !keep.contains(deleted.path.lowercased()) {
      try Task.checkCancellation()
      let url = try SophonPathPolicy.resolve(deleted.path, in: gameDirectory)
      // Only a file or a link goes. `attributesOfItem` does not follow links, and a folder is never removed.
      guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path) else { continue }
      guard attributes[.type] as? FileAttributeType != .typeDirectory else {
        throw SophonError.invalidManifest("\(deleted.path) is a folder, not a file")
      }
      try FileManager.default.removeItem(at: url)
    }

    // UPG-010: new, missing and damaged files, plus the ones whose patch failed.
    if !downloads.isEmpty {
      try await downloader.install(
        downloads, using: chunkRef, into: gameDirectory, tempDirectory: tempDirectory, progress: progress)
    }

    // UPG-011: sizes of every file of the new version, and the old files are gone.
    progress(.finalizing)
    for file in plan.expectedFiles {
      let url = try SophonPathPolicy.resolve(file.path, in: gameDirectory)
      guard Self.size(of: url) == file.size else { throw SophonError.verificationFailed(path: file.path) }
    }
    for deleted in plan.deletions where !keep.contains(deleted.path.lowercased()) {
      let url = try SophonPathPolicy.resolve(deleted.path, in: gameDirectory)
      if Self.exists(url) { throw SophonError.verificationFailed(path: deleted.path) }
    }

    // UPG-012: the ldiff files of this update go; the directory stays.
    for ldiff in plan.ldiffs { try? FileManager.default.removeItem(at: ldiffDirectory.appending(path: ldiff.id)) }
    try? FileManager.default.removeItem(at: patchDirectory)
    try? FileManager.default.removeItem(at: SophonPredownloadRecord.url(in: tempDirectory))
  }

  // MARK: - Internals

  static func ldiffDirectory(in tempDirectory: URL) -> URL {
    tempDirectory.appending(path: "ldiff", directoryHint: .isDirectory)
  }

  /// Patches and ldiff slices come from the server: check them before the first request (INS-011 style).
  static func validate(patches: [SophonPlannedPatch]) throws {
    var sizes: [String: Int64] = [:]
    for planned in patches {
      let patch = planned.patch
      guard SophonDownloaderLayout.isSafeName(patch.patchID) else {
        throw SophonError.invalidManifest("unsafe ldiff id for \(planned.file.path)")
      }
      let (end, overflow) = patch.offset.addingReportingOverflow(patch.length)
      guard patch.offset >= 0, patch.length > 0, !overflow, end <= patch.patchSize else {
        throw SophonError.invalidManifest("patch of \(planned.file.path) lies outside its ldiff file")
      }
      if let known = sizes[patch.patchID], known != patch.patchSize {
        throw SophonError.invalidManifest("ldiff \(patch.patchID) has two sizes")
      }
      sizes[patch.patchID] = patch.patchSize
    }
  }

  /// Size and MD5 both match. A missing file does not match.
  static func matches(_ url: URL, size: Int64, md5: String, cancelled: CancelFlag) throws -> Bool {
    guard Self.size(of: url) == size else { return false }
    return try MD5Hasher.hex(ofFileAt: url, cancelled: cancelled).caseInsensitiveCompare(md5) == .orderedSame
  }

  static func size(of url: URL) -> Int64 {
    guard let size = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber else {
      return -1
    }
    return size.int64Value
  }

  /// Also true for a dangling symlink.
  static func exists(_ url: URL) -> Bool {
    (try? FileManager.default.attributesOfItem(atPath: url.path)) != nil
  }

  /// Patches one file. Returns `false` when the file must come from the chunk download instead: the
  /// old file or the ldiff file is not what the manifest says, or the result does not match its MD5
  /// (the original file is then left alone). Throws only for cancellation.
  private static func apply(
    _ planned: SophonPlannedPatch, ldiffDirectory: URL, patchDirectory: URL, gameDirectory: URL
  ) async throws -> Bool {
    let file = planned.file
    let patch = planned.patch
    return try await Offload.run { cancelled in
      let destination = try SophonPathPolicy.resolve(file.path, in: gameDirectory)
      // Already the new file (a previous run got this far): nothing to do.
      if try matches(destination, size: file.size, md5: file.md5, cancelled: cancelled) { return true }
      let originalPath = patch.originalPath.isEmpty ? file.path : patch.originalPath
      let original = try SophonPathPolicy.resolve(originalPath, in: gameDirectory)
      // Before patching: the old file must be the one the patch was made for.
      guard try matches(original, size: patch.originalSize, md5: patch.originalMD5, cancelled: cancelled) else {
        return false
      }
      let ldiff = ldiffDirectory.appending(path: patch.patchID)
      guard size(of: ldiff) == patch.patchSize else { return false }

      let fileManager = FileManager.default
      try fileManager.createDirectory(at: patchDirectory, withIntermediateDirectories: true)
      let staging = patchDirectory.appending(path: SophonDownloaderLayout.fileKey(for: file.path) + ".patched")
      try? fileManager.removeItem(at: staging)
      do {
        try HDiffPatcher.apply(
          old: original, ldiff: ldiff, offset: patch.offset, length: patch.length, to: staging,
          expectedSize: file.size, name: file.path, cancelled: cancelled)
      } catch is CancellationError {
        try? fileManager.removeItem(at: staging)
        throw CancellationError()
      } catch {
        try? fileManager.removeItem(at: staging)
        return false
      }
      // After patching: a wrong result is thrown away, never moved over the original.
      guard try matches(staging, size: file.size, md5: file.md5, cancelled: cancelled) else {
        try? fileManager.removeItem(at: staging)
        return false
      }
      // The game directory may have changed meanwhile: resolve once more right before the move.
      let safe = try SophonPathPolicy.resolve(file.path, in: gameDirectory)
      try fileManager.createDirectory(at: safe.deletingLastPathComponent(), withIntermediateDirectories: true)
      if exists(safe) {
        _ = try fileManager.replaceItemAt(safe, withItemAt: staging)
      } else {
        try fileManager.moveItem(at: staging, to: safe)
      }
      return true
    }
  }
}
