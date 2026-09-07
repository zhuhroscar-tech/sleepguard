import Foundation

/// Result of decoding a raw IOKit assertion snapshot.
///
/// Completeness is reported separately from evidence: a malformed record never
/// silently becomes a clean scan, and valid records are still preserved.
public struct DecodedAssertions: Sendable {
  public let observations: [AssertionObservation]
  public let malformedRecordCount: Int
  /// True when IOKit reported success but handed back no table at all. IOPMLib.h
  /// does not document NULL as meaning "no assertions", so this is an unproven
  /// empty result, not a clean one.
  public let sourceTableWasNull: Bool

  public var isComplete: Bool { malformedRecordCount == 0 && !sourceTableWasNull }

  public init(
    observations: [AssertionObservation],
    malformedRecordCount: Int,
    sourceTableWasNull: Bool = false
  ) {
    self.observations = observations
    self.malformedRecordCount = malformedRecordCount
    self.sourceTableWasNull = sourceTableWasNull
  }
}

/// Pure decoder for the dictionary shape returned by `IOPMCopyAssertionsByProcess`.
/// Kept free of IOKit so it is deterministically testable without live system state.
public enum AssertionDecoder {
  static let idKey = "AssertionId"
  static let typeKey = "AssertType"
  static let nameKey = "AssertName"
  static let processNameKey = "Process Name"
  static let startKey = "AssertStartWhen"

  public static func decode(
    assertionsByProcess: [Int32: [[String: Any]]],
    now: Date
  ) -> DecodedAssertions {
    var observations: [AssertionObservation] = []
    var malformed = 0

    for pid in assertionsByProcess.keys.sorted() {
      guard let records = assertionsByProcess[pid] else { continue }
      for record in records {
        guard
          let rawType = nonBlankString(record[typeKey]),
          let assertionID = unsignedInteger(record[idKey])
        else {
          malformed += 1
          continue
        }

        let humanName = nonBlankString(record[nameKey]) ?? ""
        let processName = nonBlankString(record[processNameKey]) ?? "pid \(pid)"
        var heldSeconds: Int?
        if let start = record[startKey] as? Date {
          heldSeconds = max(0, Int(now.timeIntervalSince(start)))
        }

        observations.append(
          AssertionObservation(
            assertionID: assertionID,
            pid: pid,
            processName: processName,
            rawType: rawType,
            humanName: humanName,
            heldSeconds: heldSeconds
          )
        )
      }
    }

    return DecodedAssertions(observations: observations, malformedRecordCount: malformed)
  }

  private static func nonBlankString(_ value: Any?) -> String? {
    guard let string = value as? String else { return nil }
    let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
  }

  private static func unsignedInteger(_ value: Any?) -> UInt64? {
    if let number = value as? UInt64 { return number }
    if let number = value as? NSNumber {
      // Reject negatives rather than wrapping them into a huge UInt64.
      guard number.int64Value >= 0 else { return nil }
      return number.uint64Value
    }
    return nil
  }
}
