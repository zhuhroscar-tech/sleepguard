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

  /// Assertion types this build treats as preventing system idle sleep.
  ///
  /// Four of the five carry a citable IOPMLib.h statement.
  /// `PreventUserIdleDisplaySleep` is included deliberately: IOPMLib.h states
  /// "While the display is prevented from dimming, the system cannot go into
  /// idle sleep." `NetworkClientActive` likewise: "Keeps the system awake while
  /// OS X serves active network clients... On battery, this assertion can
  /// prevent system from going into idle sleep."
  ///
  /// **`PreventSystemSleep` is the one exception and has NO header statement.**
  /// Verified against the macOS 15.7.4 SDK: the only text attached to
  /// `kIOPMAssertionTypePreventSystemSleep` (IOPMLib.h:1013-1023) is a
  /// deprecation notice — "Deprecated in 10.9. This assertion is not supported
  /// in any OS X releases. This assertion is deprecated. Do not use it." — which
  /// says nothing about sleep in either direction. An earlier revision of this
  /// comment and of the README claimed a citation of "documented system-sleep
  /// prevention"; that citation does not exist and an independent review caught
  /// it. It is retained as a blocker on a measured, fail-closed basis instead:
  /// the type is still live in practice (macOS 15.7.4: `screensharingd` holds it
  /// with the reason "Remote user is connected", corroborated by
  /// `pmset -g assertions`), and the header redirects its callers to
  /// `kIOPMAssertPreventUserIdleSystemSleep`, which *is* cited as blocking idle
  /// sleep. Classifying a possible blocker as blocking can never manufacture a
  /// false clean verdict; the reverse could. See README "Classification
  /// authority".
  ///
  /// Note the asymmetry this preserves: a *blocking* verdict may rest on a
  /// documented measurement, but `knownNonBlockingTypes` — certifying something
  /// harmless — still requires a literal header citation, with no exceptions.
  public static let systemSleepBlockingTypes: Set<String> = [
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

  /// Blocking assertion types whose system-wide level exceeds the number of
  /// readable process records this build observed holding that type.
  ///
  /// A non-empty result means the assertion subsystem reports a sleep-blocking
  /// type asserted with no readable process record to account for it. It names
  /// the *type*, never an owner, because the aggregate table carries no owner
  /// information.
  ///
  /// **Measured level semantics, and a known limit.** IOPMLib.h does not
  /// document what a level counts. On macOS 15.7.4 it behaves as a 0/1 asserted
  /// flag, not a holder count: with three simultaneous holders of the canonical
  /// type `PreventUserIdleSystemSleep`, the level stayed at 1. Consequently one
  /// readable holder of a type does account for the whole level, and a *second*
  /// unreadable holder of that same type cannot be detected through this API.
  /// Same-type masking is therefore a known limit, not a solved problem. The
  /// count comparison below is defensive coding for level semantics Apple does
  /// not document — if a level ever does carry a count, a surplus is reported;
  /// under the measured 0/1 behavior it reduces to presence subtraction.
  ///
  /// `NoIdleSleepAssertion` is normalized to `PreventUserIdleSystemSleep`.
  /// IOPMLib.h:1025-1030 does not use the words "alias" or "identical" for it —
  /// its full text is "Deprecated in 10.7. Please use assertion type
  /// kIOPMAssertPreventUserIdleSystemSleep instead." (Contrast
  /// IOPMLib.h:1001 and :1008, which do say "identical to" for other types; the
  /// distinction is preserved here rather than paraphrased away.) The
  /// normalization rests on that documented redirect plus the measured fact that
  /// the aggregate table publishes only the modern name.
  public func unattributedBlockingTypes(
    aggregate: AggregateAssertionStatus
  ) -> [String] {
    var observedHolders: [String: Int] = [:]
    for observation in observations {
      observedHolders[Self.canonicalType(observation.rawType), default: 0] += 1
    }
    return aggregate.activeBlockingTypes
      .filter { type in
        let level = aggregate.levels[type] ?? 0
        return level > (observedHolders[Self.canonicalType(type)] ?? 0)
      }
      .sorted()
  }

  /// Aggregate assertion types this build cannot classify from an IOPMLib.h
  /// citation but which were **measured active on an idle interactive Mac**, so
  /// their mere presence carries no diagnostic signal.
  ///
  /// Membership requires a measurement, not a plausible-looking name. On macOS
  /// 15.7.4 only `UserIsActive` (raised by the window server on every input
  /// tickle) and `EnableIdleSleep` (a standing state key whose name asserts the
  /// opposite of blocking) were active on an otherwise idle host. Every other
  /// published key measured level 0, so excluding them costs nothing in noise
  /// and keeps real signal if one ever goes active.
  ///
  /// Deliberately **not** included: `InternalPreventSleep`,
  /// `InternalPreventDisplaySleep`, `SystemIsActive` and `DisplayWake`. Their
  /// names suggest they may prevent sleep, this build has no header citation
  /// either way, and they measured level 0 — so allowlisting them would buy no
  /// noise reduction while letting an active one produce a provably-clean
  /// verdict. That would be certifying a potential blocker as harmless on an
  /// unsourced guess, which this project forbids.
  ///
  /// Baseline members are still never certified harmless: this build has no
  /// header citation for their sleep semantics, so they are neither counted as
  /// blockers nor enumerated as safe.
  public static let baselineUnclassifiedAggregateTypes: Set<String> = [
    "UserIsActive",
    "EnableIdleSleep",
  ]

  /// Active aggregate types with no citable IOPMLib.h classification, split into
  /// the always-present baseline (informational) and genuinely novel types
  /// (which make the answer uncertain).
  public func unclassifiedAggregateTypes(
    aggregate: AggregateAssertionStatus
  ) -> [String] {
    aggregate.levels
      .filter { entry in
        entry.value > 0
          && !Self.systemSleepBlockingTypes.contains(entry.key)
          && !Self.knownNonBlockingTypes.contains(entry.key)
      }
      .keys.sorted()
  }

  /// Active unclassified aggregate types that are part of the documented
  /// always-present baseline. Informational only.
  public func baselineActiveAggregateTypes(
    aggregate: AggregateAssertionStatus
  ) -> [String] {
    unclassifiedAggregateTypes(aggregate: aggregate)
      .filter { Self.baselineUnclassifiedAggregateTypes.contains($0) }
  }

  /// Active unclassified aggregate types that are *not* in the baseline set.
  ///
  /// This is where the real signal is: an assertion type this build has never
  /// seen, asserted right now, with unknown sleep semantics. These make the scan
  /// incomplete.
  public func novelUnclassifiedAggregateTypes(
    aggregate: AggregateAssertionStatus
  ) -> [String] {
    unclassifiedAggregateTypes(aggregate: aggregate)
      .filter { !Self.baselineUnclassifiedAggregateTypes.contains($0) }
  }

  /// Maps the deprecated `NoIdleSleepAssertion` alias onto the modern type name
  /// documented in IOPMLib.h, so process-held and aggregate views can be
  /// compared. All other types are returned unchanged.
  static func canonicalType(_ rawType: String) -> String {
    rawType == "NoIdleSleepAssertion" ? "PreventUserIdleSystemSleep" : rawType
  }

  /// Tri-state verdict. `nil` means "cannot determine".
  ///
  /// This is a function taking **both** the aggregate table and the kernel
  /// driver view for the same reason `canProveSleepIsUnblocked` is: as a
  /// property it could return `false` — an affirmative clean answer — while a
  /// kernel driver held a documented idle-sleep assertion or a view could not
  /// be read at all. A consumer must not be able to get "not blocked" without
  /// consulting every view this build knows how to read. Neither parameter has
  /// a default value: silently defaulting to an empty view is exactly the
  /// fail-open path this signature exists to close.
  ///
  /// A confirmed blocker is decisive even on an incomplete scan: finding more
  /// evidence could never turn a real blocker into a clean result. That applies
  /// to a kernel driver blocker too, since
  /// `kIOPMDriverAssertionPreventSystemIdleSleepBit` is header-cited as
  /// preventing idle sleep.
  public func systemSleepIsBlocked(
    aggregate: AggregateAssertionStatus,
    driver: DriverAssertionStatus
  ) -> Bool? {
    if !systemSleepBlockers.isEmpty { return true }
    if !driver.documentedIdleSleepBlockers.isEmpty { return true }
    if sleepDisabledSetting == true { return true }
    if sleepDisabledSetting == nil { return nil }
    if !sourceWasComplete { return nil }
    if !unclassifiedAssertions.isEmpty { return nil }
    if !aggregate.isComplete { return nil }
    if !unattributedBlockingTypes(aggregate: aggregate).isEmpty { return nil }
    if !novelUnclassifiedAggregateTypes(aggregate: aggregate).isEmpty { return nil }
    if !driver.isComplete { return nil }
    if !driver.unclassifiedAssertedRecords.isEmpty { return nil }
    return false
  }

  /// True only when a clean result is actually provable.
  ///
  /// This is a function, not a property, on purpose: proving that nothing is
  /// blocking sleep requires the system-wide aggregate table and the kernel
  /// driver assertion view as well as the process-held one, so the caller
  /// cannot obtain a clean verdict without supplying them. The previous
  /// property form let a library consumer prove "unblocked" while never
  /// consulting the other views at all, which is the blind spot this API exists
  /// to close.
  ///
  /// Requires: the process snapshot decoded completely, the aggregate table
  /// decoded completely, the kernel driver view decoded and reconciled
  /// completely, the standing setting was read, and there are no blockers, no
  /// unclassified process assertions, no unattributed aggregate blockers, no
  /// unclassified active aggregate types, no kernel driver idle-sleep blockers
  /// and no asserted kernel records of unknown effect.
  public func canProveSleepIsUnblocked(
    aggregate: AggregateAssertionStatus,
    driver: DriverAssertionStatus
  ) -> Bool {
    sourceWasComplete && aggregate.isComplete && driver.isComplete
      && sleepDisabledSetting == false
      && systemSleepBlockers.isEmpty && unclassifiedAssertions.isEmpty
      && unattributedBlockingTypes(aggregate: aggregate).isEmpty
      && novelUnclassifiedAggregateTypes(aggregate: aggregate).isEmpty
      && driver.documentedIdleSleepBlockers.isEmpty
      && driver.unclassifiedAssertedRecords.isEmpty
  }
}
