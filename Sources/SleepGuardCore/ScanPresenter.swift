import Foundation

/// The typed outcome of one scan attempt.
///
/// A scan can fail *after* reading part of the system state, so failure is not
/// simply "no data": `SleepGuardCore` already models partial reads as an
/// incomplete report rather than a clean one. This enum keeps the two phases
/// distinct so the UI cannot present a read failure as an empty, healthy scan.
public enum ScanOutcome: Sendable {
  case success(SleepScanReport)
  /// The scan could not be completed. The message is a diagnostic string, never
  /// an implied clean result.
  case failure(String)
}

/// Presentation state for one scan surface, deliberately free of SwiftUI and
/// IOKit so every state transition is deterministically testable.
///
/// ## Why generation tokens
///
/// Scans are asynchronous and the user can refresh while one is in flight.
/// Completions can therefore arrive out of order. Publishing whichever
/// completion happens to land last would show stale evidence with no signal
/// that it is stale. Every scan gets a monotonically increasing token; a
/// completion publishes only if its token is still the current generation, and
/// a superseded completion is discarded — including its busy flag, so a stale
/// completion cannot make an in-flight scan look finished.
///
/// This type is not `Sendable`: it is main-actor UI state, and marking it
/// `Sendable` for appearance would be a false concurrency claim.
public final class ScanPresenter {
  /// Monotonic generation counter. `0` means no scan has ever started.
  private var currentToken: UInt64 = 0
  private var activeToken: UInt64?

  public private(set) var rows: [BlockerRow] = []
  public private(set) var report: SleepScanReport?
  /// When the currently published result was observed.
  ///
  /// Power-assertion state changes second to second, so a result redisplayed
  /// later must be attributable to when it was actually read. Cleared with the
  /// rest of the state when a new scan starts, so a stale timestamp cannot
  /// outlive the result it described.
  public private(set) var lastScanDate: Date?
  /// Terminal notice for the most recent *published* outcome.
  ///
  /// Kept separate from `rows` because a scan can legitimately end with zero
  /// rows, and "no blockers found" must be distinguishable from "the scan
  /// failed" and from "no scan has run yet".
  public private(set) var notice: String?

  public init() {}

  public var isScanning: Bool { activeToken != nil }

  /// Starts a new generation and returns its token. Calling this while a scan
  /// is active supersedes the previous generation rather than queuing or
  /// duplicating work, which is what makes a refresh button harmless.
  ///
  /// Starting a scan also clears the previous result. Rows from a finished scan
  /// must not stay on screen as current evidence: the holder they name may
  /// already have exited, and a verdict from the previous scan no longer
  /// describes the system.
  @discardableResult
  public func beginScan() -> UInt64 {
    currentToken += 1
    activeToken = currentToken
    rows = []
    report = nil
    notice = nil
    lastScanDate = nil
    return currentToken
  }

  /// Publishes an outcome only if `token` is still the **in-flight**
  /// generation. Returns whether the outcome was accepted, so callers can be
  /// tested.
  ///
  /// The comparison is against `activeToken`, not `currentToken`. Comparing
  /// against the last *issued* token was a real fail-open found in review: on a
  /// fresh presenter both counters were 0, so a caller passing a zero or
  /// default token published an affirmative clean verdict with no scan having
  /// run at all. Matching the in-flight generation instead makes two things
  /// impossible: publishing without an active scan, and publishing twice for
  /// one generation (a duplicated callback cannot resurrect a superseded
  /// scan's state), because `activeToken` is cleared on acceptance.
  @discardableResult
  public func publish(
    _ outcome: ScanOutcome, token: UInt64, observedAt: Date = Date()
  ) -> Bool {
    guard token == activeToken else { return false }
    activeToken = nil
    lastScanDate = observedAt
    switch outcome {
    case .success(let report):
      self.report = report
      self.rows = report.blockerRows
      self.notice = Self.notice(for: report)
    case .failure(let message):
      self.report = nil
      self.rows = []
      self.notice = "Scan failed: \(message). No conclusion about sleep can be drawn."
    }
    return true
  }

  /// Terminal notice text, derived from the core's tri-state verdict.
  ///
  /// The three cases are kept genuinely distinct. `nil` from
  /// `systemSleepIsBlocked` means the scan could not determine the answer, and
  /// it is never rendered as a clean result.
  static func notice(for report: SleepScanReport) -> String {
    switch report.diagnosis.systemSleepIsBlocked(
      aggregate: report.aggregate, driver: report.driver)
    {
    case .some(true):
      return "Sleep is being blocked."
    case .some(false):
      return "Nothing found blocking sleep."
    case nil:
      return
        "Could not determine whether sleep is blocked; part of the system state was unreadable or of unknown effect."
    }
  }
}
