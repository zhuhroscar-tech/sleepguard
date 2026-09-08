import Foundation

/// The seam between the presentation layer and live system state.
///
/// Every IOKit call sits behind this protocol so the runner's policy — how the
/// four reads are combined into one report — is testable with deterministic
/// fakes that never consult the host.
///
/// The four reads are separate members rather than one aggregate call because
/// they fail independently: the process snapshot can throw while the aggregate
/// table and kernel driver view are still readable, and each carries its own
/// completeness state. Collapsing them would lose the partial evidence that
/// `SleepGuardCore` is built to preserve.
///
/// `Sendable` is required here for a real reason, not for appearance: the
/// menu-bar surface performs the synchronous IOKit reads off the main actor so
/// the UI does not block, which genuinely moves a source value across an
/// isolation boundary. Conformers must therefore hold no mutable or
/// non-`Sendable` state; `LiveSleepScanSource` is a stateless struct.
public protocol SleepScanSource: Sendable {
  /// Throws on an unreadable or unexpectedly shaped payload. A throw is a read
  /// failure, never an empty result.
  func readSnapshot() throws -> DecodedAssertions
  func readAggregate() -> AggregateAssertionStatus
  func readDriver() -> DriverAssertionStatus
  /// Nil means the standing setting could not be read.
  func readSleepDisabledSetting() -> Bool?
}

/// Live adapter over `IOKitAssertionReader`. Read-only: it never asserts,
/// releases, terminates or signals anything.
public struct LiveSleepScanSource: SleepScanSource {
  private let reader: IOKitAssertionReader

  public init(reader: IOKitAssertionReader = IOKitAssertionReader()) {
    self.reader = reader
  }

  public func readSnapshot() throws -> DecodedAssertions { try reader.snapshot() }
  public func readAggregate() -> AggregateAssertionStatus { reader.aggregateStatus() }
  public func readDriver() -> DriverAssertionStatus { reader.driverAssertionStatus() }
  public func readSleepDisabledSetting() -> Bool? { reader.sleepDisabledSetting() }
}

/// Combines the four reads into one `ScanOutcome`.
///
/// The only policy here is: a throwing snapshot read is a failure outcome, and
/// otherwise the decoder's own completeness flag is carried into the diagnosis
/// via the `snapshot:` initializer so the two cannot drift apart.
public struct SleepScanRunner: Sendable {
  private let source: SleepScanSource

  public init(source: SleepScanSource) {
    self.source = source
  }

  public func scan() -> ScanOutcome {
    let snapshot: DecodedAssertions
    do {
      snapshot = try source.readSnapshot()
    } catch {
      return .failure(String(describing: error))
    }
    let diagnosis = SleepDiagnosis(
      snapshot: snapshot,
      sleepDisabledSetting: source.readSleepDisabledSetting())
    return .success(
      SleepScanReport(
        diagnosis: diagnosis,
        aggregate: source.readAggregate(),
        driver: source.readDriver()))
  }
}
