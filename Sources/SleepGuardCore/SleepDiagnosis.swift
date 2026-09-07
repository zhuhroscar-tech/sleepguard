import Foundation

/// A single observed power assertion. This is an *observation*: the owning PID
/// may exit or be reused at any time, so nothing here is treated as a live handle.
public struct AssertionObservation: Equatable, Sendable {
  public let assertionID: UInt64
  public let pid: Int32
  public let processName: String
  public let rawType: String
  public let humanName: String
  public let heldSeconds: Int

  public init(
    assertionID: UInt64,
    pid: Int32,
    processName: String,
    rawType: String,
    humanName: String,
    heldSeconds: Int
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
  public let sleepDisabledSetting: Bool

  /// Assertion type names that block full system idle sleep.
  static let systemSleepBlockingTypes: Set<String> = [
    "NoIdleSleepAssertion",
    "PreventUserIdleSystemSleep",
    "PreventSystemSleep",
  ]

  public init(observations: [AssertionObservation], sleepDisabledSetting: Bool) {
    self.observations = observations
    self.sleepDisabledSetting = sleepDisabledSetting
  }

  public var systemSleepBlockers: [AssertionObservation] {
    observations.filter { Self.systemSleepBlockingTypes.contains($0.rawType) }
  }

  public var systemSleepIsBlocked: Bool {
    sleepDisabledSetting || !systemSleepBlockers.isEmpty
  }
}
