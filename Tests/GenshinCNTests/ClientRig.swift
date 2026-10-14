import Foundation
import Launcher
import Sophon
import Synchronization
import TestSupport
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
  let recoveries = Mutex(0)
  func recover() async { recoveries.withLock { $0 += 1 } }

  let prompts = Mutex<[(recipe: LaunchRecipe, gameDirectory: URL?)]>([])
  func openCommandPrompt(_ recipe: LaunchRecipe, gameDirectory: URL?) async -> Int32? {
    prompts.withLock { $0.append((recipe, gameDirectory)) }
    return 0
  }

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

/// A temporary game directory and data directory around a `GenshinCNClient` whose Sophon talks to a canned server.
/// The job workflows themselves are tested in SophonTests; here only the mapping to the launcher's types is.
final class ClientRig: @unchecked Sendable {
  let root: URL
  let game: URL
  let data: URL
  let protonExtras: URL
  let launcher = FakeLauncher()
  let client: GenshinCNClient

  /// `branches` is the body of getGameBranches; `nil` makes every request fail like a missing network.
  init(branches: Data? = nil) {
    root = temporaryURL("genshin-launcher-client")
    game = root.appending(path: "Game", directoryHint: .isDirectory)
    data = root.appending(path: "Data", directoryHint: .isDirectory)
    protonExtras = root.appending(path: "protonextras", directoryHint: .isDirectory)
    try! FileManager.default.createDirectory(at: game, withIntermediateDirectories: true)
    let (session, _) = BackgroundStub.session { url in
      url.path.hasSuffix("getGameBranches") ? branches.map { (200, $0) } : nil
    }
    client = GenshinCNClient(
      dataDirectory: data, protonExtras: protonExtras, launcher: launcher,
      sophon: SophonClient(game: GenshinCN.sophonGame, session: session))
  }

  /// A getGameBranches answer: the main version, and optionally a pre-download one that patches from `preFrom`.
  static func branches(main: String, diffTags: [String] = [], pre: String? = nil, preFrom: [String] = []) -> Data {
    func branch(_ name: String, _ tag: String, _ diffs: [String]) -> String {
      let tags = diffs.map { "\"\($0)\"" }.joined(separator: ",")
      return """
        "\(name)":{"package_id":"p","branch":"\(name)","password":"x","tag":"\(tag)","diff_tags":[\(tags)],"categories":[]}
        """
    }
    let preDownload = pre.map { "," + branch("pre_download", $0, preFrom) } ?? ""
    return Data(
      """
      {"retcode":0,"message":"OK","data":{"game_branches":[{\(branch("main", main, diffTags))\(preDownload)}]}}
      """.utf8)
  }

  func url(_ path: String) -> URL { game.appending(path: path) }

  func read(_ path: String) -> Data? { try? Data(contentsOf: url(path)) }

  func write(_ path: String, _ data: Data) {
    try! FileManager.default.createDirectory(
      at: url(path).deletingLastPathComponent(), withIntermediateDirectories: true)
    try! data.write(to: url(path))
  }

  func exists(_ path: String) -> Bool { FileManager.default.fileExists(atPath: url(path).path) }

  /// Puts a finished install of `version` on disk: the executable, the version file, the three files the launch
  /// moves aside and `config.ini`.
  func install(_ version: String) {
    for path in ["YuanShen.exe"] + GenshinLaunchRecipe.movedAside { write(path, Data("\(path) \(version)".utf8)) }
    write("YuanShen_Data/globalgamemanagers", Data(("\0" + "\(version)_100_200" + "\0").utf8))
    write(
      "config.ini",
      Data("[General]\r\nchannel=1\r\ncps=mihoyo\r\ngame_version=\(version)\r\nsdk_version=\r\nsub_channel=1\r\n".utf8))
  }
}
