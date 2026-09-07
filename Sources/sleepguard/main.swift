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
  let snapshot = try reader.snapshot()
  let sleepDisabled = reader.sleepDisabledSetting()
  let diagnosis = SleepDiagnosis(snapshot: snapshot, sleepDisabledSetting: sleepDisabled)

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
    if diagnosis.canProveSleepIsUnblocked {
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
    "Scope: this reads process-held assertions (IOPMCopyAssertionsByProcess) only. "
      + "Kernel-level preventers (USB, IODisplayWrangler) and scheduled dark wakes "
      + "are NOT covered; see `pmset -g assertions` for those.")

  // Exit codes: 0 sleep provably unblocked, 3 sleep confirmed blocked,
  // 2 scan incomplete (unknown), 1 IOKit read failure.
  if uncertain { exit(2) }
  exit(diagnosis.systemSleepIsBlocked == true ? 3 : 0)
} catch {
  FileHandle.standardError.write(Data("sleepguard: \(error)\n".utf8))
  exit(1)
}
