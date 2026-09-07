import Foundation

/// Decoded form of the system-wide aggregate assertion table
/// (`IOPMCopyAssertionsStatus`).
///
/// This table reports one level per assertion *type* for the whole system,
/// without naming an owner.
///
/// **What it is not.** Measured on macOS 15.7.4, this table aggregates the same
/// assertion accounting as `IOPMCopyAssertionsByProcess`: with three active
/// kernel USB assertions and `IODisplayWrangler` listed as an active idle-sleep
/// preventer by `pmset -g assertions`, no key in this table changed. IOPMLib.h
/// documents nothing about kernel contribution to these levels, so per this
/// project's citation-only rule, kernel-held preventers must still be treated as
/// structurally invisible. This table is used only to notice a sleep-blocking
/// type asserted through the assertion subsystem that no *readable* process
/// record accounts for — an unreadable record, or a holder the by-process
/// enumeration missed.
public struct AggregateAssertionStatus: Sendable {
  /// Level per assertion type, exactly as reported. A level greater than zero
  /// means that type is currently asserted somewhere on the system.
  public let levels: [String: Int]
  /// Entries whose key or value had an unusable type. A malformed entry means
  /// the aggregate view is partial, so it cannot prove an absence.
  public let malformedEntryCount: Int
  /// True when IOKit reported success but returned no table at all. Not
  /// documented as meaning "nothing is asserted", so it is unproven.
  public let sourceTableWasNull: Bool

  /// True when the table came back with no entries at all. macOS publishes a
  /// fixed set of aggregate keys, so an empty table is a failed read.
  public var hasImplausiblyEmptyTable: Bool {
    levels.isEmpty && malformedEntryCount == 0 && !sourceTableWasNull
  }

  public var isComplete: Bool {
    malformedEntryCount == 0 && !sourceTableWasNull && !hasImplausiblyEmptyTable
  }

  public init(
    levels: [String: Int],
    malformedEntryCount: Int,
    sourceTableWasNull: Bool = false
  ) {
    self.levels = levels
    self.malformedEntryCount = malformedEntryCount
    self.sourceTableWasNull = sourceTableWasNull
  }

  /// Assertion types this build classifies as blocking idle sleep that are
  /// currently asserted somewhere on the system, sorted for stable output.
  public var activeBlockingTypes: [String] {
    levels.filter { SleepDiagnosis.systemSleepBlockingTypes.contains($0.key) && $0.value > 0 }
      .keys.sorted()
  }

  /// Pure decoder for the aggregate dictionary shape. Kept free of IOKit so it
  /// is deterministically testable without live system state.
  public static func decode(rawTable: Any?) -> AggregateAssertionStatus {
    guard let rawTable else {
      return AggregateAssertionStatus(
        levels: [:], malformedEntryCount: 0, sourceTableWasNull: true)
    }
    guard let table = rawTable as? [AnyHashable: Any] else {
      return AggregateAssertionStatus(levels: [:], malformedEntryCount: 1)
    }

    var levels: [String: Int] = [:]
    var malformed = 0
    for (key, value) in table {
      guard
        let name = (key as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
        !name.isEmpty,
        let number = value as? NSNumber,
        // A Boolean is not a level; CFBoolean would silently bridge to 0/1.
        CFGetTypeID(number) != CFBooleanGetTypeID(),
        // A level is a count of active assertions; a negative value is
        // nonsensical and must not be silently read as "not asserted".
        number.intValue >= 0
      else {
        malformed += 1
        continue
      }
      levels[name] = number.intValue
    }
    return AggregateAssertionStatus(levels: levels, malformedEntryCount: malformed)
  }
}
