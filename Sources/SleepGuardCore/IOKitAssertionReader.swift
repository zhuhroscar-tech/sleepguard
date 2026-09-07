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
    guard let raw = unmanaged?.takeRetainedValue() as? [AnyHashable: Any] else {
      // No assertions at all is a legitimate empty snapshot.
      return DecodedAssertions(observations: [], malformedRecordCount: 0)
    }

    var normalized: [Int32: [[String: Any]]] = [:]
    var malformedTopLevel = 0
    for (key, value) in raw {
      guard
        let pidNumber = key as? NSNumber,
        let records = value as? [[String: Any]]
      else {
        malformedTopLevel += 1
        continue
      }
      normalized[pidNumber.int32Value, default: []].append(contentsOf: records)
    }

    let decoded = AssertionDecoder.decode(assertionsByProcess: normalized, now: now)
    return DecodedAssertions(
      observations: decoded.observations,
      malformedRecordCount: decoded.malformedRecordCount + malformedTopLevel
    )
  }

  /// Reads the standing `SleepDisabled` system setting, which is not an assertion.
  public func sleepDisabledSetting() -> Bool {
    let root = IOServiceGetMatchingService(
      kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
    guard root != 0 else { return false }
    defer { IOObjectRelease(root) }
    guard
      let value = IORegistryEntryCreateCFProperty(
        root, "SleepDisabled" as CFString, kCFAllocatorDefault, 0
      )?.takeRetainedValue()
    else { return false }
    if let boolean = value as? Bool { return boolean }
    if let number = value as? NSNumber { return number.boolValue }
    return false
  }
}
