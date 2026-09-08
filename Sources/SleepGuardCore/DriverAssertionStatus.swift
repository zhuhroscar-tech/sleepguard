import Foundation

/// One kernel driver power-management assertion record, as published by
/// `IOPMrootDomain`'s `DriverPMAssertionsDetailed` property.
///
/// This is an *observation*, exactly like `AssertionObservation`: the owning
/// driver may release the assertion at any moment. Nothing here is ever acted
/// upon — `sleepguard` has no code path that mutates a driver assertion.
public struct DriverAssertionRecord: Equatable, Sendable {
  /// `kIOPMDriverAssertionIDKey`.
  public let id: UInt64
  /// `kIOPMDriverAssertionOwnerStringKey` — the driver's own name string.
  public let owner: String
  /// `kIOPMDriverAssertionLevelKey`. Greater than zero means asserted.
  public let level: Int
  /// `kIOPMDriverAssertionAssertedKey` — the bitfield of `kIOPMDriverAssertion*Bit`
  /// values this record asserts.
  public let bits: Int

  public init(id: UInt64, owner: String, level: Int, bits: Int) {
    self.id = id
    self.owner = owner
    self.level = level
    self.bits = bits
  }
}

/// Decoded form of the kernel driver assertion view: the `DriverPMAssertions`
/// aggregate bitfield plus the `DriverPMAssertionsDetailed` per-record array on
/// `IOPMrootDomain`.
///
/// **Why this type exists.** `IOPMCopyAssertionsStatus` was measured on
/// macOS 15.7.4 *not* to expose kernel-held sleep preventers at all (see
/// `AggregateAssertionStatus`). These two `IOPMrootDomain` registry keys are the
/// documented public route to that data: `IOPM.h` defines
/// `kIOPMAssertionsDriverKey` / `kIOPMAssertionsDriverDetailedKey` and the
/// `kIOPMDriverAssertion*Bit` enumeration, and it states of bit `0x02`
/// `kIOPMDriverAssertionPreventSystemIdleSleepBit`: *"When set, the system
/// should not idle sleep. This does not prevent demand sleep."* That is a
/// citable idle-sleep statement, so this view can name a kernel idle-sleep
/// blocker that the assertion-subsystem APIs cannot.
///
/// **What it still does not cover.** The `Idle sleep preventers:` line in
/// `pmset -g assertions` (for example `IODisplayWrangler`) is a separate
/// power-plane concept and is *not* a driver assertion; nothing here exposes it.
/// Bits other than `0x02` carry no `IOPM.h` statement about idle sleep in either
/// direction, so an asserted record holding only those bits is reported as
/// **unknown-effect** and marks the view incomplete. It is never certified
/// harmless.
public struct DriverAssertionStatus: Sendable {
  /// The aggregate `DriverPMAssertions` bitfield, or `nil` when it could not be
  /// read as a usable non-negative integer. `nil` is *not* collapsed to `0`:
  /// "I could not read it" must never be reported as "no driver asserts".
  public let aggregateBits: Int?
  /// Every well-formed record, asserted or not.
  public let records: [DriverAssertionRecord]
  /// Records, entries, or payloads that could not be decoded. A nonzero count
  /// means this view is partial and cannot prove an absence.
  public let malformedRecordCount: Int
  /// True when the detailed array itself was missing or of the wrong shape.
  public let detailedPayloadWasUnreadable: Bool

  public init(
    aggregateBits: Int?,
    records: [DriverAssertionRecord],
    malformedRecordCount: Int,
    detailedPayloadWasUnreadable: Bool
  ) {
    self.aggregateBits = aggregateBits
    self.records = records
    self.malformedRecordCount = malformedRecordCount
    self.detailedPayloadWasUnreadable = detailedPayloadWasUnreadable
  }

  // MARK: - Header-cited classification

  /// The only driver assertion bit with a citable `IOPM.h` idle-sleep
  /// statement: *"When set, the system should not idle sleep."*
  public static let preventSystemIdleSleepBit = 0x02

  /// Documented names for every bit in the `IOPM.h` enumeration. Used for
  /// output only; an unlisted bit is rendered as its hex value.
  static let bitNameTable: [(bit: Int, name: String)] = [
    (0x01, "CPU"),
    (0x02, "PreventSystemIdleSleep"),
    (0x04, "USBExternalDevice"),
    (0x08, "BluetoothHIDDevicePaired"),
    (0x10, "ExternalMediaMounted"),
    (0x20, "ReservedBit5"),
    (0x40, "PreventDisplaySleep"),
    (0x80, "ReservedBit7"),
    (0x100, "MagicPacketWakeEnabled"),
    (0x200, "NetworkKeepAliveActive"),
  ]

  /// Documented `IOPM.h` names of the set bits in `bits`, ascending. Bits with
  /// no entry in the header enumeration are rendered as `unknown(0x…)` rather
  /// than dropped, so an unrecognized bit can never vanish from the report.
  ///
  /// A negative input cannot come from `decode` (which rejects negatives), but
  /// this method is public, so a negative is rendered explicitly rather than
  /// silently returning an empty list — an empty list reads as "nothing set",
  /// which is exactly the fail-open answer this project forbids.
  public func bitNames(_ bits: Int) -> [String] {
    if bits < 0 { return ["invalid(\(bits))"] }
    guard bits > 0 else { return [] }
    var names: [String] = []
    var unaccounted = bits
    for entry in Self.bitNameTable where bits & entry.bit != 0 {
      names.append(entry.name)
      unaccounted &= ~entry.bit
    }
    if unaccounted != 0 {
      names.append("unknown(0x" + String(unaccounted, radix: 16) + ")")
    }
    return names
  }

  // MARK: - Derived views

  /// Records currently asserted (`Level > 0`), sorted by owner then ID for
  /// stable output. A `Level` of zero means the driver is *not* asserting, so
  /// such records are deliberately excluded from every finding below.
  public var assertedRecords: [DriverAssertionRecord] {
    records.filter { $0.level > 0 }
      .sorted { ($0.owner, $0.id) < ($1.owner, $1.id) }
  }

  /// Asserted records holding `kIOPMDriverAssertionPreventSystemIdleSleepBit`.
  /// These are genuine, header-cited kernel idle-sleep blockers *with an owner
  /// name* — the coverage gap the assertion-subsystem APIs could not close.
  public var documentedIdleSleepBlockers: [DriverAssertionRecord] {
    assertedRecords.filter { $0.bits & Self.preventSystemIdleSleepBit != 0 }
  }

  /// Asserted records holding at least one bit with no `IOPM.h` statement about
  /// idle sleep. Their effect is unknown, so they make this view incomplete
  /// rather than being enumerated as harmless.
  public var unclassifiedAssertedRecords: [DriverAssertionRecord] {
    assertedRecords.filter { $0.bits & ~Self.preventSystemIdleSleepBit != 0 }
  }

  /// Union of the bits claimed by asserted records.
  var assertedRecordBits: Int {
    assertedRecords.reduce(0) { $0 | $1.bits }
  }

  /// Bits set in the aggregate bitfield that no asserted record accounts for.
  ///
  /// Nonzero means the kernel says *something* is asserted that this view
  /// cannot name — an unreadable record, or a record the detailed array did not
  /// publish. It fails closed.
  ///
  /// When the aggregate bitfield itself is unreadable this is `0`, because no
  /// bit is *known* to be set; `aggregateBits == nil` already forces
  /// incompleteness on its own.
  public var unattributedAssertedBits: Int {
    guard let aggregateBits else { return 0 }
    return aggregateBits & ~assertedRecordBits
  }

  /// Bits an asserted record claims that are absent from the aggregate
  /// bitfield. This direction is also a mismatch: the two properties are
  /// supposed to describe the same kernel state, so disagreement means at least
  /// one of them was read inconsistently.
  public var recordBitsMissingFromAggregate: Int {
    guard let aggregateBits else { return 0 }
    return assertedRecordBits & ~aggregateBits
  }

  /// True only when this whole kernel view decoded consistently: the aggregate
  /// bitfield was readable, the detailed array was readable, no record was
  /// malformed, and the two views reconcile in both directions.
  public var isComplete: Bool {
    aggregateBits != nil
      && !detailedPayloadWasUnreadable
      && malformedRecordCount == 0
      && unattributedAssertedBits == 0
      && recordBitsMissingFromAggregate == 0
  }

  // MARK: - Decoding

  /// Pure decoder for the two `IOPMrootDomain` property values. Kept free of
  /// IOKit so it is deterministically testable without live system state.
  ///
  /// Fail-closed rules, all of which mark the view incomplete rather than
  /// yielding a clean answer:
  /// * a missing, Boolean, non-numeric, or negative aggregate bitfield;
  /// * a missing or non-array detailed payload;
  /// * any record that is not a dictionary, or that lacks a usable `ID`,
  ///   nonblank `Owner`, `Level`, or `Assertions` field.
  ///
  /// One malformed record never discards the valid ones: partial evidence is
  /// preserved alongside the incompleteness flag.
  public static func decode(aggregateValue: Any?, detailedValue: Any?) -> DriverAssertionStatus {
    let bits = decodeNonNegativeInt(aggregateValue)

    guard let rawArray = detailedValue as? [Any] else {
      return DriverAssertionStatus(
        aggregateBits: bits,
        records: [],
        malformedRecordCount: 1,
        detailedPayloadWasUnreadable: true)
    }

    var records: [DriverAssertionRecord] = []
    var malformed = 0
    for element in rawArray {
      guard
        let dictionary = element as? [String: Any],
        let id = decodeNonNegativeInt(dictionary["ID"]),
        let owner = (dictionary["Owner"] as? String)?
          .trimmingCharacters(in: .whitespacesAndNewlines),
        !owner.isEmpty,
        let level = decodeNonNegativeInt(dictionary["Level"]),
        let recordBits = decodeNonNegativeInt(dictionary["Assertions"])
      else {
        malformed += 1
        continue
      }
      records.append(
        DriverAssertionRecord(id: UInt64(id), owner: owner, level: level, bits: recordBits))
    }

    return DriverAssertionStatus(
      aggregateBits: bits,
      records: records,
      malformedRecordCount: malformed,
      detailedPayloadWasUnreadable: false)
  }

  /// Decodes a non-negative integer, rejecting absence, non-numbers, Booleans
  /// (a `CFBoolean` would otherwise bridge silently to 0/1), negatives (a
  /// bitfield or level is never negative, and must not read as "nothing set"),
  /// and any value that is not exactly representable as an `Int`.
  ///
  /// That last check matters: `NSNumber.intValue` silently truncates. A
  /// fractional `4.7` would become `4` and a `UInt64` above `Int.max` would
  /// become a negative — either would fabricate a bitfield or level the kernel
  /// never reported. Requiring `intValue` to round-trip through `int64Value`
  /// *and* `doubleValue` rejects both without trusting the truncation.
  static func decodeNonNegativeInt(_ value: Any?) -> Int? {
    guard
      let number = value as? NSNumber,
      CFGetTypeID(number) != CFBooleanGetTypeID()
    else { return nil }
    let candidate = number.intValue
    guard
      candidate >= 0,
      Int64(candidate) == number.int64Value,
      Double(candidate) == number.doubleValue
    else { return nil }
    return candidate
  }
}
