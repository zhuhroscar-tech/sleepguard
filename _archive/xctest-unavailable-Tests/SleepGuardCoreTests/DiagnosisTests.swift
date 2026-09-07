import XCTest

@testable import SleepGuardCore

final class DiagnosisTests: XCTestCase {
  func testNoIdleSleepAssertionIsReportedAsASystemSleepBlocker() throws {
    let observation = AssertionObservation(
      assertionID: 0x000d_fae9_0001_870f,
      pid: 1437,
      processName: "ChatGPT",
      rawType: "NoIdleSleepAssertion",
      humanName: "Electron",
      heldSeconds: 110_288
    )

    let diagnosis = SleepDiagnosis(observations: [observation], sleepDisabledSetting: false)

    XCTAssertTrue(diagnosis.systemSleepIsBlocked)
    XCTAssertEqual(diagnosis.systemSleepBlockers.map(\.processName), ["ChatGPT"])
  }
}
