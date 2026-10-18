import Foundation
import Platform
import Testing
import TestSupport

@testable import Wine

// Shared helpers for the Wine install tests. All fixtures are built at runtime with /usr/bin/tar and
// /usr/bin/ditto; nothing touches the real data directory or the network. Nothing here is a secret:
// every payload is a short marker string.

// MARK: - Temp directories

/// Runs `body` with a fresh, symlink-resolved temp directory (TestSupport removes it when the process exits).
func withWineTempDirectory<T>(_ body: (URL) async throws -> T) async throws -> T {
  try await body(makeTemporaryDirectory("genshin-launcher-wine-test"))
}

/// Relative paths of every file and directory below `root` (sorted), without following symlinks.
func wineRelativePaths(under root: URL) -> [String] {
  guard let enumerator = FileManager.default.enumerator(atPath: root.path) else { return [] }
  return (enumerator.allObjects as? [String] ?? []).sorted()
}

func wineExists(_ url: URL) -> Bool {
  FileManager.default.fileExists(atPath: url.path)
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
  static let gptkFiles = ["d3d10", "d3d11", "d3d12", "d3d12core", "dxgi", "nvapi64", "nvngx-on-metalfx"]
}

struct WineFixtureOptions {
  /// `nil` builds an archive whose root is the Wine tree itself (no strip).
  var winePath: String? = "wine"
  /// Appends junk after the sha256 was computed, like a truncated or tampered download.
  var corruptWine = false
  /// `false` builds a DXMT bundle without `x86_64-windows`.
  var dxmtHasX64 = true
  var gptk4Included = true
}

struct WineFixtures {
  var wineArchive: URL
  var distribution: WineDistribution
  /// The DXMT shipped in the (fake) app.
  var dxmt: DXMTBundle
  var gptk4: GPTK4Bundle?
}

/// Declared sizes of the fixture archive (the real files are a few KB). Required space = wine archive + installed + prefix.
let wineFixtureArchiveSize: Int64 = 450_000_000
let wineFixtureInstalledSize: Int64 = 2_000_000_000
let wineFixturePrefixSize: Int64 = 600_000_000

let wineFixtureCommit = "abc1234def5678abc1234def5678abc1234def56"

func makeWineFixtures(in directory: URL, options: WineFixtureOptions = .init()) throws -> WineFixtures {
  func write(_ data: Data, to url: URL) throws { try writeFile(data, to: url) }

  // Wine tree
  let wineStage = directory.appending(path: "wine-stage", directoryHint: .isDirectory)
  let tree =
    options.winePath.map { wineStage.appending(path: $0, directoryHint: .isDirectory) } ?? wineStage
  try write(Data("loader".utf8), to: tree.appending(path: "bin/wine"))
  try write(Data("server".utf8), to: tree.appending(path: "bin/wineserver"))
  for name in ["d3d10core.dll", "d3d11.dll", "dxgi.dll", "kernel32.dll"] {
    try write(WineFixtureContent.stock(name), to: tree.appending(path: "lib/wine/x86_64-windows/\(name)"))
  }
  try write(Data("Wine base external library".utf8), to: tree.appending(path: "lib/external/wine-base.dylib"))
  try write(Data("unix-wine".utf8), to: tree.appending(path: "lib/wine/x86_64-unix/wine"))
  try write(Data("unix-wine-host".utf8), to: tree.appending(path: "lib/wine/x86_64-unix/wine-host"))
  try write(Data(WineFixtureContent.stockWineInf.utf8), to: tree.appending(path: "share/wine/wine.inf"))

  let wineArchive = directory.appending(path: "fixture-wine.tar.xz")
  if let winePath = options.winePath {
    try wineRunFixtureTool("/usr/bin/tar", ["-cJf", wineArchive.path, "-C", wineStage.path, winePath])
  } else {
    try wineRunFixtureTool("/usr/bin/tar", ["-cJf", wineArchive.path, "-C", wineStage.path, "."])
  }
  let wineSHA = try Downloader.sha256Hex(of: wineArchive)
  if options.corruptWine {
    let handle = try FileHandle(forWritingTo: wineArchive)
    try handle.seekToEnd()
    try handle.write(contentsOf: Data("CORRUPTION".utf8))
    try handle.close()
  }

  // DXMT as it sits in the app: <bundle>/{x86_64-windows,x86_64-unix,VERSION}
  let bundle = directory.appending(path: "dxmt-bundle", directoryHint: .isDirectory)
  if options.dxmtHasX64 {
    for name in WineFixtureContent.dxmtWindowsFiles {
      try write(WineFixtureContent.dxmt(name), to: bundle.appending(path: "x86_64-windows/\(name)"))
    }
    try write(WineFixtureContent.dxmt("winemetal.so"), to: bundle.appending(path: "x86_64-unix/winemetal.so"))
  }
  for wrong in ["aarch64-windows", "i386-windows"] {
    for name in WineFixtureContent.dxmtWindowsFiles {
      try write(WineFixtureContent.wrongArch, to: bundle.appending(path: "\(wrong)/\(name)"))
    }
  }
  try write(WineFixtureContent.wrongArch, to: bundle.appending(path: "aarch64-unix/winemetal.so"))
  try write(Data("\(wineFixtureCommit)\n".utf8), to: bundle.appending(path: "VERSION"))

  var gptk4: GPTK4Bundle?
  if options.gptk4Included {
    let payload = directory.appending(path: "gptk4/lib", directoryHint: .isDirectory)
    let framework = payload.appending(path: "external/D3DMetal.framework/Versions/A", directoryHint: .isDirectory)
    let info = try PropertyListSerialization.data(
      fromPropertyList: ["CFBundleShortVersionString": GPTK4Bundle.expectedVersion], format: .xml, options: 0)
    try write(Data("D3DMetal".utf8), to: framework.appending(path: "D3DMetal"))
    try write(info, to: framework.appending(path: "Resources/Info.plist"))
    try write(Data("libd3dshared".utf8), to: payload.appending(path: "external/libd3dshared.dylib"))
    for file in WineFixtureContent.gptkFiles {
      try write(Data("GPTK-windows-\(file)".utf8), to: payload.appending(path: "wine/x86_64-windows/\(file).dll"))
      let unix = payload.appending(path: "wine/x86_64-unix/\(file).so")
      try FileManager.default.createDirectory(at: unix.deletingLastPathComponent(), withIntermediateDirectories: true)
      try FileManager.default.createSymbolicLink(
        atPath: unix.path, withDestinationPath: "../../external/libd3dshared.dylib")
    }
    gptk4 = GPTK4Bundle(directory: payload, version: GPTK4Bundle.expectedVersion)
  }

  return WineFixtures(
    wineArchive: wineArchive,
    distribution: WineDistribution(
      id: "test-wine-1", url: URL(string: "https://fixtures.invalid/wine.tar.xz")!, sha256: wineSHA,
      winePath: options.winePath, archiveSize: wineFixtureArchiveSize, installedSize: wineFixtureInstalledSize,
      prefixSize: wineFixturePrefixSize),
    dxmt: DXMTBundle(directory: bundle, version: wineFixtureCommit), gptk4: gptk4)
}

// MARK: - Stub downloader

struct WineStubDownloadFailure: Error, Equatable {}

final class WineStubDownloader: Downloading, Sendable {
  struct Request: Sendable, Equatable {
    var url: URL
    var destination: URL
    var sha256: String?
  }

  private let recorded = Locked<[Request]>([])
  private let failing: Locked<Set<URL>>
  private let sources: [URL: URL]
  private let delay: Duration?
  private let chunks: Int

  /// `chunks`: how many progress reports one download makes, each after a short suspension so concurrent
  /// downloads interleave.
  init(fixtures: WineFixtures, failing: Set<URL> = [], delay: Duration? = nil, chunks: Int = 4) {
    sources = [fixtures.distribution.url: fixtures.wineArchive]
    self.failing = Locked(failing)
    self.delay = delay
    self.chunks = chunks
  }

  var requests: [Request] { recorded.value }
  func count(of url: URL) -> Int { requests.filter { $0.url == url }.count }
  func setFailing(_ urls: Set<URL>) { failing.value = urls }

  func download(
    from url: URL, to destination: URL, sha256: String?,
    progress: @escaping @Sendable (DownloadProgress) -> Void
  ) async throws {
    if let sha256, wineExists(destination), try Downloader.sha256Hex(of: destination) == sha256 {
      let size = Downloader.fileSize(destination)
      progress(DownloadProgress(completed: size, total: size))
      return
    }
    recorded.mutate { $0.append(Request(url: url, destination: destination, sha256: sha256)) }
    if let delay { try await Task.sleep(for: delay) }
    if failing.value.contains(url) { throw WineStubDownloadFailure() }
    guard let source = sources[url] else { throw WineStubDownloadFailure() }
    let data = try Data(contentsOf: source)
    let actual = sha256Hex(data)
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

final class WineRecordingRunner: ProcessRunning, Sendable {
  private let recorded = Locked<[WineRecordedCall]>([])
  private let _infAtBoot = Locked<String?>(nil)
  private let _d3d11AtBoot = Locked<Data?>(nil)
  private let dittoExitCode = Locked<Int32?>(nil)
  private let root: URL
  private let bootExitCode: Locked<Int32>
  private let winecfgExitCode: Int32
  private let tarExitCode: Int32?
  private let tarOutput: String
  private let real = SystemProcessRunner()

  init(
    root: URL, bootExitCode: Int32 = 0, winecfgExitCode: Int32 = 0, tarExitCode: Int32? = nil,
    tarOutput: String = "tar: stub failure"
  ) {
    self.root = root
    self.bootExitCode = Locked(bootExitCode)
    self.winecfgExitCode = winecfgExitCode
    self.tarExitCode = tarExitCode
    self.tarOutput = tarOutput
  }

  var calls: [WineRecordedCall] { recorded.value }
  /// Contents of `wine/share/wine/wine.inf` at the moment `wineboot` was called.
  var infAtBoot: String? { _infAtBoot.value }
  var d3d11AtBoot: Data? { _d3d11AtBoot.value }
  var wineCalls: [WineRecordedCall] { calls.filter { Self.isLoader($0.executable) } }
  func setBootExitCode(_ exitCode: Int32) { bootExitCode.value = exitCode }
  func setDittoExitCode(_ exitCode: Int32?) { dittoExitCode.value = exitCode }

  static func isLoader(_ path: String) -> Bool {
    let url = URL(filePath: path)
    return ["wine", "wine64"].contains(url.lastPathComponent)
      && url.deletingLastPathComponent().lastPathComponent == "bin"
  }

  func run(
    _ executable: URL, arguments: [String], environment: [String: String], workingDirectory: URL?
  ) async throws -> ProcessResult {
    recorded.mutate {
      $0.append(
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
      if let exitCode = dittoExitCode.value {
        return ProcessResult(exitCode: exitCode, output: "ditto: stub failure")
      }
      return try await real.run(
        executable, arguments: arguments, environment: environment, workingDirectory: workingDirectory)
    default:
      guard Self.isLoader(executable.path) else { return ProcessResult(exitCode: 0, output: "") }
      if arguments.first == "wineboot" {
        let runtime = executable.deletingLastPathComponent().deletingLastPathComponent()
        let inf = try? String(contentsOf: runtime.appending(path: "share/wine/wine.inf"), encoding: .utf8)
        let d3d11 = try? Data(contentsOf: runtime.appending(path: "lib/wine/x86_64-windows/d3d11.dll"))
        let prefix = URL(filePath: environment["WINEPREFIX"] ?? root.appending(path: "wineprefix").path)
        let system32 = prefix.appending(path: "drive_c/windows/system32", directoryHint: .isDirectory)
        let bootExitCode = self.bootExitCode.value
        _infAtBoot.value = inf
        _d3d11AtBoot.value = d3d11
        if bootExitCode == 0 {
          try FileManager.default.createDirectory(at: system32, withIntermediateDirectories: true)
          try Data("system".utf8).write(to: prefix.appending(path: "system.reg"))
          try Data("user".utf8).write(to: prefix.appending(path: "user.reg"))
        }
        return ProcessResult(exitCode: bootExitCode, output: "wineboot-stub-output")
      }
      return ProcessResult(exitCode: winecfgExitCode, output: "winecfg-stub-output")
    }
  }
}

// MARK: - Progress collector

final class WineProgressCollector: Sendable {
  private let labels = Locked<[String]>([])
  private let wine = Locked<[DownloadProgress]>([])

  var wineDownloads: [DownloadProgress] { wine.value }

  func record(_ progress: WineInstallProgress) {
    switch progress {
    case .downloadingWine(let value): wine.mutate { $0.append(value) }
    default: break
    }
    let label: String
    switch progress {
    case .downloadingWine: label = "downloadingWine"
    case .extracting: label = "extracting"
    case .configuring: label = "configuring"
    case .initializingPrefix: label = "initializingPrefix"
    case .installingDXMT: label = "installingDXMT"
    case .installingGPTK4: label = "installingGPTK4"
    case .finalizing: label = "finalizing"
    }
    labels.mutate { $0.append(label) }
  }

  /// Labels in arrival order with consecutive repeats collapsed.
  var collapsed: [String] {
    var out: [String] = []
    for label in labels.value where out.last != label { out.append(label) }
    return out
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

  func install() async throws { try await runtime.ensureInstalled(for: .dxmt) }

  func writeFile(_ relative: String, _ text: String = "sentinel") throws {
    try TestSupport.writeFile(text, to: root.appending(path: relative))
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
    gptk4: fixtures.gptk4,
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

extension WineHarness {
  func readStamp() throws -> WineStamp {
    try JSONDecoder().decode(WineStamp.self, from: Data(contentsOf: layout.stampFile))
  }
}
