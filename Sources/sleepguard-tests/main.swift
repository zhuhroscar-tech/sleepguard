import Foundation
import SleepGuardCore

// Minimal assertion harness (XCTest unavailable on a Command Line Tools-only host).
enum Harness {
  nonisolated(unsafe) static var failures: [String] = []
  nonisolated(unsafe) static var checks = 0

  static func expect(
    _ condition: Bool, _ message: String, file: StaticString = #file, line: UInt = #line
  ) {
    checks += 1
    if !condition { failures.append("\(file):\(line): \(message)") }
  }

  static func equal<T: Equatable>(
    _ lhs: T, _ rhs: T, _ message: String, file: StaticString = #file, line: UInt = #line
  ) {
    checks += 1
    if lhs != rhs { failures.append("\(file):\(line): \(message) — got \(lhs), expected \(rhs)") }
  }

  static func finish() -> Never {
    if failures.isEmpty {
      print("PASS: \(checks) assertions")
      exit(0)
    }
    for failure in failures { print("FAIL: \(failure)") }
    print("FAILED: \(failures.count) of \(checks) assertions")
    exit(1)
  }
}

/// Opt-in gate for tests that read live system state.
///
/// Pure function over an injected environment so the gate itself is testable
/// without mutating the process environment.
enum LiveTestGate {
  static let variableName = "RUN_LIVE_TESTS"

  static func isEnabled(environment: [String: String]) -> Bool {
    guard let raw = environment[variableName] else { return false }
    let normalized = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    return normalized == "1" || normalized == "true" || normalized == "yes"
  }
}

func testLiveTestGateOptsInOnlyForAnExplicitTruthyValue() {
  Harness.expect(
    !LiveTestGate.isEnabled(environment: [:]),
    "live tests must be off when RUN_LIVE_TESTS is absent")
  Harness.expect(
    !LiveTestGate.isEnabled(environment: ["RUN_LIVE_TESTS": ""]),
    "an empty value is not an opt-in")
  Harness.expect(
    !LiveTestGate.isEnabled(environment: ["RUN_LIVE_TESTS": "0"]),
    "0 is not an opt-in")
  Harness.expect(
    !LiveTestGate.isEnabled(environment: ["RUN_LIVE_TESTS": "false"]),
    "false is not an opt-in")
  Harness.expect(
    !LiveTestGate.isEnabled(environment: ["RUN_LIVE_TESTS": "  "]),
    "whitespace is not an opt-in")
  Harness.expect(
    LiveTestGate.isEnabled(environment: ["RUN_LIVE_TESTS": "1"]),
    "1 opts in")
  Harness.expect(
    LiveTestGate.isEnabled(environment: ["RUN_LIVE_TESTS": " true "]),
    "surrounding whitespace must not defeat an explicit opt-in")
  Harness.expect(
    LiveTestGate.isEnabled(environment: ["RUN_LIVE_TESTS": "TRUE"]),
    "opt-in comparison is case-insensitive")
  Harness.expect(
    !LiveTestGate.isEnabled(environment: ["OTHER": "1"]),
    "an unrelated variable must not enable live tests")
}

func testAnEmptyButWellFormedTableIsNotAProvenCleanScan() {
  // Regression: review found that a successfully-returned, well-shaped, EMPTY
  // dictionary produced isComplete == true and therefore a provably-clean exit 0.
  // A running macOS always holds at least one process assertion, so zero
  // observations means a broken or permission-denied read, not an idle Mac.
  let empty = AssertionDecoder.decode(assertionsByProcess: [:], now: Date())

  Harness.expect(empty.hasImplausiblyEmptyTable, "zero observations is implausible on live macOS")
  Harness.expect(!empty.isComplete, "an empty assertion table is not a proven-empty scan")

  let diagnosis = SleepDiagnosis(snapshot: empty, sleepDisabledSetting: false)
  Harness.expect(
    !diagnosis.canProveSleepIsUnblocked(aggregate: cleanAggregate),
    "an empty table must not yield a provably-clean verdict")
  Harness.expect(
    diagnosis.systemSleepIsBlocked(aggregate: cleanAggregate) == nil,
    "an empty table yields an unknown verdict, not a clean false")

  // A table that decoded at least one real assertion is not implausibly empty.
  let populated = AssertionDecoder.decode(
    assertionsByProcess: [
      1: [["AssertionId": UInt64(1), "AssertType": "PreventDiskIdle", "Process Name": "x"]]
    ],
    now: Date())
  Harness.expect(
    !populated.hasImplausiblyEmptyTable, "a populated table is not implausibly empty")
  Harness.expect(populated.isComplete, "a populated well-formed table is complete")
}

func testALibraryConsumerCannotGetACleanVerdictFromAnIncompleteSnapshot() {
  // Regression: SleepGuardCore is a public library product, but all fail-closed
  // logic used to live in the CLI's local `uncertain` variable. A third party
  // composing reader.snapshot() -> SleepDiagnosis(observations:) dropped the
  // completeness flags and got canProveSleepIsUnblocked == true from a snapshot
  // full of undecodable records. Completeness is now required by construction.
  let incomplete = DecodedAssertions(observations: [], malformedRecordCount: 12)
  Harness.expect(!incomplete.isComplete, "12 malformed records is an incomplete snapshot")

  let diagnosis = SleepDiagnosis(snapshot: incomplete, sleepDisabledSetting: false)
  Harness.expect(
    !diagnosis.canProveSleepIsUnblocked(aggregate: cleanAggregate),
    "undecodable records must never produce a provably-clean verdict")
  Harness.expect(
    diagnosis.systemSleepIsBlocked(aggregate: cleanAggregate) == nil,
    "an incomplete snapshot yields unknown, not not-blocked")

  // A confirmed blocker stays decisive on an incomplete scan: finding more
  // evidence could not turn a real blocker into a clean result.
  let blockerOnIncompleteScan = SleepDiagnosis(
    observations: [
      AssertionObservation(
        assertionID: 1, pid: 1, processName: "ChatGPT", rawType: "NoIdleSleepAssertion",
        humanName: "", heldSeconds: 1)
    ],
    sleepDisabledSetting: false,
    sourceWasComplete: false)
  Harness.expect(
    blockerOnIncompleteScan.systemSleepIsBlocked(aggregate: cleanAggregate) == true,
    "a confirmed blocker is decisive even on an incomplete scan")

  // The NULL-table path must reach the same conclusion through the library type.
  let nullTable = DecodedAssertions(
    observations: [], malformedRecordCount: 0, sourceTableWasNull: true)
  Harness.expect(
    !SleepDiagnosis(snapshot: nullTable, sleepDisabledSetting: false).canProveSleepIsUnblocked(
      aggregate: cleanAggregate),
    "a NULL table must not produce a clean verdict through the library type")
}

// A clean aggregate table with nothing asserted, for tests that only exercise
// the process-held side. Named so no test silently proves "unblocked" without
// stating which aggregate view it assumed.
let cleanAggregate = AggregateAssertionStatus.decode(rawTable: [
  "PreventUserIdleSystemSleep": NSNumber(value: 0),
  "PreventSystemSleep": NSNumber(value: 0),
  "PreventUserIdleDisplaySleep": NSNumber(value: 0),
  "NetworkClientActive": NSNumber(value: 0),
  "PreventDiskIdle": NSNumber(value: 0),
])

func testAggregateTableDecodesLevelsAndFailsClosedOnMalformedEntries() {
  let decoded = AggregateAssertionStatus.decode(rawTable: [
    "PreventUserIdleSystemSleep": NSNumber(value: 1),
    "PreventDiskIdle": NSNumber(value: 0),
    "UserIsActive": NSNumber(value: 1),
  ])
  Harness.equal(decoded.levels["PreventUserIdleSystemSleep"], 1, "asserted level decodes")
  Harness.equal(decoded.levels["PreventDiskIdle"], 0, "zero level decodes")
  Harness.expect(decoded.isComplete, "well-formed aggregate table is complete")
  Harness.equal(
    decoded.activeBlockingTypes, ["PreventUserIdleSystemSleep"],
    "only asserted blocking types are active")

  // A NULL table is not a proven-empty result.
  let nullTable = AggregateAssertionStatus.decode(rawTable: nil)
  Harness.expect(nullTable.sourceTableWasNull, "nil raw table is flagged")
  Harness.expect(!nullTable.isComplete, "a NULL aggregate table is not complete")

  // An empty table is a failed read: macOS publishes a fixed set of keys.
  let empty = AggregateAssertionStatus.decode(rawTable: [AnyHashable: Any]())
  Harness.expect(empty.hasImplausiblyEmptyTable, "an empty aggregate table is implausible")
  Harness.expect(!empty.isComplete, "an empty aggregate table is not complete")

  // A non-dictionary payload is malformed, not empty.
  let wrongShape = AggregateAssertionStatus.decode(rawTable: "not a dictionary")
  Harness.equal(wrongShape.malformedEntryCount, 1, "uncastable payload counted malformed")
  Harness.expect(!wrongShape.isComplete, "uncastable payload is not complete")

  // Malformed entries are counted, valid siblings survive, completeness fails.
  let mixed = AggregateAssertionStatus.decode(rawTable: [
    "PreventSystemSleep": NSNumber(value: 1),
    "": NSNumber(value: 1),
    "BlankValue": "not a number",
    NSNumber(value: 7): NSNumber(value: 1),
  ])
  Harness.equal(mixed.levels["PreventSystemSleep"], 1, "valid entry survives")
  Harness.equal(mixed.malformedEntryCount, 3, "blank key, bad value and non-string key counted")
  Harness.expect(!mixed.isComplete, "malformed aggregate entries mark it incomplete")

  // A CFBoolean must not silently bridge to a 0/1 level.
  let boolean = AggregateAssertionStatus.decode(rawTable: ["PreventSystemSleep": true])
  Harness.equal(boolean.malformedEntryCount, 1, "a Boolean is not an assertion level")
  Harness.expect(boolean.levels.isEmpty, "Boolean entry is not recorded as a level")
}

func testAggregateTableRevealsBlockersNoProcessAssertionAccountsFor() {
  // The blind spot this closes: the aggregate table says idle sleep is being
  // prevented, but no process-held record explains it (a kernel-held assertion,
  // or a process record that could not be read). It names the type, not an owner.
  let aggregate = AggregateAssertionStatus.decode(rawTable: [
    "PreventUserIdleSystemSleep": NSNumber(value: 1),
    "PreventDiskIdle": NSNumber(value: 0),
  ])
  let noProcessEvidence = SleepDiagnosis(
    observations: [], sleepDisabledSetting: false, sourceWasComplete: true)

  Harness.equal(
    noProcessEvidence.unattributedBlockingTypes(aggregate: aggregate),
    ["PreventUserIdleSystemSleep"],
    "an aggregate blocker with no process record is unattributed")

  // Once a process-held assertion of that type is observed, it is attributed
  // and must no longer be reported as an unexplained blocker.
  let attributed = SleepDiagnosis(
    observations: [
      AssertionObservation(
        assertionID: 1, pid: 42, processName: "Video", rawType: "PreventUserIdleSystemSleep",
        humanName: "", heldSeconds: 5)
    ],
    sleepDisabledSetting: false, sourceWasComplete: true)
  Harness.equal(
    attributed.unattributedBlockingTypes(aggregate: aggregate), [],
    "an observed process assertion accounts for its aggregate type")

  // NoIdleSleepAssertion is the deprecated alias of PreventUserIdleSystemSleep,
  // and the aggregate table reports only the modern name. The alias must count
  // as accounting for it, or every Electron app produces a false blind-spot alarm.
  let aliasHolder = SleepDiagnosis(
    observations: [
      AssertionObservation(
        assertionID: 2, pid: 1437, processName: "ChatGPT", rawType: "NoIdleSleepAssertion",
        humanName: "Electron", heldSeconds: 99)
    ],
    sleepDisabledSetting: false, sourceWasComplete: true)
  Harness.equal(
    aliasHolder.unattributedBlockingTypes(aggregate: aggregate), [],
    "NoIdleSleepAssertion accounts for the PreventUserIdleSystemSleep aggregate level")

  // Multiple unattributed types are reported in sorted order.
  let twoBlockers = AggregateAssertionStatus.decode(rawTable: [
    "PreventUserIdleDisplaySleep": NSNumber(value: 1),
    "NetworkClientActive": NSNumber(value: 2),
  ])
  Harness.equal(
    noProcessEvidence.unattributedBlockingTypes(aggregate: twoBlockers),
    ["NetworkClientActive", "PreventUserIdleDisplaySleep"],
    "multiple unattributed types are sorted")

  // An unrecognized aggregate type that is asserted must be surfaced as
  // unclassified, never assumed harmless.
  let unknownType = AggregateAssertionStatus.decode(rawTable: [
    "SomeFutureAggregateType": NSNumber(value: 1),
    "UserIsActive": NSNumber(value: 1),
    "PreventDiskIdle": NSNumber(value: 1),
    "InactiveFutureType": NSNumber(value: 0),
  ])
  Harness.equal(
    noProcessEvidence.unclassifiedAggregateTypes(aggregate: unknownType),
    ["SomeFutureAggregateType", "UserIsActive"],
    "asserted unrecognized aggregate types are unclassified; inactive ones are not")
  Harness.equal(
    noProcessEvidence.unattributedBlockingTypes(aggregate: unknownType), [],
    "an unclassified type is not reported as a known blocker")

  // Regression: proving "unblocked" must require the aggregate view. A process
  // scan that is clean on its own must NOT yield a clean verdict when the
  // aggregate table reports an unattributed blocker or is itself incomplete.
  Harness.expect(
    !noProcessEvidence.canProveSleepIsUnblocked(aggregate: aggregate),
    "an unattributed aggregate blocker must defeat the clean proof")
  Harness.expect(
    !noProcessEvidence.canProveSleepIsUnblocked(
      aggregate: AggregateAssertionStatus.decode(rawTable: nil)),
    "an unreadable aggregate table must defeat the clean proof")
  Harness.expect(
    !noProcessEvidence.canProveSleepIsUnblocked(aggregate: unknownType),
    "an unclassified active aggregate type must defeat the clean proof")
  Harness.expect(
    noProcessEvidence.canProveSleepIsUnblocked(aggregate: cleanAggregate),
    "a complete process scan plus a complete quiet aggregate table is provably clean")

  // A negative level is nonsensical for a count and must be malformed, not
  // silently read as "not asserted".
  let negative = AggregateAssertionStatus.decode(rawTable: [
    "PreventSystemSleep": NSNumber(value: -1)
  ])
  Harness.equal(negative.malformedEntryCount, 1, "a negative level is malformed")
  Harness.expect(negative.levels.isEmpty, "negative level is not recorded")
  Harness.expect(!negative.isComplete, "a negative level marks the table incomplete")
}

func testASecondHolderOfAnAlreadyObservedTypeIsNotMaskedByPresenceAlone() {
  // Regression: comparing SET PRESENCE let one observed holder of type T grant
  // blanket amnesty to every other holder of T. The aggregate level must be
  // compared against the NUMBER of observed holders, not merely whether any
  // exists, or a second unattributed holder is silently masked.
  let twoHolders = AggregateAssertionStatus.decode(rawTable: [
    "PreventUserIdleDisplaySleep": NSNumber(value: 2)
  ])
  let oneObserved = SleepDiagnosis(
    observations: [
      AssertionObservation(
        assertionID: 1, pid: 5899, processName: "UniversalControl",
        rawType: "PreventUserIdleDisplaySleep", humanName: "", heldSeconds: 10)
    ],
    sleepDisabledSetting: false, sourceWasComplete: true)

  Harness.equal(
    oneObserved.unattributedBlockingTypes(aggregate: twoHolders),
    ["PreventUserIdleDisplaySleep"],
    "level 2 with one observed holder leaves one holder unattributed")
  Harness.expect(
    !oneObserved.canProveSleepIsUnblocked(aggregate: twoHolders),
    "a masked second holder must defeat the clean proof")
  Harness.expect(
    oneObserved.systemSleepIsBlocked(aggregate: twoHolders) == true,
    "the observed holder is itself a confirmed blocker")

  // With both holders observed, the level is fully accounted for.
  let twoObserved = SleepDiagnosis(
    observations: [
      AssertionObservation(
        assertionID: 1, pid: 5899, processName: "UniversalControl",
        rawType: "PreventUserIdleDisplaySleep", humanName: "", heldSeconds: 10),
      AssertionObservation(
        assertionID: 2, pid: 700, processName: "Video",
        rawType: "PreventUserIdleDisplaySleep", humanName: "", heldSeconds: 3),
    ],
    sleepDisabledSetting: false, sourceWasComplete: true)
  Harness.equal(
    twoObserved.unattributedBlockingTypes(aggregate: twoHolders), [],
    "two observed holders account for level 2")
}

func testAlwaysPresentBaselineAggregateTypesAreNotedButDoNotForceUncertainty() {
  // Regression: UserIsActive and EnableIdleSleep are asserted on every
  // interactive Mac and have no IOPMLib.h citation. Treating them as reasons
  // sleep might be blocked made exit 0 unreachable, destroying the exit code's
  // information content. They are noted, never certified harmless, and never
  // counted as blockers or uncertainty.
  let realWorldTable = AggregateAssertionStatus.decode(rawTable: [
    "UserIsActive": NSNumber(value: 1),
    "EnableIdleSleep": NSNumber(value: 1),
    "PreventUserIdleSystemSleep": NSNumber(value: 0),
    "PreventUserIdleDisplaySleep": NSNumber(value: 0),
    "PreventSystemSleep": NSNumber(value: 0),
    "NetworkClientActive": NSNumber(value: 0),
    "PreventDiskIdle": NSNumber(value: 0),
  ])
  let quiet = SleepDiagnosis(
    observations: [], sleepDisabledSetting: false, sourceWasComplete: true)

  Harness.equal(
    quiet.baselineActiveAggregateTypes(aggregate: realWorldTable),
    ["EnableIdleSleep", "UserIsActive"],
    "the always-present pair is reported as baseline")
  Harness.equal(
    quiet.novelUnclassifiedAggregateTypes(aggregate: realWorldTable), [],
    "the baseline pair is not novel")
  Harness.expect(
    quiet.canProveSleepIsUnblocked(aggregate: realWorldTable),
    "a real-world quiet Mac must be able to reach a provably-clean verdict")
  Harness.expect(
    quiet.systemSleepIsBlocked(aggregate: realWorldTable) == false,
    "a real-world quiet Mac is not blocked")

  // A genuinely novel asserted type is still hard uncertainty.
  let novel = AggregateAssertionStatus.decode(rawTable: [
    "UserIsActive": NSNumber(value: 1),
    "SomeFutureAggregateType": NSNumber(value: 1),
    "PreventDiskIdle": NSNumber(value: 0),
  ])
  Harness.equal(
    quiet.novelUnclassifiedAggregateTypes(aggregate: novel), ["SomeFutureAggregateType"],
    "an unrecognized non-baseline type is novel")
  Harness.expect(
    !quiet.canProveSleepIsUnblocked(aggregate: novel),
    "a novel unclassified active type defeats the clean proof")
  Harness.expect(
    quiet.systemSleepIsBlocked(aggregate: novel) == nil,
    "a novel unclassified active type yields unknown")

  // Regression: the baseline allowlist must not certify a plausible blocker as
  // harmless. InternalPreventSleep and friends measured level 0 on a real host,
  // so allowlisting them bought no noise reduction while letting an active one
  // produce a provably-clean verdict on an unsourced guess.
  for suspicious in [
    "InternalPreventSleep", "InternalPreventDisplaySleep", "SystemIsActive", "DisplayWake",
  ] {
    Harness.expect(
      !SleepDiagnosis.baselineUnclassifiedAggregateTypes.contains(suspicious),
      "\(suspicious) must not be baselined: no header citation and its name suggests blocking")

    let table = AggregateAssertionStatus.decode(rawTable: [
      suspicious: NSNumber(value: 1),
      "UserIsActive": NSNumber(value: 1),
      "PreventDiskIdle": NSNumber(value: 0),
    ])
    Harness.equal(
      quiet.novelUnclassifiedAggregateTypes(aggregate: table), [suspicious],
      "an active \(suspicious) is novel, not baseline")
    Harness.expect(
      !quiet.canProveSleepIsUnblocked(aggregate: table),
      "an active \(suspicious) must never yield a provably-clean verdict")
    Harness.expect(
      quiet.systemSleepIsBlocked(aggregate: table) == nil,
      "an active \(suspicious) must yield unknown, not not-blocked")
  }
}

func testNoIdleSleepAssertionIsReportedAsASystemSleepBlocker() {
  let observation = AssertionObservation(
    assertionID: 0x000d_fae9_0001_870f,
    pid: 1437,
    processName: "ChatGPT",
    rawType: "NoIdleSleepAssertion",
    humanName: "Electron",
    heldSeconds: 110_288
  )

  let diagnosis = SleepDiagnosis(
    observations: [observation], sleepDisabledSetting: false, sourceWasComplete: true)

  Harness.expect(
    diagnosis.systemSleepIsBlocked(aggregate: cleanAggregate) == true,
    "NoIdleSleepAssertion must block system sleep")
  Harness.equal(
    diagnosis.systemSleepBlockers.map(\.processName), ["ChatGPT"], "blocker process name")
}

func testDecodingIOKitAssertionsByProcessProducesObservations() {
  // Shape mirrors IOPMCopyAssertionsByProcess: PID key -> array of assertion dictionaries.
  let raw: [Int32: [[String: Any]]] = [
    1437: [
      [
        "AssertionId": UInt64(0x000d_fae9_0001_870f),
        "AssertType": "NoIdleSleepAssertion",
        "AssertName": "Electron",
        "Process Name": "ChatGPT",
        "AssertStartWhen": Date(timeIntervalSinceNow: -110_288),
      ]
    ]
  ]

  let decoded = AssertionDecoder.decode(assertionsByProcess: raw, now: Date())

  Harness.equal(decoded.observations.count, 1, "one decoded observation")
  Harness.expect(decoded.isComplete, "well-formed input must decode completely")
  Harness.equal(decoded.observations.first?.processName, "ChatGPT", "process name")
  Harness.equal(decoded.observations.first?.rawType, "NoIdleSleepAssertion", "assertion type")
  Harness.equal(decoded.observations.first?.pid, 1437, "pid")
}

func testMalformedAssertionRecordMarksResultIncompleteWithoutDroppingValidEvidence() {
  let raw: [Int32: [[String: Any]]] = [
    1437: [
      [
        "AssertionId": UInt64(1),
        "AssertType": "NoIdleSleepAssertion",
        "AssertName": "Electron",
        "Process Name": "ChatGPT",
      ]
    ],
    99: [
      // Missing AssertType: unusable evidence, must not be silently dropped as "clean".
      ["AssertionId": UInt64(2), "AssertName": "mystery", "Process Name": "somed"]
    ],
  ]

  let decoded = AssertionDecoder.decode(assertionsByProcess: raw, now: Date())

  Harness.expect(!decoded.isComplete, "malformed record must mark the scan incomplete")
  Harness.equal(decoded.observations.count, 1, "valid record survives")
  Harness.equal(decoded.observations.first?.processName, "ChatGPT", "valid record preserved")
  Harness.equal(decoded.malformedRecordCount, 1, "malformed record counted")
}

func testOnlyHeaderCitedNonBlockingTypesAreCertifiedHarmless() {
  // IOPMLib.h, kIOPMAssertPreventDiskIdle: "The system may still sleep while
  // this assertion is active." That is the only citable non-blocker.
  let disk = AssertionObservation(
    assertionID: 1, pid: 1, processName: "a", rawType: "PreventDiskIdle", humanName: "",
    heldSeconds: 1)
  let diskDiagnosis = SleepDiagnosis(
    observations: [disk], sleepDisabledSetting: false, sourceWasComplete: true)
  Harness.equal(diskDiagnosis.systemSleepBlockers.count, 0, "PreventDiskIdle does not block")
  Harness.equal(diskDiagnosis.unclassifiedAssertions.count, 0, "PreventDiskIdle is a known type")
  Harness.expect(
    diskDiagnosis.canProveSleepIsUnblocked(aggregate: cleanAggregate),
    "disk-only state is provably clean")

  // IOPMLib.h, kIOPMAssertNetworkClientActive: "Keeps the system awake while OS X
  // serves active network clients... this assertion can prevent system from going
  // into idle sleep." It must be a blocker, never certified harmless.
  let network = AssertionObservation(
    assertionID: 2, pid: 2, processName: "sharingd", rawType: "NetworkClientActive",
    humanName: "", heldSeconds: 1)
  let networkDiagnosis = SleepDiagnosis(
    observations: [network], sleepDisabledSetting: false, sourceWasComplete: true)
  Harness.equal(networkDiagnosis.systemSleepBlockers.count, 1, "NetworkClientActive blocks sleep")
  Harness.expect(
    !networkDiagnosis.canProveSleepIsUnblocked(aggregate: cleanAggregate),
    "network assertion is not clean")

  // Types with no citable authority must be unclassified, never enumerated harmless.
  for unsourced in ["UserIsActive", "BackgroundTask", "DenySystemSleep", "EnableIdleSleep"] {
    let observation = AssertionObservation(
      assertionID: 3, pid: 3, processName: "x", rawType: unsourced, humanName: "", heldSeconds: 1)
    let diagnosis = SleepDiagnosis(
      observations: [observation], sleepDisabledSetting: false, sourceWasComplete: true)
    Harness.equal(
      diagnosis.unclassifiedAssertions.count, 1, "\(unsourced) has no cited authority")
    Harness.expect(
      !diagnosis.canProveSleepIsUnblocked(aggregate: cleanAggregate),
      "\(unsourced) must not yield a clean result")
  }
}

func testNullIOKitTableIsNotTreatedAsAProvenEmptyScan() {
  // IOPMLib.h documents only kIOReturnSuccess and a per-PID dictionary; it does
  // not guarantee that NULL means "no assertions". Unprovable means incomplete.
  let snapshot = DecodedAssertions(
    observations: [], malformedRecordCount: 0, sourceTableWasNull: true)

  Harness.expect(!snapshot.isComplete, "a NULL assertion table is not a proven-empty scan")
}

func testSystemSleepIsBlockedIsTriStateWhenTheStandingSettingIsUnknown() {
  let unknown = SleepDiagnosis(observations: [], sleepDisabledSetting: nil, sourceWasComplete: true)
  Harness.expect(
    unknown.systemSleepIsBlocked(aggregate: cleanAggregate) == nil,
    "unknown SleepDisabled yields an unknown verdict")

  let blocked = SleepDiagnosis(
    observations: [
      AssertionObservation(
        assertionID: 1, pid: 1, processName: "x", rawType: "NoIdleSleepAssertion", humanName: "",
        heldSeconds: 1)
    ],
    sleepDisabledSetting: nil, sourceWasComplete: true)
  Harness.expect(
    blocked.systemSleepIsBlocked(aggregate: cleanAggregate) == true,
    "a confirmed blocker is decisive even when the standing setting is unknown")

  let clean = SleepDiagnosis(observations: [], sleepDisabledSetting: false, sourceWasComplete: true)
  Harness.expect(
    clean.systemSleepIsBlocked(aggregate: cleanAggregate) == false,
    "fully known empty state is unblocked")
}

func testDisplaySleepAssertionAlsoBlocksSystemIdleSleep() {
  // IOPMLib.h, kIOPMAssertPreventUserIdleDisplaySleep:
  // "While the display is prevented from dimming, the system cannot go into idle sleep."
  let observation = AssertionObservation(
    assertionID: 5, pid: 700, processName: "Video", rawType: "PreventUserIdleDisplaySleep",
    humanName: "playback", heldSeconds: 60)

  let diagnosis = SleepDiagnosis(
    observations: [observation], sleepDisabledSetting: false, sourceWasComplete: true)

  Harness.expect(
    diagnosis.systemSleepIsBlocked(aggregate: cleanAggregate) == true,
    "display assertion blocks system idle sleep")
  Harness.equal(diagnosis.systemSleepBlockers.count, 1, "display assertion is a blocker")
  Harness.equal(diagnosis.unclassifiedAssertions.count, 0, "known type is not unclassified")
}

func testKnownNonBlockingAssertionTypesAreNotReportedAsBlockers() {
  // Superseded by testOnlyHeaderCitedNonBlockingTypesAreCertifiedHarmless, which
  // checks each classification against a citable IOPMLib.h statement.
  let observation = AssertionObservation(
    assertionID: 1, pid: 1, processName: "a", rawType: "PreventDiskIdle", humanName: "",
    heldSeconds: 1)

  let diagnosis = SleepDiagnosis(
    observations: [observation], sleepDisabledSetting: false, sourceWasComplete: true)

  Harness.equal(diagnosis.systemSleepBlockers.count, 0, "no idle-sleep blockers")
  Harness.expect(
    diagnosis.systemSleepIsBlocked(aggregate: cleanAggregate) == false, "sleep is not blocked")
}

func testUnknownAssertionTypeIsUnclassifiedAndMakesTheAnswerUncertain() {
  let observation = AssertionObservation(
    assertionID: 9, pid: 900, processName: "Mystery", rawType: "SomeFutureAssertionType",
    humanName: "", heldSeconds: 30)

  let diagnosis = SleepDiagnosis(
    observations: [observation], sleepDisabledSetting: false, sourceWasComplete: true)

  Harness.equal(diagnosis.unclassifiedAssertions.count, 1, "unknown type is unclassified")
  Harness.expect(
    !diagnosis.canProveSleepIsUnblocked(aggregate: cleanAggregate),
    "an unknown assertion type must not yield a confident clean result")
}

func testSleepDisabledSettingIsTriStateSoAFailedLookupIsNotReportedAsFalse() {
  let unknown = SleepDiagnosis(observations: [], sleepDisabledSetting: nil, sourceWasComplete: true)
  Harness.expect(
    !unknown.canProveSleepIsUnblocked(aggregate: cleanAggregate),
    "unknown SleepDisabled must not yield a clean result")

  let known = SleepDiagnosis(observations: [], sleepDisabledSetting: false, sourceWasComplete: true)
  Harness.expect(
    known.canProveSleepIsUnblocked(aggregate: cleanAggregate),
    "fully known empty state is provably clean")

  let disabled = SleepDiagnosis(
    observations: [], sleepDisabledSetting: true, sourceWasComplete: true)
  Harness.expect(
    disabled.systemSleepIsBlocked(aggregate: cleanAggregate) == true, "SleepDisabled=1 blocks sleep"
  )
}

func testMissingStartTimestampYieldsUnknownDurationRatherThanZero() {
  let raw: [Int32: [[String: Any]]] = [
    1: [["AssertionId": UInt64(1), "AssertType": "NoIdleSleepAssertion", "Process Name": "x"]]
  ]

  let decoded = AssertionDecoder.decode(assertionsByProcess: raw, now: Date())

  Harness.equal(decoded.observations.count, 1, "record still decodes")
  Harness.expect(
    decoded.observations.first?.heldSeconds == nil, "absent timestamp is unknown, not zero")
}

func testNegativeAssertionIdentifierIsRejectedAsMalformed() {
  let raw: [Int32: [[String: Any]]] = [
    1: [["AssertionId": NSNumber(value: -5), "AssertType": "NoIdleSleepAssertion"]]
  ]

  let decoded = AssertionDecoder.decode(assertionsByProcess: raw, now: Date())

  Harness.equal(decoded.observations.count, 0, "negative id is not a valid assertion id")
  Harness.equal(decoded.malformedRecordCount, 1, "negative id counted as malformed")
}

func testUnexpectedIOKitDictionaryShapeThrowsInsteadOfReportingACleanScan() {
  var threwUnexpectedShape = false
  do {
    let result = try IOKitAssertionReader.decodeSnapshot(rawTable: "not a dictionary", now: Date())
    Harness.expect(
      false, "an uncastable IOKit payload must throw, not return \(result.observations.count)")
  } catch AssertionReadError.unexpectedShape {
    threwUnexpectedShape = true
  } catch {
    Harness.expect(false, "expected unexpectedShape, got \(error)")
  }
  Harness.expect(threwUnexpectedShape, "unexpectedShape must be the thrown error")
}

func testOneBadRecordDoesNotDiscardAPIDsValidRecords() {
  let table: [AnyHashable: Any] = [
    NSNumber(value: 1437): [
      ["AssertionId": UInt64(1), "AssertType": "NoIdleSleepAssertion", "Process Name": "ChatGPT"],
      "not a record",
    ]
  ]

  guard let decoded = try? IOKitAssertionReader.decodeSnapshot(rawTable: table, now: Date())
  else {
    Harness.expect(false, "a well-shaped table must decode")
    return
  }

  Harness.equal(decoded.observations.count, 1, "valid sibling record is preserved")
  Harness.equal(decoded.malformedRecordCount, 1, "exactly one element counted malformed")
  Harness.expect(!decoded.isComplete, "scan is incomplete")
}

func testLiveIOKitSnapshotIsReadableAndSelfConsistent() {
  // Real integration: reads live IOKit power-assertion state. Read-only, no mutation.
  guard let snapshot = try? IOKitAssertionReader().snapshot() else {
    Harness.expect(false, "IOKitAssertionReader.snapshot() must succeed on macOS")
    return
  }

  // A macOS host always has at least one live assertion (WindowServer/powerd),
  // so an empty table means the read path is broken, not that the Mac is idle.
  // Without this the per-observation checks below could pass vacuously.
  Harness.expect(
    !snapshot.observations.isEmpty,
    "live macOS always holds at least one process assertion; empty means a broken read")

  for observation in snapshot.observations {
    Harness.expect(!observation.rawType.isEmpty, "live assertion type must be non-empty")
    Harness.expect(observation.pid > 0, "live assertion pid must be positive")
    if let held = observation.heldSeconds {
      Harness.expect(held >= 0, "held duration must be non-negative")
    }
  }
}

func testLiveAggregateAssertionTableIsReadableAndSelfConsistent() {
  // Real integration: reads the live system-wide aggregate table. Read-only.
  let aggregate = IOKitAssertionReader().aggregateStatus()

  Harness.expect(
    !aggregate.levels.isEmpty,
    "macOS publishes a fixed set of aggregate assertion keys; empty means a broken read")
  Harness.expect(aggregate.isComplete, "the live aggregate table must decode completely")
  Harness.expect(!aggregate.sourceTableWasNull, "live aggregate table must not be NULL")
  Harness.equal(aggregate.malformedEntryCount, 0, "no malformed live aggregate entries")

  // Every level is a plausible non-negative count.
  for (name, level) in aggregate.levels {
    Harness.expect(!name.isEmpty, "aggregate key must be non-empty")
    Harness.expect(level >= 0, "aggregate level for \(name) must be non-negative")
  }

  // Cross-check the two IOKit views: any blocking type held by a process this
  // build observed must also be asserted in the aggregate table. The reverse
  // need not hold, which is exactly the blind spot this feature reports.
  guard let snapshot = try? IOKitAssertionReader().snapshot() else {
    Harness.expect(false, "process-held snapshot must succeed on macOS")
    return
  }
  let diagnosis = SleepDiagnosis(
    snapshot: snapshot, sleepDisabledSetting: IOKitAssertionReader().sleepDisabledSetting())
  for blocker in diagnosis.systemSleepBlockers {
    let canonical =
      blocker.rawType == "NoIdleSleepAssertion" ? "PreventUserIdleSystemSleep" : blocker.rawType
    if let level = aggregate.levels[canonical] {
      Harness.expect(
        level > 0,
        "process holds \(blocker.rawType) but aggregate \(canonical) level is \(level)")
    }
  }
}

func testLiveSleepDisabledLookupReturnsAKnownValueOnThisHost() {
  // IOPMrootDomain always publishes SleepDisabled on macOS, so a nil here means
  // the lookup broke rather than that sleep is enabled.
  let setting = IOKitAssertionReader().sleepDisabledSetting()
  Harness.expect(setting != nil, "SleepDisabled must resolve to a known boolean on macOS")
}

testLiveTestGateOptsInOnlyForAnExplicitTruthyValue()
testAnEmptyButWellFormedTableIsNotAProvenCleanScan()
testALibraryConsumerCannotGetACleanVerdictFromAnIncompleteSnapshot()
testAggregateTableDecodesLevelsAndFailsClosedOnMalformedEntries()
testAggregateTableRevealsBlockersNoProcessAssertionAccountsFor()
testASecondHolderOfAnAlreadyObservedTypeIsNotMaskedByPresenceAlone()
testAlwaysPresentBaselineAggregateTypesAreNotedButDoNotForceUncertainty()
testNoIdleSleepAssertionIsReportedAsASystemSleepBlocker()
testDecodingIOKitAssertionsByProcessProducesObservations()
testMalformedAssertionRecordMarksResultIncompleteWithoutDroppingValidEvidence()
testDisplaySleepAssertionAlsoBlocksSystemIdleSleep()
testOnlyHeaderCitedNonBlockingTypesAreCertifiedHarmless()
testNullIOKitTableIsNotTreatedAsAProvenEmptyScan()
testSystemSleepIsBlockedIsTriStateWhenTheStandingSettingIsUnknown()
testKnownNonBlockingAssertionTypesAreNotReportedAsBlockers()
testUnknownAssertionTypeIsUnclassifiedAndMakesTheAnswerUncertain()
testSleepDisabledSettingIsTriStateSoAFailedLookupIsNotReportedAsFalse()
testMissingStartTimestampYieldsUnknownDurationRatherThanZero()
testNegativeAssertionIdentifierIsRejectedAsMalformed()
testUnexpectedIOKitDictionaryShapeThrowsInsteadOfReportingACleanScan()
testOneBadRecordDoesNotDiscardAPIDsValidRecords()

// Live-system reads are opt-in. They pass on a healthy macOS host but assert on
// live IOKit state, so a sandboxed or restricted environment would report a
// product defect that does not exist. Skipping is announced, never silent.
if LiveTestGate.isEnabled(environment: ProcessInfo.processInfo.environment) {
  testLiveIOKitSnapshotIsReadableAndSelfConsistent()
  testLiveAggregateAssertionTableIsReadableAndSelfConsistent()
  testLiveSleepDisabledLookupReturnsAKnownValueOnThisHost()
} else {
  print("SKIP: live IOKit tests (set \(LiveTestGate.variableName)=1 to run them)")
}
Harness.finish()
