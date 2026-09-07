import Foundation

/// A single observed power assertion. This is an *observation*: the owning PID
/// may exit or be reused at any time, so nothing here is treated as a live handle.
public struct AssertionObservation: Equatable, Sendable {
  public let assertionID: UInt64
  public let pid: Int32
  public let processName: String
  public let rawType: String
  public let humanName: String
  /// Nil when the source record carried no usable start timestamp. Unknown
  /// duration is reported as unknown, never fabricated as zero.
  public let heldSeconds: Int?

  public init(
    assertionID: UInt64,
    pid: Int32,
    processName: String,
    rawType: String,
    humanName: String,
    heldSeconds: Int?
  ) {
    self.assertionID = assertionID
    self.pid = pid
    self.processName = processName
    self.rawType = rawType
    self.humanName = humanName
    self.heldSeconds = heldSeconds
  }
}

/// Read-only interpretation of observed assertions. This type never terminates,
/// signals, or otherwise mutates anything; it only explains why sleep is blocked.
public struct SleepDiagnosis: Sendable {
  public let observations: [AssertionObservation]
  /// Tri-state: `nil` means the standing `SleepDisabled` setting could not be
  /// read. "I could not find out" is never collapsed into "sleep is enabled".
  public let sleepDisabledSetting: Bool?
  /// Whether the snapshot these observations came from decoded completely.
  ///
  /// This is a required initializer parameter, not an optional convenience: the
  /// fail-closed promise must be enforced by the library type itself. A
  /// consumer that links `SleepGuardCore` and drops the decoder's completeness
  /// flags on the floor would otherwise get a provably-clean verdict from a
  /// snapshot full of undecodable records.
  public let sourceWasComplete: Bool

  /// Assertion types documented in IOPMLib.h as preventing system idle sleep.
  ///
  /// `PreventUserIdleDisplaySleep` is included deliberately: IOPMLib.h states
  /// "While the display is prevented from dimming, the system cannot go into
  /// idle sleep." `NetworkClientActive` likewise: "Keeps the system awake while
  /// OS X serves active network clients... On battery, this assertion can
  /// prevent system from going into idle sleep."
  static let systemSleepBlockingTypes: Set<String> = [
    "NoIdleSleepAssertion",
    "PreventUserIdleSystemSleep",
    "PreventSystemSleep",
    "PreventUserIdleDisplaySleep",
    "NetworkClientActive",
  ]

  /// Assertion types with a citable IOPMLib.h statement that they do NOT prevent
  /// system idle sleep on their own.
  ///
  /// Membership requires an explicit header citation. A type that merely looks
  /// harmless, or whose name suggests it, is left unclassified instead — the
  /// tool must never certify a blocker as harmless on an unsourced guess.
  ///
  /// `PreventDiskIdle`: "The system may still sleep while this assertion is
  /// active."
  static let knownNonBlockingTypes: Set<String> = [
    "PreventDiskIdle"
  ]

  /// Every caller must state whether the source snapshot was complete. There is
  /// deliberately no default value: silently defaulting to `true` is exactly the
  /// fail-open path this parameter exists to close.
  public init(
    observations: [AssertionObservation],
    sleepDisabledSetting: Bool?,
    sourceWasComplete: Bool
  ) {
    self.observations = observations
    self.sleepDisabledSetting = sleepDisabledSetting
    self.sourceWasComplete = sourceWasComplete
  }

  /// Convenience initializer that takes completeness straight from the decoder,
  /// so the two cannot drift apart.
  public init(snapshot: DecodedAssertions, sleepDisabledSetting: Bool?) {
    self.init(
      observations: snapshot.observations,
      sleepDisabledSetting: sleepDisabledSetting,
      sourceWasComplete: snapshot.isComplete)
  }

  public var systemSleepBlockers: [AssertionObservation] {
    observations.filter { Self.systemSleepBlockingTypes.contains($0.rawType) }
  }

  /// Assertions whose type this build does not recognize. An unknown type is
  /// *not* assumed harmless; it makes the answer uncertain instead.
  public var unclassifiedAssertions: [AssertionObservation] {
    observations.filter {
      !Self.systemSleepBlockingTypes.contains($0.rawType)
        && !Self.knownNonBlockingTypes.contains($0.rawType)
    }
  }

  /// Tri-state verdict. `nil` means "cannot determine": no confirmed blocker was
  /// found, but something could not be read, so the absence of a blocker is not
  /// provable. Never collapses unknown into "not blocked".
  ///
  /// A confirmed blocker is decisive even on an incomplete scan — finding *more*
  /// evidence could never turn a real blocker into a clean result.
  public var systemSleepIsBlocked: Bool? {
    if !systemSleepBlockers.isEmpty { return true }
    if sleepDisabledSetting == true { return true }
    if sleepDisabledSetting == nil { return nil }
    if !sourceWasComplete { return nil }
    if !unclassifiedAssertions.isEmpty { return nil }
    return false
  }

  /// True only when a clean result is actually provable: the source snapshot
  /// decoded completely, no blockers, no unclassified assertions, and the
  /// standing setting was successfully read.
  public var canProveSleepIsUnblocked: Bool {
    sourceWasComplete && sleepDisabledSetting == false && systemSleepBlockers.isEmpty
      && unclassifiedAssertions.isEmpty
  }
}
