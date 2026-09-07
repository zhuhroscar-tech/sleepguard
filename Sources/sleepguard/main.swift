import Foundation
import SleepGuardCore

/// sleepguard — read-only explanation of why this Mac will not idle-sleep.
///
/// Non-goals (enforced by design): never kills, signals, force-quits, elevates,
/// changes power settings, or sends anything over the network.

func formatHeld(_ seconds: Int?) -> String {
  guard let seconds else { return "unknown" }
  return "\(seconds / 3600)h \((seconds % 3600) / 60)m"
}

let reader = IOKitAssertionReader()

do {
  // Read the aggregate table BEFORE the process snapshot. An assertion acquired
  // between the two reads would otherwise appear in the aggregate with no
  // process record and be misreported as unattributed. Reading the aggregate
  // first means a mid-scan acquisition shows up as an extra *process* record
  // instead, which is harmless. A surviving mismatch is then re-checked against
  // a second aggregate read before any unattributed claim is made.
  let firstAggregate = reader.aggregateStatus()
  let snapshot = try reader.snapshot()
  let sleepDisabled = reader.sleepDisabledSetting()
  let diagnosis = SleepDiagnosis(snapshot: snapshot, sleepDisabledSetting: sleepDisabled)

  var aggregate = firstAggregate
  var unattributed = diagnosis.unattributedBlockingTypes(aggregate: firstAggregate)
  if !unattributed.isEmpty {
    // Confirm against a fresh read; a transient acquisition must not be
    // reported as an unexplained blocker.
    let secondAggregate = reader.aggregateStatus()
    let confirmed = diagnosis.unattributedBlockingTypes(aggregate: secondAggregate)
    aggregate = secondAggregate
    unattributed = unattributed.filter { confirmed.contains($0) }
  }

  print("sleepguard — read-only sleep-blocker inspector (prototype)")
  print("scanned: \(ISO8601DateFormatter().string(from: Date()))")
  print("")

  // Uncertainty is reported BEFORE any findings, so a reader who stops at the
  // top of the output never sees a clean claim without its retraction.
  var uncertain = false

  if snapshot.sourceTableWasNull {
    uncertain = true
    print(
      "WARNING: IOKit returned success but no assertion table. IOPMLib.h does not "
        + "document this as meaning \"no assertions\", so this scan is INCOMPLETE.")
  }
  if snapshot.hasImplausiblyEmptyTable {
    uncertain = true
    print(
      "WARNING: IOKit returned an assertion table with no entries. A running Mac always "
        + "holds at least one process assertion, so this indicates a failed or restricted "
        + "read, not an idle system. This scan is INCOMPLETE.")
  }
  if snapshot.malformedRecordCount > 0 {
    uncertain = true
    print(
      "WARNING: \(snapshot.malformedRecordCount) assertion record(s) could not be decoded. "
        + "This scan is INCOMPLETE.")
  }
  if !aggregate.isComplete {
    uncertain = true
    print(
      "WARNING: the system-wide aggregate assertion table could not be read completely, "
        + "so a sleep blocker with no process-held record could go unnoticed. "
        + "This scan is INCOMPLETE.")
  }
  if !unattributed.isEmpty {
    uncertain = true
    print(
      "WARNING: the assertion subsystem reports more holders of \(unattributed.count) "
        + "sleep-blocking type(s) than this scan could attribute to a readable process "
        + "record. The extra holder cannot be named:")
    for type in unattributed {
      print("  ! \(type) — asserted system-wide, owner unaccounted for")
    }
    print("  Run `pmset -g assertions` for the authoritative full listing.")
  }
  let novelTypes = diagnosis.novelUnclassifiedAggregateTypes(aggregate: aggregate)
  if !novelTypes.isEmpty {
    uncertain = true
    print(
      "WARNING: \(novelTypes.count) system-wide assertion type(s) are active but have no citable "
        + "IOPMLib.h classification in this build; their effect on sleep is unknown: "
        + novelTypes.joined(separator: ", "))
  }
  if sleepDisabled == nil {
    uncertain = true
    print("WARNING: could not read the standing SleepDisabled setting. This scan is INCOMPLETE.")
  }
  if !diagnosis.unclassifiedAssertions.isEmpty {
    uncertain = true
    print(
      "WARNING: \(diagnosis.unclassifiedAssertions.count) assertion(s) have a type this build "
        + "does not recognize; their effect on sleep is unknown:")
    for observation in diagnosis.unclassifiedAssertions {
      print("  ? \(observation.processName) (pid \(observation.pid)) — \(observation.rawType)")
    }
  }
  if uncertain {
    print("An incomplete scan is NOT proof that nothing is blocking sleep.")
    print("")
  }

  if sleepDisabled == true {
    print("SleepDisabled = 1 (standing system setting, not an assertion).")
    print("  This is set by `pmset -a disablesleep 1`; it survives process exit.")
    print("")
  }

  if diagnosis.systemSleepBlockers.isEmpty {
    if diagnosis.canProveSleepIsUnblocked(aggregate: aggregate) {
      print("No process-held assertion is blocking idle sleep.")
    } else if sleepDisabled == true {
      print("No process-held assertion is blocking idle sleep, but SleepDisabled=1 is.")
    } else {
      print("No *recognized* sleep-blocking assertion was found, but see the warnings above.")
    }
  } else {
    print("Idle sleep is blocked by \(diagnosis.systemSleepBlockers.count) assertion(s):")
    let sorted = diagnosis.systemSleepBlockers.sorted {
      ($0.heldSeconds ?? -1) > ($1.heldSeconds ?? -1)
    }
    for blocker in sorted {
      print("  • \(blocker.processName) (pid \(blocker.pid))")
      print("      type: \(blocker.rawType)")
      print("      name: \(blocker.humanName.isEmpty ? "(unnamed)" : blocker.humanName)")
      print("      held: \(formatHeld(blocker.heldSeconds))")
    }
    print("")
    print("Quitting the owning app releases its assertion; sleepguard will not do it for you.")
  }

  print("")
  print(
    "Scope: owners are named only for process-held assertions "
      + "(IOPMCopyAssertionsByProcess). The system-wide aggregate table "
      + "(IOPMCopyAssertionsStatus) is also read, and it catches a sleep-blocking type "
      + "asserted with no readable process record to account for it. Same-type masking "
      + "is a known limit: a level measures as a 0/1 flag, not a holder count. "
      + "Kernel-level preventers — the `Kernel Assertions` and "
      + "`Idle sleep preventers: IODisplayWrangler` lines in `pmset -g assertions` — "
      + "remain structurally invisible: measured on macOS 15.7.4, active kernel USB "
      + "assertions and IODisplayWrangler raised no aggregate level. Scheduled dark "
      + "wakes and Power Nap are NOT covered.")

  let baseline = diagnosis.baselineActiveAggregateTypes(aggregate: aggregate)
  if !baseline.isEmpty {
    print("")
    print(
      "Note: \(baseline.count) aggregate assertion type(s) are active that this build has no "
        + "IOPMLib.h citation for, but which measured active on an idle Mac, so their presence "
        + "carries no diagnostic signal: " + baseline.joined(separator: ", ")
        + ". They are neither certified harmless nor counted as blockers.")
  }

  // Exit codes: 0 sleep provably unblocked, 3 sleep confirmed blocked,
  // 2 scan incomplete (unknown), 1 IOKit read failure.
  //
  // The code derives from the tri-state verdict rather than duplicating its
  // guards. `nil` means "cannot determine" and must map to 2, never to 0: the
  // printed unattributed list is the intersection of two aggregate reads while
  // the verdict recomputes on the confirming read, so a type seen only in the
  // second read yields nil with nothing printed. Mapping nil to 0 would report
  // "provably unblocked" in exactly that state.
  let verdict = diagnosis.systemSleepIsBlocked(aggregate: aggregate)
  if verdict == true { exit(3) }
  if verdict == nil || uncertain { exit(2) }
  exit(0)
} catch {
  FileHandle.standardError.write(Data("sleepguard: \(error)\n".utf8))
  exit(1)
}
