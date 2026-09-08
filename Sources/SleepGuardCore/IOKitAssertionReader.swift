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
///
/// `Sendable` is accurate rather than decorative: this struct has no stored
/// properties at all. Every IOKit handle it touches is created, used and
/// released inside a single method body, so no non-`Sendable` Foundation or
/// CoreFoundation object is ever held across a suspension or shared between
/// isolation domains.
public struct IOKitAssertionReader: Sendable {
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

  /// Reads the kernel driver assertion view from `IOPMrootDomain`.
  ///
  /// Read-only, like every other method here. Two documented `IOPM.h` registry
  /// keys: `kIOPMAssertionsDriverKey` ("DriverPMAssertions", the aggregate
  /// bitfield) and `kIOPMAssertionsDriverDetailedKey`
  /// ("DriverPMAssertionsDetailed", the per-record array with an `Owner`).
  ///
  /// This is the coverage that `IOPMCopyAssertionsStatus` was measured *not* to
  /// provide: `kIOPMDriverAssertionPreventSystemIdleSleepBit` is header-cited
  /// as preventing idle sleep, and the detailed array names the driver holding
  /// it.
  ///
  /// A failed read degrades to an incomplete view rather than throwing, so it
  /// reduces the confidence of the report instead of destroying an otherwise
  /// valid process-held scan. An unreadable property is never reported as
  /// "no driver asserts".
  public func driverAssertionStatus() -> DriverAssertionStatus {
    let root = IOServiceGetMatchingService(
      kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
    guard root != 0 else {
      return DriverAssertionStatus.decode(aggregateValue: nil, detailedValue: nil)
    }
    defer { IOObjectRelease(root) }

    // Read the detailed array FIRST, then the aggregate bitfield. The two
    // properties are read non-atomically, so a driver asserting between the two
    // reads must not appear as an aggregate bit with no owning record — which
    // would be reported as an unattributed kernel blocker. Reading detail first
    // means a mid-scan acquisition instead surfaces as a record whose bits are
    // missing from the aggregate; that direction is also flagged as a mismatch,
    // and both directions fail closed, so ordering cannot produce a *clean*
    // answer either way.
    let detailed = IORegistryEntryCreateCFProperty(
      root, "DriverPMAssertionsDetailed" as CFString, kCFAllocatorDefault, 0
    )?.takeRetainedValue()
    let aggregate = IORegistryEntryCreateCFProperty(
      root, "DriverPMAssertions" as CFString, kCFAllocatorDefault, 0
    )?.takeRetainedValue()

    return DriverAssertionStatus.decode(aggregateValue: aggregate, detailedValue: detailed)
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
