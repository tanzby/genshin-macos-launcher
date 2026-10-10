import CryptoKit
import Foundation
import ImageIO
import Launcher

/// Fetches the official launcher background (APP-021) and keeps one copy in the data directory.
/// Never throws: any failure yields the last cached image, or `.bundledDefault` when there is none.
/// The static image only; the video the same entry carries is not played (old repo #30).
public struct BackgroundImageProvider: Sendable {
  public static let infoURL = URL(
    string: "https://hyp-api.mihoyo.com/hyp/hyp-connect/api/getAllGameBasicInfo")!
  static let biz = "hk4e_cn"
  static let launcherID = "jGHBHlcOq1"
  static let language = "zh-cn"
  static let requestTimeout: TimeInterval = 15

  let cacheDirectory: URL
  let session: URLSession
  private var fileManager: FileManager { .default }

  /// `cacheDirectory` holds at most one image; it is created on first download.
  public init(cacheDirectory: URL, session: URLSession = .shared) {
    self.cacheDirectory = cacheDirectory
    self.session = session
  }

  public func backgroundImage() async -> BackgroundImage {
    if let remote = try? await officialImageURL() {
      let cached = cacheFile(for: remote)
      if fileManager.fileExists(atPath: cached.path) { return .remote(cached) }
      if let downloaded = try? await download(remote, to: cached) { return .remote(downloaded) }
    }
    return newestCachedFile().map { .remote(cacheDirectory.appending(path: $0.lastPathComponent)) }
      ?? .bundledDefault
  }

  // MARK: - hyp-connect

  private struct Envelope: Decodable {
    struct Info: Decodable {
      struct Game: Decodable { var biz: String }
      struct Background: Decodable {
        struct Picture: Decodable { var url: String }
        var background: Picture?
        var type: String?
      }
      var game: Game
      var backgrounds: [Background]?
    }
    struct Payload: Decodable { var game_info_list: [Info] }
    var retcode: Int
    var data: Payload?
  }

  /// The static image of the hk4e_cn entry, preferring the video-type entry as the old launcher did.
  private func officialImageURL() async throws -> URL {
    var components = URLComponents(url: Self.infoURL, resolvingAgainstBaseURL: false)!
    components.queryItems = [
      URLQueryItem(name: "launcher_id", value: Self.launcherID),
      URLQueryItem(name: "language", value: Self.language),
    ]
    var request = URLRequest(url: components.url!)
    request.timeoutInterval = Self.requestTimeout
    let (body, response) = try await session.data(for: request)
    guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
    let envelope = try JSONDecoder().decode(Envelope.self, from: body)
    guard envelope.retcode == 0,
      let game = envelope.data?.game_info_list.first(where: { $0.game.biz == Self.biz })
    else { throw URLError(.cannotParseResponse) }
    let candidates = (game.backgrounds ?? []).filter { !($0.background?.url ?? "").isEmpty }
    let pick = candidates.first { $0.type == "BACKGROUND_TYPE_VIDEO" } ?? candidates.first
    guard let string = pick?.background?.url, let url = URL(string: string), url.scheme == "https"
    else { throw URLError(.cannotParseResponse) }
    return url
  }

  // MARK: - Cache

  /// The URL carries a content hash upstream, so hashing it makes a changed image a different file.
  private func cacheFile(for remote: URL) -> URL {
    let digest = SHA256.hash(data: Data(remote.absoluteString.utf8))
    let name = digest.prefix(16).map { String(format: "%02x", $0) }.joined()
    let ext = remote.pathExtension
    return cacheDirectory.appending(path: ext.isEmpty ? name : "\(name).\(ext)")
  }

  /// Writes only after the bytes decode as an image, then drops every older entry.
  private func download(_ remote: URL, to destination: URL) async throws -> URL {
    var request = URLRequest(url: remote)
    request.timeoutInterval = Self.requestTimeout
    let (body, response) = try await session.data(for: request)
    guard (response as? HTTPURLResponse)?.statusCode == 200,
      let source = CGImageSourceCreateWithData(body as CFData, nil),
      CGImageSourceGetCount(source) > 0
    else { throw URLError(.cannotDecodeContentData) }
    try fileManager.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
    try body.write(to: destination, options: .atomic)
    for stale in cachedFiles() where stale.lastPathComponent != destination.lastPathComponent {
      try? fileManager.removeItem(at: stale)
    }
    return destination
  }

  private func cachedFiles() -> [URL] {
    (try? fileManager.contentsOfDirectory(
      at: cacheDirectory, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
  }

  private func newestCachedFile() -> URL? {
    cachedFiles().max { lhs, rhs in
      let left = (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]))?
        .contentModificationDate ?? .distantPast
      let right = (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]))?
        .contentModificationDate ?? .distantPast
      return left < right
    }
  }
}
