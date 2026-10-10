import CryptoKit
import Foundation
import Sophon
import SwiftProtobuf

@testable import Sophon

// An in-memory Sophon service for the GenshinCNClient tests: getGameBranches, getBuild, getPatchBuild,
// manifests and chunks, all served through a `URLProtocol` stub. Chunks are zstd frames made of raw blocks
// (the vendored zstd cannot compress). The bytes of the files are short marker strings, never secrets.

func md5Hex(_ data: Data) -> String {
  Insecure.MD5.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

/// A valid zstd frame made of one raw block per 128 KB.
func zstdRawFrame(_ raw: Data) -> Data {
  var frame = Data([0x28, 0xB5, 0x2F, 0xFD, 0x00, 0x58])
  var offset = 0
  repeat {
    let size = min(128 * 1024, raw.count - offset)
    let last = offset + size >= raw.count
    let header = UInt32(last ? 1 : 0) | UInt32(size << 3)
    frame.append(contentsOf: [UInt8(header & 0xFF), UInt8((header >> 8) & 0xFF), UInt8((header >> 16) & 0xFF)])
    frame.append(raw.subdata(in: offset..<(offset + size)))
    offset += size
  } while offset < raw.count
  return frame
}

/// The files of one released version, as a CDN would hold them.
struct FakeRelease {
  var tag: String
  var files: [String: Data]
  /// Older versions this release can be patched from.
  var diffTags: [String] = []

  func manifestID(_ branch: String) -> String { "manifest-\(branch)-\(tag)" }

  func chunkID(_ path: String) -> String { "chunk-\(tag)-" + path.replacingOccurrences(of: "/", with: "_") }

  func frame(_ path: String) -> Data { zstdRawFrame(files[path]!) }

  var sortedPaths: [String] { files.keys.sorted() }

  var chunkManifest: Data {
    var manifest = PbManifest()
    for path in sortedPaths {
      let content = files[path]!
      var chunk = PbChunkInfo()
      chunk.chunkID = chunkID(path)
      chunk.md5 = md5Hex(content)
      chunk.offset = 0
      chunk.compressedSize = UInt32(frame(path).count)
      chunk.uncompressedSize = UInt32(content.count)
      chunk.compressedMd5 = md5Hex(frame(path))
      var file = PbFileInfo()
      file.filename = path
      file.chunks = [chunk]
      file.size = Int32(content.count)
      file.md5 = md5Hex(content)
      manifest.files.append(file)
    }
    return zstdRawFrame(try! manifest.serializedData())
  }

  var uncompressedSize: Int { files.values.reduce(0) { $0 + $1.count } }
  var compressedSize: Int { sortedPaths.reduce(0) { $0 + frame($1).count } }
}

final class FakeCDN: @unchecked Sendable {
  static let hyp = "https://hyp.test/api"
  static let downloader = "https://dl.test/api"
  static let endpoints = SophonEndpoints(
    hypConnectBase: URL(string: hyp)!, downloaderBase: URL(string: downloader)!, gameID: "game", launcherID: "launcher")

  private let lock = NSLock()
  private var _main: FakeRelease
  private var _pre: FakeRelease?
  private var _preDiffTags: [String] = []
  private var _online = true
  private var _requests: [String] = []
  private var _chunkDelay: Duration = .zero
  /// Files removed in the update from the keyed old version: `deletions[installed] = [paths]`.
  private var _deletions: [String: [String: Data]] = [:]
  init(main: FakeRelease, pre: FakeRelease? = nil) {
    _main = main
    _pre = pre
  }

  var main: FakeRelease {
    get { lock.withLock { _main } }
    set { lock.withLock { _main = newValue } }
  }
  var pre: FakeRelease? {
    get { lock.withLock { _pre } }
    set { lock.withLock { _pre = newValue } }
  }
  var online: Bool {
    get { lock.withLock { _online } }
    set { lock.withLock { _online = newValue } }
  }
  var chunkDelay: Duration {
    get { lock.withLock { _chunkDelay } }
    set { lock.withLock { _chunkDelay = newValue } }
  }
  /// Old files an update from `version` deletes.
  func setDeletions(from version: String, _ files: [String: Data]) { lock.withLock { _deletions[version] = files } }
  /// Every request as "METHOD path-with-query", oldest first.
  var requests: [String] { lock.withLock { _requests } }
  func chunkRequests() -> [String] { requests.filter { $0.contains("/chunks/") } }

  /// One session for every consumer, so the stub sees all traffic.
  private(set) lazy var session: URLSession = {
    StubURLProtocol.session(reply: { [unowned self] request in handle(request) }).session
  }()

  var api: SophonAPI { SophonAPI(endpoints: Self.endpoints, session: session) }

  private func handle(_ request: URLRequest) -> StubReply {
    let url = request.url!
    lock.withLock { _requests.append("\(request.httpMethod ?? "GET") \(url.path)?\(url.query ?? "")") }
    guard online else { return .failure(.notConnectedToInternet) }
    let (main, pre, deletions, delay) = lock.withLock { (_main, _pre, _deletions, _chunkDelay) }
    let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
    let branch = query.first { $0.name == "branch" }?.value ?? "main"
    let release = branch == "main" ? main : (pre ?? main)

    switch (url.host, url.lastPathComponent) {
    case ("hyp.test", "getGameBranches"):
      return json(branchesJSON(main: main, pre: pre))
    case ("dl.test", "getBuild"):
      return json(buildJSON(release, branch: branch))
    case ("dl.test", "getPatchBuild"):
      return json(patchBuildJSON(release, branch: branch, installedGuess: release.diffTags))
    case ("cdn.test", let name) where url.path.hasPrefix("/manifests/"):
      if name == main.manifestID("main") { return ok(main.chunkManifest) }
      if let pre, name == pre.manifestID("predownload") { return ok(pre.chunkManifest) }
      if name.hasPrefix("diff-") {
        let target = name == "diff-main" ? main : (pre ?? main)
        return ok(diffManifest(target, deletions: deletions))
      }
      return .response(status: 404, body: Data())
    case ("cdn.test", let name) where url.path.hasPrefix("/chunks/"):
      for candidate in [main, pre].compactMap({ $0 }) {
        for path in candidate.sortedPaths where candidate.chunkID(path) == name {
          return .response(status: 200, body: candidate.frame(path), delay: delay)
        }
      }
      return .response(status: 404, body: Data())
    default:
      return .response(status: 404, body: Data())
    }
  }

  private func ok(_ body: Data) -> StubReply { .response(status: 200, body: body) }

  private func json(_ object: [String: Any]) -> StubReply {
    let envelope: [String: Any] = ["retcode": 0, "message": "OK", "data": object]
    return ok(try! JSONSerialization.data(withJSONObject: envelope))
  }

  private func branchJSON(_ release: FakeRelease, branch: String) -> [String: Any] {
    [
      "package_id": "pkg-\(branch)", "branch": branch, "password": "secret", "tag": release.tag,
      "diff_tags": release.diffTags,
      "categories": [["category_id": "1", "matching_field": "game"]],
    ]
  }

  private func branchesJSON(main: FakeRelease, pre: FakeRelease?) -> [String: Any] {
    var entry: [String: Any] = ["game": ["id": "game", "biz": "hk4e_cn"], "main": branchJSON(main, branch: "main")]
    entry["pre_download"] = pre.map { branchJSON($0, branch: "predownload") } ?? NSNull()
    return ["game_branches": [entry]]
  }

  private func download(_ prefix: String) -> [String: Any] {
    ["encryption": 0, "password": "", "compression": 1, "url_prefix": prefix, "url_suffix": ""]
  }

  private func buildJSON(_ release: FakeRelease, branch: String) -> [String: Any] {
    [
      "build_id": "build-\(release.tag)", "tag": release.tag,
      "manifests": [
        [
          "category_id": "1", "matching_field": "game",
          "manifest": ["id": release.manifestID(branch)],
          "manifest_download": download("https://cdn.test/manifests"),
          "chunk_download": download("https://cdn.test/chunks"),
          "stats": [
            "compressed_size": String(release.compressedSize), "uncompressed_size": String(release.uncompressedSize),
            "file_count": String(release.files.count), "chunk_count": String(release.files.count),
          ],
        ]
      ],
    ]
  }

  private func patchBuildJSON(_ release: FakeRelease, branch: String, installedGuess: [String]) -> [String: Any] {
    var stats: [String: Any] = [:]
    for from in installedGuess {
      stats[from] = [
        "compressed_size": String(release.compressedSize), "uncompressed_size": String(release.uncompressedSize),
        "file_count": String(release.files.count), "chunk_count": String(release.files.count),
      ]
    }
    return [
      "build_id": "build-\(release.tag)", "patch_id": "patch-\(release.tag)", "tag": release.tag,
      "manifests": [
        [
          "category_id": "1", "matching_field": "game",
          "manifest": ["id": branch == "main" ? "diff-main" : "diff-predownload"],
          "manifest_download": download("https://cdn.test/manifests"),
          "diff_download": download("https://cdn.test/diffs"),
          "stats": stats,
        ]
      ],
    ]
  }

  /// A diff manifest in which every file of `target` is new (no patches) and `deletions` lists old files.
  private func diffManifest(_ target: FakeRelease, deletions: [String: [String: Data]]) -> Data {
    var manifest = PbDiffManifest()
    for path in target.sortedPaths {
      var file = PbDiffFileInfo()
      file.filename = path
      file.size = Int32(target.files[path]!.count)
      file.hash = md5Hex(target.files[path]!)
      manifest.files.append(file)
    }
    for version in Set(deletions.keys).union(target.diffTags) {
      var group = PbDeleteFile()
      group.key = version
      for (path, content) in (deletions[version] ?? [:]).sorted(by: { $0.key < $1.key }) {
        var info = PbDeleteFileInfo()
        info.filename = path
        info.size = Int64(content.count)
        info.hash = md5Hex(content)
        group.info.list.append(info)
      }
      manifest.filesDelete.append(group)
    }
    return zstdRawFrame(try! manifest.serializedData())
  }
}
