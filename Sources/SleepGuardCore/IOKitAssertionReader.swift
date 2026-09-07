import Foundation
import IOKit
import IOKit.pwr_mgt

public enum AssertionReadError: Error, CustomStringConvertible {
  case ioKitFailure(IOReturn)
  case unexpectedShape

  public var description: String {
    switch self {
    case .ioKitFailure(let code): return "IOKit returned status \(code)"
    case .unexpectedShape: return "IOKit returned an unexpected data shape"
    }
  }
}

/// Read-only adapter over the documented IOKit power-management API.
///
/// Safety boundary: this type only *reads*. It never creates, releases, or
/// otherwise mutates an assertion, and never signals or terminates a process.
public struct IOKitAssertionReader {
  public init() {}

  public func snapshot(now: Date = Date()) throws -> DecodedAssertions {
    var unmanaged: Unmanaged<CFDictionary>?
    let status = IOPMCopyAssertionsByProcess(&unmanaged)
    guard status == kIOReturnSuccess else { throw AssertionReadError.ioKitFailure(status) }

    guard let table = unmanaged?.takeRetainedValue() else {
      // IOPMLib.h documents only kIOReturnSuccess and a per-PID dictionary; it
      // never states that NULL means "no assertions". Treat it as unproven.
      return DecodedAssertions(
        observations: [], malformedRecordCount: 0, sourceTableWasNull: true)
    }
    return try Self.decodeSnapshot(rawTable: table, now: now)
  }

  /// Pure, testable decoding of an already-retrieved IOKit payload.
  ///
  /// A payload that is not the documented `[pid: [record]]` shape throws
  /// `unexpectedShape`; it must never degrade into an empty "clean" snapshot.
  public static func decodeSnapshot(rawTable: Any, now: Date) throws -> DecodedAssertions {
    guard let raw = rawTable as? [AnyHashable: Any] else {
      throw AssertionReadError.unexpectedShape
    }

    var normalized: [Int32: [[String: Any]]] = [:]
    var malformedTopLevel = 0
    for (key, value) in raw {
      guard let pidNumber = key as? NSNumber, let elements = value as? [Any] else {
        malformedTopLevel += 1
        continue
      }
      // Cast per element so one bad record does not discard a PID's valid ones.
      for element in elements {
        if let record = element as? [String: Any] {
          normalized[pidNumber.int32Value, default: []].append(record)
        } else {
          malformedTopLevel += 1
        }
      }
    }

    let decoded = AssertionDecoder.decode(assertionsByProcess: normalized, now: now)
    return DecodedAssertions(
      observations: decoded.observations,
      malformedRecordCount: decoded.malformedRecordCount + malformedTopLevel,
      sourceTableWasNull: false
    )
  }

  /// Reads the system-wide aggregate assertion table.
  ///
  /// Read-only, like every other method here. This is the documented public way
  /// to notice that *something* is asserting a sleep-blocking type even when no
  /// process-held record accounts for it. It carries no owner information and is
  /// never used to attribute a blocker to a process.
  ///
  /// An IOKit failure is reported as a malformed (incomplete) result rather than
  /// throwing, so a failed aggregate read degrades the confidence of the report
  /// instead of destroying an otherwise valid process-held scan.
  public func aggregateStatus() -> AggregateAssertionStatus {
    var unmanaged: Unmanaged<CFDictionary>?
    let status = IOPMCopyAssertionsStatus(&unmanaged)
    guard status == kIOReturnSuccess else {
      return AggregateAssertionStatus(levels: [:], malformedEntryCount: 1)
    }
    guard let table = unmanaged?.takeRetainedValue() else {
      return AggregateAssertionStatus.decode(rawTable: nil)
    }
    return AggregateAssertionStatus.decode(rawTable: table)
  }

  /// Reads the standing `SleepDisabled` system setting, which is not an assertion.
  ///
  /// Returns `nil` when the value could not be read at all, so a failed lookup
  /// is never reported as "sleep is not disabled".
  public func sleepDisabledSetting() -> Bool? {
    let root = IOServiceGetMatchingService(
      kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
    guard root != 0 else { return nil }
    defer { IOObjectRelease(root) }
    guard
      let value = IORegistryEntryCreateCFProperty(
        root, "SleepDisabled" as CFString, kCFAllocatorDefault, 0
      )?.takeRetainedValue()
    else { return nil }
    if let boolean = value as? Bool { return boolean }
    if let number = value as? NSNumber { return number.boolValue }
    return nil
  }
}
