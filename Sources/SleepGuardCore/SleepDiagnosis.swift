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

  /// Assertion types documented in IOPMLib.h as preventing system idle sleep.
  ///
  /// `PreventUserIdleDisplaySleep` is included deliberately: IOPMLib.h states
  /// "While the display is prevented from dimming, the system cannot go into
  /// idle sleep." It blocks idle sleep just as surely as the system types do.
  static let systemSleepBlockingTypes: Set<String> = [
    "NoIdleSleepAssertion",
    "PreventUserIdleSystemSleep",
    "PreventSystemSleep",
    "PreventUserIdleDisplaySleep",
    "InternalPreventSleep",
    "InternalPreventDisplaySleep",
  ]

  /// Assertion types known NOT to prevent system idle sleep on their own.
  static let knownNonBlockingTypes: Set<String> = [
    "PreventDiskIdle",
    "UserIsActive",
    "NetworkClientActive",
    "BackgroundTask",
    "ApplePushServiceTask",
    "ExternalMedia",
    "EnableIdleSleep",
    "DenySystemSleep",
  ]

  public init(observations: [AssertionObservation], sleepDisabledSetting: Bool?) {
    self.observations = observations
    self.sleepDisabledSetting = sleepDisabledSetting
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

  public var systemSleepIsBlocked: Bool {
    (sleepDisabledSetting ?? false) || !systemSleepBlockers.isEmpty
  }

  /// True only when a clean result is actually provable: no blockers, no
  /// unclassified assertions, and the standing setting was successfully read.
  public var canProveSleepIsUnblocked: Bool {
    sleepDisabledSetting == false && systemSleepBlockers.isEmpty
      && unclassifiedAssertions.isEmpty
  }
}
