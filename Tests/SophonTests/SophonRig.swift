import Foundation
import Synchronization
import TestSupport

@testable import Sophon

/// A temporary game directory and a fake CDN wired into a `SophonClient`.
final class SophonRig: @unchecked Sendable {
  let root: URL
  let game: URL
  let cdn: FakeGameCDN
  let client: SophonClient
  /// What the client is asked about: the game folder, or `nil` for a launcher with none chosen.
  let directory: URL?

  init(main: FakeRelease, pre: FakeRelease? = nil, withGameDirectory: Bool = true) {
    root = temporaryURL("genshin-launcher-sophon")
    game = root.appending(path: "Game", directoryHint: .isDirectory)
    try! FileManager.default.createDirectory(at: game, withIntermediateDirectories: true)
    cdn = FakeGameCDN(main: main, pre: pre)
    client = SophonClient(
      game: FakeGameCDN.game(),
      session: cdn.session,
      configuration: SophonDownloadConfiguration(concurrency: 2, maxAttempts: 1, retryDelay: .milliseconds(1)))
    directory = withGameDirectory ? game : nil
  }

  func url(_ path: String) -> URL { game.appending(path: path) }

  func read(_ path: String) -> Data? { try? Data(contentsOf: url(path)) }

  func write(_ path: String, _ data: Data) {
    try! FileManager.default.createDirectory(
      at: url(path).deletingLastPathComponent(), withIntermediateDirectories: true)
    try! data.write(to: url(path))
  }

  func exists(_ path: String) -> Bool { FileManager.default.fileExists(atPath: url(path).path) }

  var configText: String? { read("config.ini").map { String(decoding: $0, as: UTF8.self) } }

  /// Polls until `config.ini` says `version`, so a test does not depend on how fast a loaded runner gets there.
  func waitForConfig(version: String) async -> Bool {
    await pollUntil { configText?.contains("game_version=\(version)") == true }
  }

  /// Puts `release` on disk as a finished install, with `config.ini` saying `version` (default: its tag).
  func install(_ release: FakeRelease, configVersion: String? = nil) {
    for (path, content) in release.files { write(path, content) }
    write(
      "config.ini",
      Data(
        "[General]\r\nchannel=1\r\ncps=mihoyo\r\ngame_version=\(configVersion ?? release.tag)\r\nsdk_version=\r\nsub_channel=1\r\n"
          .utf8))
  }

  func status() async throws -> SophonStatus { try await client.status(in: directory) }

  func requiredDiskSpace(for job: SophonJob) async throws -> Int64 {
    try await client.requiredDiskSpace(for: job, in: game)
  }

  /// Everything `run(job)` reports, or the error it ends with.
  func run(_ job: SophonJob, in folder: URL? = nil) async -> (progress: [SophonProgress], error: (any Error)?) {
    let progress = Mutex<[SophonProgress]>([])
    do {
      try await client.run(job, in: folder ?? game) { update in progress.withLock { $0.append(update) } }
      return (progress.withLock { $0 }, nil)
    } catch {
      return (progress.withLock { $0 }, error)
    }
  }
}

extension FakeRelease {
  /// A tiny but recognisable game: the executable, the version file and the three files the launch moves aside.
  static func game(_ tag: String, extra: [String: Data] = [:], diffTags: [String] = []) -> FakeRelease {
    var files: [String: Data] = [
      "YuanShen.exe": Data("MZ \(tag)".utf8),
      "YuanShen_Data/globalgamemanagers": Data(("\0" + "\(tag)_100_200" + "\0").utf8),
      "YuanShen_Data/Plugins/crashreport.exe": Data("crashreport \(tag)".utf8),
      "YuanShen_Data/Plugins/vulkan-1.dll": Data("vulkan \(tag)".utf8),
      "YuanShen_Data/upload_crash.exe": Data("upload_crash \(tag)".utf8),
      "pkg_version": Data("pkg \(tag)".utf8),
    ]
    for (path, content) in extra { files[path] = content }
    return FakeRelease(tag: tag, files: files, diffTags: diffTags)
  }
}
