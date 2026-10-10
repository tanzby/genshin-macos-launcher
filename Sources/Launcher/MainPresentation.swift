import Foundation

/// The facts the main window's bottom capsule is derived from.
public struct MainSnapshot: Sendable, Equatable {
  public var phase: LauncherPhase
  public var isPreDownloading: Bool
  public var isPausing: Bool
  public var progress: JobProgress?
  public var pendingJob: PendingJob?
  public var lastError: LauncherError?
  public var status: GameStatus?
  public var isOnline: Bool
  /// The hosts blocklist is in place; without it the game must not start.
  public var hostsAllowLaunch: Bool
  /// The first status query has finished (successfully or not). Before that "offline" is not yet known.
  public var hasLoaded: Bool
  /// Wine is known to need (re)installing; nothing else can run until it is prepared.
  public var wineNotReady: Bool

  public init(
    phase: LauncherPhase, isPreDownloading: Bool, isPausing: Bool, progress: JobProgress?,
    pendingJob: PendingJob?, lastError: LauncherError?, status: GameStatus?, isOnline: Bool,
    hostsAllowLaunch: Bool, hasLoaded: Bool = true, wineNotReady: Bool = false
  ) {
    self.phase = phase
    self.isPreDownloading = isPreDownloading
    self.isPausing = isPausing
    self.progress = progress
    self.pendingJob = pendingJob
    self.lastError = lastError
    self.status = status
    self.isOnline = isOnline
    self.hostsAllowLaunch = hostsAllowLaunch
    self.hasLoaded = hasLoaded
    self.wineNotReady = wineNotReady
  }
}

/// The one accent-coloured button in the capsule (#21: the colour never changes with the state).
public enum PrimaryButton: Sendable, Equatable {
  case prepareWine, preparingWine
  case install, update, launch
  case pause, pausing, resume, retry
  case repairing, launching, running
}

/// What the capsule's status area says. The view maps each case to a localized sentence.
public enum StatusLine: Sendable, Equatable {
  case none
  case job(GameJob, JobProgress?, paused: Bool)
  case wine(JobProgress?)
  case wineRequired
  case updateAvailable(version: String?)
  case preDownloadAvailable(version: String?)
  case error(LauncherError)
  case offline
  case hostsRequired
  case launching
  case running
}

/// The state table of #21 as a pure function.
public struct MainPresentation: Sendable, Equatable {
  public var button: PrimaryButton
  public var buttonEnabled: Bool
  public var status: StatusLine
  /// "Check file integrity" is offered only for an installed, current game while nothing exclusive runs.
  public var canRepair: Bool
  /// The "Pre-download" button is offered (also next to an error, so a failed pre-download can be retried).
  public var canPreDownload: Bool

  public static func derive(_ s: MainSnapshot) -> MainPresentation {
    let installed = s.status?.localVersion != nil
    let idleLike = s.phase == .idle || s.phase == .preDownloading
    // Pre-download may overlap with launching and running (APP-015), but not with install/update/repair.
    let preDownloadPhase = idleLike || s.phase == .launching || s.phase == .running
    let noBlockingJob = s.pendingJob.map { $0.kind == .preDownload } ?? true
    let repairable = installed && idleLike && noBlockingJob && !s.wineNotReady && s.status?.canUpdate != true

    func make(_ button: PrimaryButton, _ enabled: Bool, _ status: StatusLine) -> MainPresentation {
      MainPresentation(
        button: button, buttonEnabled: enabled, status: status, canRepair: repairable,
        canPreDownload: installed && s.isOnline && preDownloadPhase && !s.isPreDownloading
          && s.status?.canPreDownload == true)
    }

    switch s.phase {
    case .preparingWine: return make(.preparingWine, false, .wine(s.progress))
    case .running: return make(.running, false, .running)
    case .launching: return make(.launching, false, .launching)
    case .installing, .updating:
      let job: GameJob = s.phase == .installing ? .install : .update
      return make(s.isPausing ? .pausing : .pause, !s.isPausing, .job(job, s.progress, paused: false))
    case .repairing:
      return make(.repairing, false, .job(.repair, s.progress, paused: false))
    case .idle, .preDownloading:
      break
    }

    if s.wineNotReady {
      return make(.prepareWine, true, s.lastError.map { .error($0) } ?? .wineRequired)
    }

    if let pending = s.pendingJob, pending.kind != .preDownload {
      if let error = s.lastError { return make(.retry, true, .error(error)) }
      return make(.resume, true, .job(pending.kind, nil, paused: true))
    }

    let base = PrimaryAction.derive(s.status)
    let button: PrimaryButton =
      switch base {
      case .install: .install
      case .update: .update
      default: .launch
      }
    let enabled = base == .install ? s.isOnline : s.isOnline && (base != .launch || s.hostsAllowLaunch)

    let status: StatusLine
    if let error = s.lastError {
      status = .error(error)
    } else if base == .launch && !s.hostsAllowLaunch {
      status = .hostsRequired
    } else if s.hasLoaded && !s.isOnline {
      status = .offline
    } else if s.isPreDownloading {
      status = .job(.preDownload, s.progress, paused: false)
    } else if s.status?.canPreDownload == true {
      status = .preDownloadAvailable(version: s.status?.preDownloadVersion)
    } else if base == .update {
      status = .updateAvailable(version: s.status?.remoteVersion)
    } else {
      status = .none
    }
    return make(button, enabled, status)
  }
}

extension JobProgress {
  /// nil = indeterminate: no total yet, or a real 0 % (PRG-005 shows both the same way).
  public var fraction: Double? {
    guard let counts, counts.total > 0, counts.done > 0 else { return nil }
    return min(1, Double(counts.done) / Double(counts.total))
  }

  /// Bytes done and total, for the steps that move bytes (game download, Wine/DXMT download).
  public var counts: (done: Int64, total: Int64)? {
    switch self {
    case .running(let done, let total): (done, total)
    case .wine(.downloadingWine(let p)), .wine(.downloadingDXMT(let p)): (p.completed, p.total)
    default: nil
    }
  }
}

/// Speed over a sliding time window, fed with `(bytes done, time)` samples (PRG-002). The caller passes
/// the clock reading, so tests are deterministic.
public struct TransferEstimator: Sendable {
  private let window: TimeInterval
  private var samples: [(done: Int64, time: TimeInterval)] = []

  public init(window: TimeInterval = 10) {
    self.window = window
  }

  public mutating func record(done: Int64, at time: TimeInterval) {
    // A counter that goes backwards means a new phase started: measure it afresh.
    if let last = samples.last, done < last.done { samples.removeAll() }
    samples.append((done, time))
    let cutoff = time - window
    let recent = samples.filter { $0.time >= cutoff }
    // After a stall fewer than two samples are recent: keep the last two so the speed still reads (as ~0).
    samples = recent.count >= 2 ? recent : Array(samples.suffix(2))
  }

  public var bytesPerSecond: Double? {
    guard let first = samples.first, let last = samples.last, last.time > first.time else { return nil }
    return Double(last.done - first.done) / (last.time - first.time)
  }

  public func remaining(done: Int64, total: Int64) -> TimeInterval? {
    guard total > done, let speed = bytesPerSecond, speed > 0 else { return nil }
    return Double(total - done) / speed
  }
}

public enum ByteFormat {
  private static let units = ["B", "KiB", "MiB", "GiB", "TiB"]

  /// IEC units, one decimal; values that round up to 1024 carry into the next unit (PRG-004).
  public static func iec(_ bytes: Int64) -> String {
    var value = Double(max(0, bytes))
    var unit = 0
    while value >= 1024, unit < units.count - 1 {
      value /= 1024
      unit += 1
    }
    if unit == 0 { return "\(max(0, bytes)) B" }
    var rounded = (value * 10).rounded() / 10
    if rounded >= 1024, unit < units.count - 1 {
      rounded = (rounded / 1024 * 10).rounded() / 10
      unit += 1
    }
    return String(format: "%.1f %@", rounded, units[unit])
  }

  /// Whole GiB, rounded up, for "need N GB more" (#28 A4 shows integers).
  public static func wholeGiBRoundedUp(_ bytes: Int64) -> Int64 {
    guard bytes > 0 else { return 0 }
    return (bytes + (1 << 30) - 1) >> 30
  }
}
