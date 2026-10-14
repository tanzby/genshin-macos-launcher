import Foundation
import Launcher
import Sophon
import Testing

@testable import GenshinCN

// What GenshinCNClient makes of Sophon's answers: GameStatus, JobProgress and the launcher's errors. The job
// workflows themselves (order, ldiff or full, pre-download) are tested through SophonClient in SophonTests.
// Rule IDs refer to docs/parity/hk4e-cn.md.

@Suite struct ClientStatusMappingTests {
  @Test func PRE_001_aStatusCarriesTheVersionsAndTheOffersOfSophon() async throws {
    let rig = ClientRig(branches: ClientRig.branches(main: "5.6.0", pre: "5.7.0", preFrom: ["5.6.0"]))
    rig.install("5.6.0")

    let status = try await rig.client.status(in: rig.game)

    #expect(
      status
        == GameStatus(
          localVersion: "5.6.0", remoteVersion: "5.6.0", canUpdate: false, canPreDownload: true,
          preDownloadVersion: "5.7.0"))
  }

  @Test func UPG_001_anOlderInstallIsOfferedTheUpdate() async throws {
    let rig = ClientRig(branches: ClientRig.branches(main: "5.6.0", diffTags: ["5.5.0"]))
    rig.install("5.5.0")

    let status = try await rig.client.status(in: rig.game)

    #expect(status.localVersion == "5.5.0" && status.canUpdate)
  }

  @Test func INS_012_offlineKeepsTheLocalVersionAndLeavesTheRemoteVersionEmpty() async throws {
    let rig = ClientRig()
    rig.install("5.5.0")

    let status = try await rig.client.status(in: rig.game)

    #expect(status == GameStatus(localVersion: "5.5.0"))
  }

  @Test func UPG_005_aBrokenInstallationIsReportedNotTakenForNoInstall() async throws {
    let rig = ClientRig(branches: ClientRig.branches(main: "5.6.0"))
    rig.install("5.5.0")
    rig.write("YuanShen_Data/Plugins/PCGameSDK.dll", Data("sdk".utf8))

    await #expect(throws: GameClientError.brokenInstallation) { try await rig.client.status(in: rig.game) }
  }
}

@Suite struct ClientJobMappingTests {
  @Test func ADR0002_sophonJobsAndProgressMapOneToOne() {
    #expect([GameJob.install, .update, .preDownload, .repair].map { GenshinCNClient.sophonJob($0) } == [.install, .update, .preDownload, .repair])
    #expect(GenshinCNClient.jobProgress(.preparing) == .preparing)
    #expect(GenshinCNClient.jobProgress(.downloading(done: 1, total: 2)) == .running(done: 1, total: 2))
    #expect(GenshinCNClient.jobProgress(.verifying(done: 3, total: 4)) == .running(done: 3, total: 4))
    #expect(GenshinCNClient.jobProgress(.patching(done: 5, total: 6)) == .running(done: 5, total: 6))
    #expect(GenshinCNClient.jobProgress(.finalizing) == .finalizing)
  }

  @Test func INS_005_aRefusedInstallReachesTheLauncherAsItsOwnError() async throws {
    let rig = ClientRig()
    rig.install("5.5.0")

    var failure: (any Error)?
    do { for try await _ in rig.client.run(.install, in: rig.game) {} } catch { failure = error }
    #expect(failure as? GameClientError == .installDirectoryNotEmpty)
    await #expect(throws: GameClientError.installDirectoryNotEmpty) {
      _ = try await rig.client.requiredDiskSpace(for: .install, in: rig.game)
    }
  }

  @Test func UPG_005_updateOfAnEmptyDirectoryIsNotInstalled() async throws {
    let rig = ClientRig()
    var failure: (any Error)?
    do { for try await _ in rig.client.run(.update, in: rig.game) {} } catch { failure = error }
    #expect(failure as? SophonError == .notInstalled)
  }

  @Test func PRG_001_aJobThatFailedBeforeAnyoneListenedStillDeliversItsError() async throws {
    let rig = ClientRig()
    let stream = rig.client.run(.update, in: rig.game)  // nothing is installed, so there is nothing to update
    await rig.client.quiesce()

    await #expect(throws: SophonError.notInstalled) {
      for try await _ in stream {}
    }
  }

  @Test func ADR0002_queuedJobsEachWorkOnTheFolderTheyWereStartedWith() async throws {
    let rig = ClientRig()
    rig.install("5.5.0")
    let empty = rig.root.appending(path: "empty", directoryHint: .isDirectory)
    let first = rig.client.run(.install, in: rig.game)  // refused: another install is there
    let second = rig.client.run(.update, in: empty)  // refused: nothing to update

    await #expect(throws: GameClientError.installDirectoryNotEmpty) { for try await _ in first {} }
    await #expect(throws: SophonError.notInstalled) { for try await _ in second {} }
  }

  @Test func LCH_014_repairAndUpdateRecoverTheSessionBeforeTheyTouchTheGame() async throws {
    let rig = ClientRig(branches: ClientRig.branches(main: "5.6.0"))
    rig.install("5.6.0")

    // Whatever the job then does with the network, the recovery came first.
    _ = try? await { for try await _ in rig.client.run(.repair, in: rig.game) {} }()
    #expect(rig.launcher.recoveries.withLock { $0 } == 1)
    _ = try? await { for try await _ in rig.client.run(.update, in: rig.game) {} }()
    #expect(rig.launcher.recoveries.withLock { $0 } == 2)
  }

  @Test func LCH_014_installAndPreDownloadLeaveTheSessionAlone() async throws {
    // The game may be running during a pre-download: recovery would shut its prefix down.
    let rig = ClientRig(branches: ClientRig.branches(main: "5.6.0", pre: "5.7.0", preFrom: ["5.6.0"]))
    rig.install("5.6.0")

    _ = try? await { for try await _ in rig.client.run(.preDownload, in: rig.game) {} }()
    _ = try? await { for try await _ in rig.client.run(.install, in: rig.game) {} }()

    #expect(rig.launcher.recoveries.withLock { $0 } == 0)
  }
}
