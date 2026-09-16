# SleepGuard classification and API reference

[English overview](../README.md) · [简体中文概览](../README.zh-CN.md)

## Process assertions

Classification lives in [SleepDiagnosis.swift](../Sources/SleepGuardCore/SleepDiagnosis.swift).

| Type | Treatment | Basis |
| --- | --- | --- |
| `PreventUserIdleSystemSleep` | Blocks idle sleep | `IOPMLib.h` states that it prevents sleep due to idle user activity. |
| `PreventUserIdleDisplaySleep` | Blocks idle sleep | The header states that preventing display dimming also prevents system idle sleep. |
| `NetworkClientActive` | Conservatively blocks | The header says it can prevent idle sleep on battery. |
| `NoIdleSleepAssertion` | Blocks; normalized for aggregate comparison | Deprecated in favor of `PreventUserIdleSystemSleep`; the redirect is not a literal declaration of identical semantics. |
| `PreventSystemSleep` | Conservatively blocks | No header statement establishes sleep prevention. The project measured it held by `screensharingd` on macOS 15.7.4 and corroborated it with `pmset`; its header redirects callers toward idle-sleep assertions. |
| `PreventDiskIdle` | Known non-blocking for system sleep | The header explicitly allows system sleep while active. |

Unrecognized process assertion types make the scan incomplete. At the aggregate level, `UserIsActive` and `EnableIdleSleep` are informational baseline exceptions based on measurements on an idle interactive Mac, not declarations that they are harmless. Other novel active aggregate types make the result uncertain.

## Kernel driver view

The reader reconciles `IOPMrootDomain` properties `DriverPMAssertions` and `DriverPMAssertionsDetailed` in both directions. Public constants and record keys are declared in `IOKit/pwr_mgt/IOPM.h`.

- Bit `0x02` (`PreventSystemIdleSleep`) explicitly prevents idle sleep, not demand sleep.
- Other asserted bits alone, including USB-related bits, have no cited idle-sleep semantics and make the scan incomplete rather than being certified harmless.
- `Level > 0` means active in this implementation. It is a measured assumption: observed levels were 0 and 255, not a documented definition of all possible levels.
- The displayed owner is the registry `Owner` value, which may resemble `pmset`'s description rather than its friendlier owner label.
- Missing properties, malformed records or inconsistent bitfields make the view incomplete. Their availability is not guaranteed on every OS or host.

See [DriverAssertionStatus.swift](../Sources/SleepGuardCore/DriverAssertionStatus.swift) and [IOKitAssertionReader.swift](../Sources/SleepGuardCore/IOKitAssertionReader.swift).

## Coverage boundaries

`IOPMCopyAssertionsByProcess` and `IOPMCopyAssertionsStatus` expose process and aggregate assertion state. The aggregate was measured as a 0/1 flag per type, not a count: one readable holder can mask another unreadable holder of that type.

The `SleepDisabled` property name is undocumented, although the registry access API is public. A failed lookup reduces confidence rather than producing a clean result. Empty process tables are also treated conservatively as incomplete; this is a project policy based on observed hosts, not an Apple guarantee.

Power-plane “Idle sleep preventers” such as `IODisplayWrangler` are outside these views. Scheduled dark wakes and Power Nap are also out of scope. Use `pmset -g assertions` as an additional diagnostic, not as proof that every undocumented API interpretation is universal.

## Snapshot and UI safety

Results are observations, never actionable process handles. The shared presenter clears old results when a new scan starts, timestamps findings and accepts completions only for the in-flight generation. This prevents stale or duplicated callbacks from replacing newer evidence. A confirmed blocker outranks uncertainty; uncertainty always outranks a clean verdict.
