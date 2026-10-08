import Foundation

/// A game branch from `getGameBranches`. The password is a server-issued download credential:
/// it stays internal and is left out of every description.
public struct SophonGameBranch: Sendable, Equatable, Decodable {
  public let branch: String
  public let packageID: String
  public let tag: String
  /// Older versions that can be upgraded to `tag` with ldiff patches.
  public let diffTags: [String]
  public let categories: [SophonCategory]
  let password: String

  enum CodingKeys: String, CodingKey {
    case branch, password, tag, categories
    case packageID = "package_id"
    case diffTags = "diff_tags"
  }

  public init(from decoder: any Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    branch = try c.decode(String.self, forKey: .branch)
    password = try c.decode(String.self, forKey: .password)
    packageID = try c.decode(String.self, forKey: .packageID)
    tag = try c.decode(String.self, forKey: .tag)
    diffTags = try c.decodeIfPresent([String].self, forKey: .diffTags) ?? []
    categories = try c.decodeIfPresent([SophonCategory].self, forKey: .categories) ?? []
  }
}

extension SophonGameBranch: CustomStringConvertible, CustomDebugStringConvertible {
  public var description: String { "SophonGameBranch(\(branch) \(tag), package \(packageID))" }
  public var debugDescription: String { description }
}

public struct SophonCategory: Sendable, Equatable, Decodable {
  public let categoryID: String
  public let matchingField: String

  enum CodingKeys: String, CodingKey {
    case categoryID = "category_id"
    case matchingField = "matching_field"
  }
}

/// `main` is the current release; `preDownload` is `nil` when the server has no pre-download.
public struct SophonGameBranches: Sendable, Equatable {
  public let main: SophonGameBranch?
  public let preDownload: SophonGameBranch?

  static func decode(_ data: Data) throws -> SophonGameBranches {
    struct Payload: Decodable {
      struct Entry: Decodable {
        let main: SophonGameBranch?
        let preDownload: SophonGameBranch?
        enum CodingKeys: String, CodingKey {
          case main
          case preDownload = "pre_download"
        }
      }
      let gameBranches: [Entry]
      enum CodingKeys: String, CodingKey { case gameBranches = "game_branches" }
    }
    let payload: Payload = try SophonEnvelope.decode(data)
    guard let entry = payload.gameBranches.first else { throw SophonError.malformedResponse }
    return SophonGameBranches(main: entry.main, preDownload: entry.preDownload)
  }
}

/// Download size figures. The server sends numbers as strings.
public struct SophonStats: Sendable, Equatable, Decodable {
  public let compressedSize: Int64
  public let uncompressedSize: Int64
  public let fileCount: Int64
  public let chunkCount: Int64

  enum CodingKeys: String, CodingKey {
    case compressedSize = "compressed_size"
    case uncompressedSize = "uncompressed_size"
    case fileCount = "file_count"
    case chunkCount = "chunk_count"
  }

  public init(from decoder: any Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    compressedSize = try c.decodeFlexibleInt64(forKey: .compressedSize)
    uncompressedSize = try c.decodeFlexibleInt64(forKey: .uncompressedSize)
    fileCount = try c.decodeFlexibleInt64(forKey: .fileCount)
    chunkCount = try c.decodeFlexibleInt64(forKey: .chunkCount)
  }
}

extension KeyedDecodingContainer {
  /// Decodes an integer that may arrive as a JSON number or as a decimal string.
  fileprivate func decodeFlexibleInt64(forKey key: Key) throws -> Int64 {
    if let value = try? decode(Int64.self, forKey: key) { return value }
    let text = try decode(String.self, forKey: key)
    guard let value = Int64(text) else {
      throw DecodingError.dataCorruptedError(forKey: key, in: self, debugDescription: "not an integer")
    }
    return value
  }
}

/// One downloadable category (the game itself or a voice pack) inside a build.
public struct SophonManifestRef: Sendable, Equatable, Decodable {
  public let categoryID: String
  public let matchingField: String
  public let manifestID: String
  public let manifestURLPrefix: String
  public let manifestURLSuffix: String
  /// Where chunks are downloaded from (`getBuild` only).
  public let chunkURLPrefix: String?
  /// Appended after the chunk id (empty today).
  public let chunkURLSuffix: String
  /// Where ldiff files are downloaded from (`getPatchBuild` only).
  public let diffURLPrefix: String?
  /// Appended after the ldiff id (empty today).
  public let diffURLSuffix: String
  /// Totals for a full install (`getBuild`); `nil` for patch builds.
  public let stats: SophonStats?
  /// Totals per old version (`getPatchBuild`); empty for plain builds.
  public let patchStats: [String: SophonStats]

  public init(
    categoryID: String, matchingField: String, manifestID: String, manifestURLPrefix: String,
    manifestURLSuffix: String = "", chunkURLPrefix: String? = nil, chunkURLSuffix: String = "",
    diffURLPrefix: String? = nil, diffURLSuffix: String = "",
    stats: SophonStats? = nil, patchStats: [String: SophonStats] = [:]
  ) {
    self.categoryID = categoryID
    self.matchingField = matchingField
    self.manifestID = manifestID
    self.manifestURLPrefix = manifestURLPrefix
    self.manifestURLSuffix = manifestURLSuffix
    self.chunkURLPrefix = chunkURLPrefix
    self.chunkURLSuffix = chunkURLSuffix
    self.diffURLPrefix = diffURLPrefix
    self.diffURLSuffix = diffURLSuffix
    self.stats = stats
    self.patchStats = patchStats
  }

  private struct Manifest: Decodable { let id: String }
  private struct Download: Decodable {
    let urlPrefix: String
    let urlSuffix: String?
    enum CodingKeys: String, CodingKey {
      case urlPrefix = "url_prefix"
      case urlSuffix = "url_suffix"
    }
  }

  enum CodingKeys: String, CodingKey {
    case categoryID = "category_id"
    case matchingField = "matching_field"
    case manifest, stats
    case manifestDownload = "manifest_download"
    case chunkDownload = "chunk_download"
    case diffDownload = "diff_download"
  }

  public init(from decoder: any Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    categoryID = try c.decode(String.self, forKey: .categoryID)
    matchingField = try c.decode(String.self, forKey: .matchingField)
    manifestID = try c.decode(Manifest.self, forKey: .manifest).id
    let manifestDownload = try c.decode(Download.self, forKey: .manifestDownload)
    manifestURLPrefix = manifestDownload.urlPrefix
    manifestURLSuffix = manifestDownload.urlSuffix ?? ""
    let chunk = try c.decodeIfPresent(Download.self, forKey: .chunkDownload)
    chunkURLPrefix = chunk?.urlPrefix
    chunkURLSuffix = chunk?.urlSuffix ?? ""
    let diff = try c.decodeIfPresent(Download.self, forKey: .diffDownload)
    diffURLPrefix = diff?.urlPrefix
    diffURLSuffix = diff?.urlSuffix ?? ""
    // `stats` is flat in getBuild and keyed by old version in getPatchBuild.
    if !c.contains(.stats) {
      stats = nil
      patchStats = [:]
    } else if let flat = try? c.decode(SophonStats.self, forKey: .stats) {
      stats = flat
      patchStats = [:]
    } else {
      stats = nil
      patchStats = try c.decode([String: SophonStats].self, forKey: .stats)
    }
  }

  /// Picks the category for `field`: exact match first, then a single substring match.
  static func select(_ refs: [SophonManifestRef], matching field: String) throws -> SophonManifestRef {
    if let exact = refs.first(where: { $0.matchingField == field }) { return exact }
    // The "main" category is never fuzzy-matched, and neither is an empty name.
    guard field != "main", !field.isEmpty else { throw SophonError.noMatchingCategory(field) }
    let fuzzy = refs.filter { $0.matchingField.contains(field) }
    switch fuzzy.count {
    case 0: throw SophonError.noMatchingCategory(field)
    case 1: return fuzzy[0]
    default: throw SophonError.ambiguousCategory(field)
    }
  }
}

/// `getBuild`: chunk download locations for a full install or repair.
public struct SophonBuild: Sendable, Equatable {
  public let buildID: String
  public let tag: String
  public let manifests: [SophonManifestRef]

  public func manifest(matching field: String) throws -> SophonManifestRef {
    try SophonManifestRef.select(manifests, matching: field)
  }

  static func decode(_ data: Data) throws -> SophonBuild {
    struct Payload: Decodable {
      let buildID: String
      let tag: String
      let manifests: [SophonManifestRef]
      enum CodingKeys: String, CodingKey {
        case buildID = "build_id"
        case tag, manifests
      }
    }
    let payload: Payload = try SophonEnvelope.decode(data)
    return SophonBuild(buildID: payload.buildID, tag: payload.tag, manifests: payload.manifests)
  }
}

/// `getPatchBuild`: ldiff download locations for an incremental update or pre-download.
public struct SophonPatchBuild: Sendable, Equatable {
  public let buildID: String
  public let patchID: String
  public let tag: String
  public let manifests: [SophonManifestRef]

  public func manifest(matching field: String) throws -> SophonManifestRef {
    try SophonManifestRef.select(manifests, matching: field)
  }

  static func decode(_ data: Data) throws -> SophonPatchBuild {
    struct Payload: Decodable {
      let buildID: String
      let patchID: String
      let tag: String
      let manifests: [SophonManifestRef]
      enum CodingKeys: String, CodingKey {
        case buildID = "build_id"
        case patchID = "patch_id"
        case tag, manifests
      }
    }
    let payload: Payload = try SophonEnvelope.decode(data)
    return SophonPatchBuild(
      buildID: payload.buildID, patchID: payload.patchID, tag: payload.tag,
      manifests: payload.manifests)
  }
}

/// The `{retcode, message, data}` wrapper around every API response.
enum SophonEnvelope {
  private struct Status: Decodable {
    let retcode: Int
    let message: String?
  }

  private struct Wrapper<T: Decodable>: Decodable {
    let retcode: Int
    let message: String?
    let data: T?
  }

  static func decode<T: Decodable>(_ body: Data) throws -> T {
    let wrapper: Wrapper<T>
    do {
      wrapper = try JSONDecoder().decode(Wrapper<T>.self, from: body)
    } catch {
      // A failure envelope may carry `data: null` or a different shape; report the retcode if we can.
      if let status = try? JSONDecoder().decode(Status.self, from: body), status.retcode != 0 {
        throw SophonError.api(retcode: status.retcode, message: status.message ?? "")
      }
      throw SophonError.malformedResponse
    }
    guard wrapper.retcode == 0 else {
      throw SophonError.api(retcode: wrapper.retcode, message: wrapper.message ?? "")
    }
    guard let data = wrapper.data else { throw SophonError.malformedResponse }
    return data
  }
}
