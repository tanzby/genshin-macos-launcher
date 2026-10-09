import CryptoKit
import Foundation
import Platform
import Testing

@testable import Wine

// Shared helpers for the Wine install tests. All fixtures are built at runtime with /usr/bin/tar and
// /usr/bin/ditto; nothing touches the real data directory or the network. Nothing here is a secret:
// every payload is a short marker string.

// MARK: - Temp directories

/// Runs `body` with a fresh, symlink-resolved temp directory and deletes it afterwards.
func withWineTempDirectory<T>(_ body: (URL) async throws -> T) async throws -> T {
  let dir = FileManager.default.temporaryDirectory
    .appending(path: "yaagl-wine-test-\(UUID().uuidString)", directoryHint: .isDirectory)
    .resolvingSymlinksInPath()
  try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: dir) }
  return try await body(dir)
}

/// Relative paths of every file and directory below `root` (sorted), without following symlinks.
func wineRelativePaths(under root: URL) -> [String] {
  guard let enumerator = FileManager.default.enumerator(atPath: root.path) else { return [] }
  return (enumerator.allObjects as? [String] ?? []).sorted()
}

func wineExists(_ url: URL) -> Bool {
  FileManager.default.fileExists(atPath: url.path)
}

func wineSHA256(_ data: Data) -> String {
  SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

func wineSHA256(ofFile url: URL) throws -> String {
  wineSHA256(try Data(contentsOf: url))
}

func winePathsEqual(_ a: String, _ b: URL) -> Bool {
  URL(filePath: a).resolvingSymlinksInPath().path == b.resolvingSymlinksInPath().path
}

// MARK: - Fixture archives

struct WineFixtureToolError: Error { var tool: String; var status: Int32; var output: String }

func wineRunFixtureTool(_ path: String, _ arguments: [String]) throws {
  let process = Process()
  process.executableURL = URL(filePath: path)
  process.arguments = arguments
  process.environment = ["COPYFILE_DISABLE": "1", "PATH": "/usr/bin:/bin"]
  let pipe = Pipe()
  process.standardOutput = pipe
  process.standardError = pipe
  try process.run()
  let data = pipe.fileHandleForReading.readDataToEndOfFile()
  process.waitUntilExit()
  guard process.terminationStatus == 0 else {
    throw WineFixtureToolError(
      tool: path, status: process.terminationStatus, output: String(decoding: data, as: UTF8.self))
  }
}

enum WineFixtureContent {
  static let stockWineInf = "[Version]\nSignature=\"$CHICAGO$\"\n\n; URL Associations\nHKCR,\"http\",,,\"URL:http\"\n\n[Strings]\nfoo=bar\n"
  static func stock(_ name: String) -> Data { Data("STOCK-\(name)".utf8) }
  static func dxmt(_ name: String) -> Data { Data("DXMT-x86_64-\(name)".utf8) }
  static let wrongArch = Data("WRONG-ARCH-MUST-BE-IGNORED".utf8)
  static let dxmtWindowsFiles = ["d3d10core.dll", "d3d11.dll", "dxgi.dll", "winemetal.dll", "nvngx.dll"]
}

struct WineFixtureOptions {
  /// `nil` builds an archive whose root is the Wine tree itself (no strip).
  var winePath: String? = "wine"
  /// Appends junk after the sha256 was computed, like a truncated or tampered download.
  var corruptWine = false
  /// `false` builds a DXMT archive without `x86_64-windows`.
  var dxmtHasX64 = true
}

struct WineFixtures {
  var wineArchive: URL
  var dxmtZip: URL
  var distribution: WineDistribution
  var dxmt: DXMTRelease
}

/// Declared sizes of the fixture archives (the real files are a few KB). Required space = wine archive + 4 x DXMT archive (zip, tar.gz, unpacked) + installed.
let wineFixtureArchiveSize: Int64 = 450_000_000
let wineFixtureDXMTArchiveSize: Int64 = 30_000_000
let wineFixtureInstalledSize: Int64 = 2_000_000_000

let wineFixtureCommit = "abc1234def5678abc1234def5678abc1234def56"

func makeWineFixtures(in directory: URL, options: WineFixtureOptions = .init()) throws -> WineFixtures {
  let fm = FileManager.default
  func write(_ data: Data, to url: URL) throws {
    try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try data.write(to: url)
  }

  // Wine tree
  let wineStage = directory.appending(path: "wine-stage", directoryHint: .isDirectory)
  let tree =
    options.winePath.map { wineStage.appending(path: $0, directoryHint: .isDirectory) } ?? wineStage
  try write(Data("loader".utf8), to: tree.appending(path: "bin/wine"))
  try write(Data("server".utf8), to: tree.appending(path: "bin/wineserver"))
  for name in ["d3d10core.dll", "d3d11.dll", "dxgi.dll", "kernel32.dll"] {
    try write(WineFixtureContent.stock(name), to: tree.appending(path: "lib/wine/x86_64-windows/\(name)"))
  }
  try write(Data("unix-wine".utf8), to: tree.appending(path: "lib/wine/x86_64-unix/wine"))
  try write(Data("unix-wine-host".utf8), to: tree.appending(path: "lib/wine/x86_64-unix/wine-host"))
  try write(Data(WineFixtureContent.stockWineInf.utf8), to: tree.appending(path: "share/wine/wine.inf"))

  let wineArchive = directory.appending(path: "fixture-wine.tar.xz")
  if let winePath = options.winePath {
    try wineRunFixtureTool("/usr/bin/tar", ["-cJf", wineArchive.path, "-C", wineStage.path, winePath])
  } else {
    try wineRunFixtureTool("/usr/bin/tar", ["-cJf", wineArchive.path, "-C", wineStage.path, "."])
  }
  let wineSHA = try wineSHA256(ofFile: wineArchive)
  if options.corruptWine {
    let handle = try FileHandle(forWritingTo: wineArchive)
    try handle.seekToEnd()
    try handle.write(contentsOf: Data("CORRUPTION".utf8))
    try handle.close()
  }

  // DXMT: zip > dxmt-<commit>.tar.gz > <commit>/...
  let dxmtStage = directory.appending(path: "dxmt-stage", directoryHint: .isDirectory)
  let commitDir = dxmtStage.appending(path: "payload/\(wineFixtureCommit)", directoryHint: .isDirectory)
  if options.dxmtHasX64 {
    for name in WineFixtureContent.dxmtWindowsFiles {
      try write(WineFixtureContent.dxmt(name), to: commitDir.appending(path: "x86_64-windows/\(name)"))
    }
    try write(WineFixtureContent.dxmt("winemetal.so"), to: commitDir.appending(path: "x86_64-unix/winemetal.so"))
  }
  for wrong in ["aarch64-windows", "i386-windows"] {
    for name in WineFixtureContent.dxmtWindowsFiles {
      try write(WineFixtureContent.wrongArch, to: commitDir.appending(path: "\(wrong)/\(name)"))
    }
  }
  try write(WineFixtureContent.wrongArch, to: commitDir.appending(path: "aarch64-unix/winemetal.so"))
  let tarGz = dxmtStage.appending(path: "dxmt-\(wineFixtureCommit).tar.gz")
  try wineRunFixtureTool(
    "/usr/bin/tar",
    ["-czf", tarGz.path, "-C", dxmtStage.appending(path: "payload").path, wineFixtureCommit])
  let dxmtZip = directory.appending(path: "fixture-dxmt.zip")
  try wineRunFixtureTool("/usr/bin/ditto", ["-c", "-k", tarGz.path, dxmtZip.path])
  let dxmtSHA = try wineSHA256(ofFile: dxmtZip)

  return WineFixtures(
    wineArchive: wineArchive,
    dxmtZip: dxmtZip,
    distribution: WineDistribution(
      id: "test-wine-1", url: URL(string: "https://fixtures.invalid/wine.tar.xz")!, sha256: wineSHA,
      winePath: options.winePath, archiveSize: wineFixtureArchiveSize, installedSize: wineFixtureInstalledSize),
    dxmt: DXMTRelease(
      version: "abc1234", commit: wineFixtureCommit,
      zipURL: URL(string: "https://fixtures.invalid/dxmt-\(wineFixtureCommit).zip")!, sha256: dxmtSHA,
      archiveSize: wineFixtureDXMTArchiveSize))
}

// MARK: - Stub downloader

struct WineStubDownloadFailure: Error, Equatable {}

final class WineStubDownloader: Downloading, @unchecked Sendable {
  struct Request: Sendable, Equatable {
    var url: URL
    var destination: URL
    var sha256: String?
  }

  private let lock = NSLock()
  private var _requests: [Request] = []
  private var _failing: Set<URL>
  private var _active = 0
  private var _maxActive = 0
  private let sources: [URL: URL]
  private let delay: Duration?
  private let chunks: Int

  /// `chunks`: how many progress reports one download makes, each after a short suspension so concurrent
  /// downloads interleave.
  init(fixtures: WineFixtures, failing: Set<URL> = [], delay: Duration? = nil, chunks: Int = 4) {
    sources = [fixtures.distribution.url: fixtures.wineArchive, fixtures.dxmt.zipURL: fixtures.dxmtZip]
    _failing = failing
    self.delay = delay
    self.chunks = chunks
  }

  var requests: [Request] { lock.withLock { _requests } }
  func count(of url: URL) -> Int { requests.filter { $0.url == url }.count }
  /// The highest number of downloads that were in flight at the same time.
  var maxConcurrentDownloads: Int { lock.withLock { _maxActive } }
  func setFailing(_ urls: Set<URL>) { lock.withLock { _failing = urls } }

  func download(
    from url: URL, to destination: URL, sha256: String?,
    progress: @escaping @Sendable (DownloadProgress) -> Void
  ) async throws {
    lock.withLock {
      _requests.append(Request(url: url, destination: destination, sha256: sha256))
      _active += 1
      _maxActive = max(_maxActive, _active)
    }
    defer { lock.withLock { _active -= 1 } }
    if let delay { try await Task.sleep(for: delay) }
    if lock.withLock({ _failing.contains(url) }) { throw WineStubDownloadFailure() }
    guard let source = sources[url] else { throw WineStubDownloadFailure() }
    let data = try Data(contentsOf: source)
    let actual = wineSHA256(data)
    if let sha256, sha256.lowercased() != actual {
      throw DownloadError.checksumMismatch(expected: sha256, actual: actual)
    }
    let total = Int64(data.count)
    for step in 1...chunks {
      try await Task.sleep(for: .milliseconds(5))
      progress(DownloadProgress(completed: total * Int64(step) / Int64(chunks), total: total))
    }
    let fm = FileManager.default
    try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
    try? fm.removeItem(at: destination)
    try data.write(to: destination)
  }
}

// MARK: - Recording runner

struct WineRecordedCall: Sendable, Equatable {
  var executable: String
  var arguments: [String]
  var environment: [String: String]
  var workingDirectory: String?
}

final class WineRecordingRunner: ProcessRunning, @unchecked Sendable {
  private let lock = NSLock()
  private var _calls: [WineRecordedCall] = []
  private var _infAtBoot: String?
  private var _d3d11AtBoot: Data?
  private var _dxmtDllAtBoot: Bool?
  private let root: URL
  private let bootExitCode: Int32
  private let winecfgExitCode: Int32
  private let tarExitCode: Int32?
  private let tarOutput: String
  private let real = SystemProcessRunner()

  init(
    root: URL, bootExitCode: Int32 = 0, winecfgExitCode: Int32 = 0, tarExitCode: Int32? = nil,
    tarOutput: String = "tar: stub failure"
  ) {
    self.root = root
    self.bootExitCode = bootExitCode
    self.winecfgExitCode = winecfgExitCode
    self.tarExitCode = tarExitCode
    self.tarOutput = tarOutput
  }

  var calls: [WineRecordedCall] { lock.withLock { _calls } }
  /// Contents of `wine/share/wine/wine.inf` at the moment `wineboot` was called.
  var infAtBoot: String? { lock.withLock { _infAtBoot } }
  var d3d11AtBoot: Data? { lock.withLock { _d3d11AtBoot } }
  var systemDxmtDllAtBoot: Bool? { lock.withLock { _dxmtDllAtBoot } }
  var wineCalls: [WineRecordedCall] { calls.filter { Self.isLoader($0.executable) } }

  static func isLoader(_ path: String) -> Bool {
    let url = URL(filePath: path)
    return ["wine", "wine64"].contains(url.lastPathComponent)
      && url.deletingLastPathComponent().lastPathComponent == "bin"
  }

  func run(
    _ executable: URL, arguments: [String], environment: [String: String], workingDirectory: URL?
  ) async throws -> ProcessResult {
    lock.withLock {
      _calls.append(
        WineRecordedCall(
          executable: executable.path, arguments: arguments, environment: environment,
          workingDirectory: workingDirectory?.path))
    }
    switch executable.path {
    case "/usr/bin/tar":
      if let tarExitCode { return ProcessResult(exitCode: tarExitCode, output: tarOutput) }
      return try await real.run(
        executable, arguments: arguments, environment: environment, workingDirectory: workingDirectory)
    case "/usr/bin/ditto":
      return try await real.run(
        executable, arguments: arguments, environment: environment, workingDirectory: workingDirectory)
    default:
      guard Self.isLoader(executable.path) else { return ProcessResult(exitCode: 0, output: "") }
      if arguments.first == "wineboot" {
        let inf = try? String(
          contentsOf: root.appending(path: "wine/share/wine/wine.inf"), encoding: .utf8)
        let d3d11 = try? Data(contentsOf: root.appending(path: "wine/lib/wine/x86_64-windows/d3d11.dll"))
        let system32 = root.appending(path: "wineprefix/drive_c/windows/system32", directoryHint: .isDirectory)
        lock.withLock {
          _infAtBoot = inf
          _d3d11AtBoot = d3d11
        }
        if bootExitCode == 0 {
          try FileManager.default.createDirectory(at: system32, withIntermediateDirectories: true)
        }
        return ProcessResult(exitCode: bootExitCode, output: "wineboot-stub-output")
      }
      return ProcessResult(exitCode: winecfgExitCode, output: "winecfg-stub-output")
    }
  }
}

// MARK: - Progress collector

final class WineProgressCollector: @unchecked Sendable {
  private let lock = NSLock()
  private var labels: [String] = []
  private var _wine: [DownloadProgress] = []
  private var _dxmt: [DownloadProgress] = []

  var wineDownloads: [DownloadProgress] { lock.withLock { _wine } }
  var dxmtDownloads: [DownloadProgress] { lock.withLock { _dxmt } }

  func record(_ progress: WineInstallProgress) {
    switch progress {
    case .downloadingWine(let value): lock.withLock { _wine.append(value) }
    case .downloadingDXMT(let value): lock.withLock { _dxmt.append(value) }
    default: break
    }
    let label: String
    switch progress {
    case .downloadingWine: label = "downloadingWine"
    case .downloadingDXMT: label = "downloadingDXMT"
    case .extracting: label = "extracting"
    case .configuring: label = "configuring"
    case .initializingPrefix: label = "initializingPrefix"
    case .installingDXMT: label = "installingDXMT"
    case .finalizing: label = "finalizing"
    }
    lock.withLock { labels.append(label) }
  }

  /// Labels in arrival order with consecutive repeats collapsed.
  var collapsed: [String] {
    lock.withLock {
      var out: [String] = []
      for label in labels where out.last != label { out.append(label) }
      return out
    }
  }

  var callback: @Sendable (WineInstallProgress) -> Void { { [self] in record($0) } }
}

// MARK: - Harness

struct WineHarness {
  var directory: URL
  var root: URL
  var fixtures: WineFixtures
  var downloader: WineStubDownloader
  var runner: WineRecordingRunner
  var runtime: WineRuntime
  var layout: WineLayout { WineLayout(root: root) }

  func install() async throws { try await runtime.ensureInstalled() }

  func writeFile(_ relative: String, _ text: String = "sentinel") throws {
    let url = root.appending(path: relative)
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(text.utf8).write(to: url)
  }
}

struct WineHarnessOptions {
  var fixture = WineFixtureOptions()
  var failingURLs: (WineFixtures) -> Set<URL> = { _ in [] }
  var downloadDelay: Duration?
  var bootExitCode: Int32 = 0
  var winecfgExitCode: Int32 = 0
  var tarExitCode: Int32?
  var tarOutput = "tar: stub failure"
  /// Free bytes the volume reports. The default is plenty.
  var availableBytes: Int64? = Int64.max
}

func makeWineHarness(in directory: URL, options: WineHarnessOptions = .init()) throws -> WineHarness {
  let fixtures = try makeWineFixtures(
    in: directory.appending(path: "fixtures", directoryHint: .isDirectory), options: options.fixture)
  let root = directory.appending(path: "data", directoryHint: .isDirectory)
  try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  let downloader = WineStubDownloader(
    fixtures: fixtures, failing: options.failingURLs(fixtures), delay: options.downloadDelay)
  let runner = WineRecordingRunner(
    root: root, bootExitCode: options.bootExitCode, winecfgExitCode: options.winecfgExitCode,
    tarExitCode: options.tarExitCode, tarOutput: options.tarOutput)
  let runtime = WineRuntime(
    dataDirectory: DataDirectory(root: root), distribution: fixtures.distribution, dxmt: fixtures.dxmt,
    downloader: downloader, runner: runner, availableSpace: { [bytes = options.availableBytes] _ in bytes })
  return WineHarness(
    directory: directory, root: root, fixtures: fixtures, downloader: downloader, runner: runner,
    runtime: runtime)
}

/// A harness whose install has already completed through the stubs.
func makeInstalledWineHarness(in directory: URL) async throws -> WineHarness {
  let harness = try makeWineHarness(in: directory)
  try await harness.install()
  return harness
}

/// Fixture directories are created below `fixtures/`; this crashes the test early if a helper broke.
extension WineHarness {
  func readStamp() throws -> WineStamp {
    try JSONDecoder().decode(WineStamp.self, from: Data(contentsOf: layout.stampFile))
  }
}
