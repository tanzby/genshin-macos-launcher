import Foundation
import Launcher
import Sophon
import Synchronization
import Wine

@testable import GenshinCN

/// Records the recipe and plays back a scripted result, like the real `GameSession` would.
final class FakeLauncher: GameLaunching {
  enum Script: Sendable {
    case result(LaunchResult)
    /// Fires `onStarted`, then waits until cancelled and returns `.cancelled` after `cleanup` ran.
    case runUntilCancelled
  }

  private struct State {
    var recipes: [LaunchRecipe] = []
    var script: Script = .result(.exited)
    var cleanupFinished = false
    var filesAtLaunch: [String: Bool] = [:]
  }

  private let state = Mutex(State())
  let watchedFiles = Mutex<[URL]>([])
  let started = Mutex(0)

  var recipes: [LaunchRecipe] { state.withLock { $0.recipes } }
  var cleanupFinished: Bool { state.withLock { $0.cleanupFinished } }
  var filesAtLaunch: [String: Bool] { state.withLock { $0.filesAtLaunch } }
  func script(_ script: Script) { state.withLock { $0.script = script } }

  func launch(_ recipe: LaunchRecipe, onStarted: @escaping @Sendable () -> Void) async -> LaunchResult {
    let files = watchedFiles.withLock { $0 }
    let script = state.withLock { s -> Script in
      s.recipes.append(recipe)
      for file in files { s.filesAtLaunch[file.lastPathComponent] = FileManager.default.fileExists(atPath: file.path) }
      return s.script
    }
    switch script {
    case .result(let result):
      return result
    case .runUntilCancelled:
      onStarted()
      started.withLock { $0 += 1 }
      while !Task.isCancelled { try? await Task.sleep(for: .milliseconds(2)) }
      try? await Task.sleep(for: .milliseconds(30))  // the uncancellable cleanup
      state.withLock { $0.cleanupFinished = true }
      return .cancelled
    }
  }
}

/// A temporary game directory, data directory and fake CDN wired into a `GenshinCNClient`.
final class ClientRig: @unchecked Sendable {
  let root: URL
  let game: URL
  let data: URL
  let protonExtras: URL
  let cdn: FakeCDN
  let launcher = FakeLauncher()
  let client: GenshinCNClient

  init(main: FakeRelease, pre: FakeRelease? = nil, withGameDirectory: Bool = true) {
    root = FileManager.default.temporaryDirectory.appending(path: "yaagl-client-\(UUID().uuidString)")
    game = root.appending(path: "Game", directoryHint: .isDirectory)
    data = root.appending(path: "Data", directoryHint: .isDirectory)
    protonExtras = root.appending(path: "protonextras", directoryHint: .isDirectory)
    try! FileManager.default.createDirectory(at: game, withIntermediateDirectories: true)
    cdn = FakeCDN(main: main, pre: pre)
    let configuration = SophonDownloadConfiguration(concurrency: 2, maxAttempts: 1, retryDelay: .milliseconds(1))
    client = GenshinCNClient(
      dataDirectory: data, protonExtras: protonExtras, launcher: launcher, sophon: cdn.api,
      downloader: SophonDownloader(session: cdn.session, configuration: configuration),
      updater: SophonUpdater(session: cdn.session, configuration: configuration))
    if withGameDirectory { client.setGameDirectory(game) }
  }

  deinit { try? FileManager.default.removeItem(at: root) }

  func url(_ path: String) -> URL { game.appending(path: path) }

  func read(_ path: String) -> Data? { try? Data(contentsOf: url(path)) }

  func write(_ path: String, _ data: Data) {
    try! FileManager.default.createDirectory(
      at: url(path).deletingLastPathComponent(), withIntermediateDirectories: true)
    try! data.write(to: url(path))
  }

  func exists(_ path: String) -> Bool { FileManager.default.fileExists(atPath: url(path).path) }

  var configText: String? { read("config.ini").map { String(decoding: $0, as: UTF8.self) } }

  /// Puts `release` on disk as a finished install, with `config.ini` saying `version` (default: its tag).
  func install(_ release: FakeRelease, configVersion: String? = nil) {
    for (path, content) in release.files { write(path, content) }
    write(
      "config.ini",
      Data(
        "[General]\r\nchannel=1\r\ncps=mihoyo\r\ngame_version=\(configVersion ?? release.tag)\r\nsdk_version=\r\nsub_channel=1\r\n"
          .utf8))
  }

  /// Everything `run(job)` reports, or the error it ends with.
  func run(_ job: GameJob) async -> (progress: [JobProgress], error: (any Error)?) {
    var progress: [JobProgress] = []
    do {
      for try await update in client.run(job) { progress.append(update) }
      return (progress, nil)
    } catch {
      return (progress, error)
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
