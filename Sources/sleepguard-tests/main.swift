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

func testNoIdleSleepAssertionIsReportedAsASystemSleepBlocker() {
  let observation = AssertionObservation(
    assertionID: 0x000d_fae9_0001_870f,
    pid: 1437,
    processName: "ChatGPT",
    rawType: "NoIdleSleepAssertion",
    humanName: "Electron",
    heldSeconds: 110_288
  )

  let diagnosis = SleepDiagnosis(observations: [observation], sleepDisabledSetting: false)

  Harness.expect(diagnosis.systemSleepIsBlocked, "NoIdleSleepAssertion must block system sleep")
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

func testDisplaySleepAssertionAlsoBlocksSystemIdleSleep() {
  // IOPMLib.h, kIOPMAssertPreventUserIdleDisplaySleep:
  // "While the display is prevented from dimming, the system cannot go into idle sleep."
  let observation = AssertionObservation(
    assertionID: 5, pid: 700, processName: "Video", rawType: "PreventUserIdleDisplaySleep",
    humanName: "playback", heldSeconds: 60)

  let diagnosis = SleepDiagnosis(observations: [observation], sleepDisabledSetting: false)

  Harness.expect(diagnosis.systemSleepIsBlocked, "display assertion blocks system idle sleep")
  Harness.equal(diagnosis.systemSleepBlockers.count, 1, "display assertion is a blocker")
  Harness.equal(diagnosis.unclassifiedAssertions.count, 0, "known type is not unclassified")
}

func testKnownNonBlockingAssertionTypesAreNotReportedAsBlockers() {
  let observations = [
    AssertionObservation(
      assertionID: 1, pid: 1, processName: "a", rawType: "PreventDiskIdle", humanName: "",
      heldSeconds: 1),
    AssertionObservation(
      assertionID: 2, pid: 2, processName: "b", rawType: "UserIsActive", humanName: "",
      heldSeconds: 1),
    AssertionObservation(
      assertionID: 3, pid: 3, processName: "c", rawType: "NetworkClientActive", humanName: "",
      heldSeconds: 1),
  ]

  let diagnosis = SleepDiagnosis(observations: observations, sleepDisabledSetting: false)

  Harness.equal(diagnosis.systemSleepBlockers.count, 0, "no idle-sleep blockers")
  Harness.equal(diagnosis.unclassifiedAssertions.count, 0, "all types are known")
  Harness.expect(!diagnosis.systemSleepIsBlocked, "sleep is not blocked")
}

func testUnknownAssertionTypeIsUnclassifiedAndMakesTheAnswerUncertain() {
  let observation = AssertionObservation(
    assertionID: 9, pid: 900, processName: "Mystery", rawType: "SomeFutureAssertionType",
    humanName: "", heldSeconds: 30)

  let diagnosis = SleepDiagnosis(observations: [observation], sleepDisabledSetting: false)

  Harness.equal(diagnosis.unclassifiedAssertions.count, 1, "unknown type is unclassified")
  Harness.expect(
    !diagnosis.canProveSleepIsUnblocked,
    "an unknown assertion type must not yield a confident clean result")
}

func testSleepDisabledSettingIsTriStateSoAFailedLookupIsNotReportedAsFalse() {
  let unknown = SleepDiagnosis(observations: [], sleepDisabledSetting: nil)
  Harness.expect(
    !unknown.canProveSleepIsUnblocked, "unknown SleepDisabled must not yield a clean result")

  let known = SleepDiagnosis(observations: [], sleepDisabledSetting: false)
  Harness.expect(known.canProveSleepIsUnblocked, "fully known empty state is provably clean")

  let disabled = SleepDiagnosis(observations: [], sleepDisabledSetting: true)
  Harness.expect(disabled.systemSleepIsBlocked, "SleepDisabled=1 blocks sleep")
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
  do {
    _ = try IOKitAssertionReader.decodeSnapshot(rawTable: "not a dictionary", now: Date())
    Harness.expect(false, "an uncastable IOKit payload must throw, not return a clean snapshot")
  } catch AssertionReadError.unexpectedShape {
    Harness.expect(true, "unexpectedShape thrown")
  } catch {
    Harness.expect(false, "expected unexpectedShape, got \(error)")
  }
}

func testLiveIOKitSnapshotIsReadableAndSelfConsistent() {
  // Real integration: reads live IOKit power-assertion state. Read-only, no mutation.
  guard let snapshot = try? IOKitAssertionReader().snapshot() else {
    Harness.expect(false, "IOKitAssertionReader.snapshot() must succeed on macOS")
    return
  }

  for observation in snapshot.observations {
    Harness.expect(!observation.rawType.isEmpty, "live assertion type must be non-empty")
    Harness.expect(observation.pid > 0, "live assertion pid must be positive")
    if let held = observation.heldSeconds {
      Harness.expect(held >= 0, "held duration must be non-negative")
    }
  }

  // This process holds no assertion, so it must never appear as its own blocker.
  let selfPID = ProcessInfo.processInfo.processIdentifier
  let diagnosis = SleepDiagnosis(
    observations: snapshot.observations, sleepDisabledSetting: false)
  Harness.expect(
    !diagnosis.systemSleepBlockers.contains(where: { $0.pid == selfPID }),
    "the inspector must not report itself as a sleep blocker")
}

func testLiveSleepDisabledLookupReturnsAKnownValueOnThisHost() {
  // IOPMrootDomain always publishes SleepDisabled on macOS, so a nil here means
  // the lookup broke rather than that sleep is enabled.
  let setting = IOKitAssertionReader().sleepDisabledSetting()
  Harness.expect(setting != nil, "SleepDisabled must resolve to a known boolean on macOS")
}

testNoIdleSleepAssertionIsReportedAsASystemSleepBlocker()
testDecodingIOKitAssertionsByProcessProducesObservations()
testMalformedAssertionRecordMarksResultIncompleteWithoutDroppingValidEvidence()
testDisplaySleepAssertionAlsoBlocksSystemIdleSleep()
testKnownNonBlockingAssertionTypesAreNotReportedAsBlockers()
testUnknownAssertionTypeIsUnclassifiedAndMakesTheAnswerUncertain()
testSleepDisabledSettingIsTriStateSoAFailedLookupIsNotReportedAsFalse()
testMissingStartTimestampYieldsUnknownDurationRatherThanZero()
testNegativeAssertionIdentifierIsRejectedAsMalformed()
testUnexpectedIOKitDictionaryShapeThrowsInsteadOfReportingACleanScan()
testLiveIOKitSnapshotIsReadableAndSelfConsistent()
testLiveSleepDisabledLookupReturnsAKnownValueOnThisHost()
Harness.finish()
