import Foundation
import Launcher

public enum GenshinCN {
  public static let channel = "hk4ecn"
  public static let executableName = "YuanShen.exe"
}

public enum GenshinCNClientError: Error, Sendable, Equatable {
  case notImplemented
}

/// Composes Sophon, Wine and Platform into a `GameClient`. Implementation lands with the module tickets.
public struct GenshinCNClient: GameClient {
  public init() {}

  public func status() async throws -> GameStatus {
    throw GenshinCNClientError.notImplemented
  }

  public func run(_ job: GameJob) -> AsyncThrowingStream<JobProgress, Error> {
    AsyncThrowingStream { $0.finish(throwing: GenshinCNClientError.notImplemented) }
  }

  public func launch(_ options: LaunchOptions) async throws -> LaunchOutcome {
    throw GenshinCNClientError.notImplemented
  }

  public func backgroundImage() async -> BackgroundImage {
    .bundledDefault
  }
}
