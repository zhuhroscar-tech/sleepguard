import Foundation
import SleepGuardCore

/// sleepguard — read-only explanation of why this Mac will not idle-sleep.
///
/// Non-goals (enforced by design): never kills, signals, force-quits, elevates,
/// changes power settings, or sends anything over the network.

let reader = IOKitAssertionReader()

do {
  let snapshot = try reader.snapshot()
  let sleepDisabled = reader.sleepDisabledSetting()
  let diagnosis = SleepDiagnosis(
    observations: snapshot.observations, sleepDisabledSetting: sleepDisabled)

  print("sleepguard — read-only sleep-blocker inspector (prototype)")
  print("scanned: \(ISO8601DateFormatter().string(from: Date()))")
  print("")

  if sleepDisabled {
    print("SleepDisabled = 1 (standing system setting, not an assertion).")
    print("  This is set by `pmset -a disablesleep 1`; it survives process exit.")
    print("")
  }

  if diagnosis.systemSleepBlockers.isEmpty {
    print("No process is holding a system-sleep assertion.")
  } else {
    print("System sleep is blocked by \(diagnosis.systemSleepBlockers.count) assertion(s):")
    for blocker in diagnosis.systemSleepBlockers.sorted(by: { $0.heldSeconds > $1.heldSeconds }) {
      let hours = blocker.heldSeconds / 3600
      let minutes = (blocker.heldSeconds % 3600) / 60
      print("  • \(blocker.processName) (pid \(blocker.pid))")
      print("      type: \(blocker.rawType)")
      print("      name: \(blocker.humanName.isEmpty ? "(unnamed)" : blocker.humanName)")
      print("      held: \(hours)h \(minutes)m")
    }
    print("")
    print("Quitting the owning app releases its assertion; sleepguard will not do it for you.")
  }

  let displayOnly = snapshot.observations.filter { $0.rawType == "PreventUserIdleDisplaySleep" }
  if !displayOnly.isEmpty {
    print("")
    print("Display-only blockers (system may still sleep): \(displayOnly.count)")
    for observation in displayOnly {
      print("  • \(observation.processName) (pid \(observation.pid)) — \(observation.humanName)")
    }
  }

  if !snapshot.isComplete {
    print("")
    print(
      "WARNING: \(snapshot.malformedRecordCount) assertion record(s) could not be decoded; "
        + "this scan is INCOMPLETE and must not be read as proof that nothing blocks sleep.")
    exit(2)
  }
  exit(0)
} catch {
  FileHandle.standardError.write(Data("sleepguard: \(error)\n".utf8))
  exit(1)
}
