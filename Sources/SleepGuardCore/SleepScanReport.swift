import Foundation

/// One row of the user-facing scan result.
///
/// `id` is a **stable synthetic identity**, not a display name and not a bare
/// PID. Two distinct processes can publish an identical process name and an
/// identical human-readable reason, and a PID can be reused after the owning
/// process exits, so neither is usable on its own as a UI identity. Keying UI
/// state on a display name lets one row's evidence appear under another row's
/// heading; that is the specific defect this type exists to prevent.
///
/// This identity is deliberately only meaningful *within* one scan. It is not a
/// live handle and must never be used to act on a process: any action would
/// have to re-resolve the target and compare identity first. This build takes
/// no actions at all.
public struct BlockerRow: Equatable, Identifiable, Sendable {
  public let id: String
  public let title: String
  public let detail: String
  public let pid: Int32
  public let rawType: String
  /// Nil means the source record carried no usable timestamp. Unknown duration
  /// stays unknown rather than being rendered as `0s`.
  public let heldSeconds: Int?

  public init(
    id: String,
    title: String,
    detail: String,
    pid: Int32,
    rawType: String,
    heldSeconds: Int?
  ) {
    self.id = id
    self.title = title
    self.detail = detail
    self.pid = pid
    self.rawType = rawType
    self.heldSeconds = heldSeconds
  }
}

/// A read-only, presentation-ready view over one completed scan.
///
/// Holding the three views together is not a convenience: `SleepGuardCore`
/// deliberately makes a clean verdict a *function* of all three, so a
/// presentation layer that stored only the process diagnosis could render
/// "nothing is blocking sleep" while a kernel driver held a documented
/// idle-sleep assertion.
public struct SleepScanReport: Sendable {
  public let diagnosis: SleepDiagnosis
  public let aggregate: AggregateAssertionStatus
  public let driver: DriverAssertionStatus

  public init(
    diagnosis: SleepDiagnosis,
    aggregate: AggregateAssertionStatus,
    driver: DriverAssertionStatus
  ) {
    self.diagnosis = diagnosis
    self.aggregate = aggregate
    self.driver = driver
  }

  /// Process-held sleep blockers, one row per observed holder.
  public var blockerRows: [BlockerRow] {
    diagnosis.systemSleepBlockers.map { observation in
      BlockerRow(
        id: "process:\(observation.pid):\(observation.assertionID)",
        title: observation.processName,
        detail: observation.humanName,
        pid: observation.pid,
        rawType: observation.rawType,
        heldSeconds: observation.heldSeconds)
    }
  }
}
