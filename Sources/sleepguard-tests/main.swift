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
    !diagnosis.canProveSleepIsUnblocked,
    "an empty table must not yield a provably-clean verdict")
  Harness.expect(
    diagnosis.systemSleepIsBlocked == nil,
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
    !diagnosis.canProveSleepIsUnblocked,
    "undecodable records must never produce a provably-clean verdict")
  Harness.expect(
    diagnosis.systemSleepIsBlocked == nil,
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
    blockerOnIncompleteScan.systemSleepIsBlocked == true,
    "a confirmed blocker is decisive even on an incomplete scan")

  // The NULL-table path must reach the same conclusion through the library type.
  let nullTable = DecodedAssertions(
    observations: [], malformedRecordCount: 0, sourceTableWasNull: true)
  Harness.expect(
    !SleepDiagnosis(snapshot: nullTable, sleepDisabledSetting: false).canProveSleepIsUnblocked,
    "a NULL table must not produce a clean verdict through the library type")
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
    diagnosis.systemSleepIsBlocked == true, "NoIdleSleepAssertion must block system sleep")
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
  Harness.expect(diskDiagnosis.canProveSleepIsUnblocked, "disk-only state is provably clean")

  // IOPMLib.h, kIOPMAssertNetworkClientActive: "Keeps the system awake while OS X
  // serves active network clients... this assertion can prevent system from going
  // into idle sleep." It must be a blocker, never certified harmless.
  let network = AssertionObservation(
    assertionID: 2, pid: 2, processName: "sharingd", rawType: "NetworkClientActive",
    humanName: "", heldSeconds: 1)
  let networkDiagnosis = SleepDiagnosis(
    observations: [network], sleepDisabledSetting: false, sourceWasComplete: true)
  Harness.equal(networkDiagnosis.systemSleepBlockers.count, 1, "NetworkClientActive blocks sleep")
  Harness.expect(!networkDiagnosis.canProveSleepIsUnblocked, "network assertion is not clean")

  // Types with no citable authority must be unclassified, never enumerated harmless.
  for unsourced in ["UserIsActive", "BackgroundTask", "DenySystemSleep", "EnableIdleSleep"] {
    let observation = AssertionObservation(
      assertionID: 3, pid: 3, processName: "x", rawType: unsourced, humanName: "", heldSeconds: 1)
    let diagnosis = SleepDiagnosis(
      observations: [observation], sleepDisabledSetting: false, sourceWasComplete: true)
    Harness.equal(
      diagnosis.unclassifiedAssertions.count, 1, "\(unsourced) has no cited authority")
    Harness.expect(
      !diagnosis.canProveSleepIsUnblocked, "\(unsourced) must not yield a clean result")
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
    unknown.systemSleepIsBlocked == nil, "unknown SleepDisabled yields an unknown verdict")

  let blocked = SleepDiagnosis(
    observations: [
      AssertionObservation(
        assertionID: 1, pid: 1, processName: "x", rawType: "NoIdleSleepAssertion", humanName: "",
        heldSeconds: 1)
    ],
    sleepDisabledSetting: nil, sourceWasComplete: true)
  Harness.expect(
    blocked.systemSleepIsBlocked == true,
    "a confirmed blocker is decisive even when the standing setting is unknown")

  let clean = SleepDiagnosis(observations: [], sleepDisabledSetting: false, sourceWasComplete: true)
  Harness.expect(clean.systemSleepIsBlocked == false, "fully known empty state is unblocked")
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
    diagnosis.systemSleepIsBlocked == true, "display assertion blocks system idle sleep")
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
  Harness.expect(diagnosis.systemSleepIsBlocked == false, "sleep is not blocked")
}

func testUnknownAssertionTypeIsUnclassifiedAndMakesTheAnswerUncertain() {
  let observation = AssertionObservation(
    assertionID: 9, pid: 900, processName: "Mystery", rawType: "SomeFutureAssertionType",
    humanName: "", heldSeconds: 30)

  let diagnosis = SleepDiagnosis(
    observations: [observation], sleepDisabledSetting: false, sourceWasComplete: true)

  Harness.equal(diagnosis.unclassifiedAssertions.count, 1, "unknown type is unclassified")
  Harness.expect(
    !diagnosis.canProveSleepIsUnblocked,
    "an unknown assertion type must not yield a confident clean result")
}

func testSleepDisabledSettingIsTriStateSoAFailedLookupIsNotReportedAsFalse() {
  let unknown = SleepDiagnosis(observations: [], sleepDisabledSetting: nil, sourceWasComplete: true)
  Harness.expect(
    !unknown.canProveSleepIsUnblocked, "unknown SleepDisabled must not yield a clean result")

  let known = SleepDiagnosis(observations: [], sleepDisabledSetting: false, sourceWasComplete: true)
  Harness.expect(known.canProveSleepIsUnblocked, "fully known empty state is provably clean")

  let disabled = SleepDiagnosis(
    observations: [], sleepDisabledSetting: true, sourceWasComplete: true)
  Harness.expect(disabled.systemSleepIsBlocked == true, "SleepDisabled=1 blocks sleep")
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

func testLiveSleepDisabledLookupReturnsAKnownValueOnThisHost() {
  // IOPMrootDomain always publishes SleepDisabled on macOS, so a nil here means
  // the lookup broke rather than that sleep is enabled.
  let setting = IOKitAssertionReader().sleepDisabledSetting()
  Harness.expect(setting != nil, "SleepDisabled must resolve to a known boolean on macOS")
}

testLiveTestGateOptsInOnlyForAnExplicitTruthyValue()
testAnEmptyButWellFormedTableIsNotAProvenCleanScan()
testALibraryConsumerCannotGetACleanVerdictFromAnIncompleteSnapshot()
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
  testLiveSleepDisabledLookupReturnsAKnownValueOnThisHost()
} else {
  print("SKIP: live IOKit tests (set \(LiveTestGate.variableName)=1 to run them)")
}
Harness.finish()
