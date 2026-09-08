# sleepguard — read-only macOS sleep-blocker inspector

**Status: development prototype. Not a release. Not notarized. Not signed with a Developer ID.**

`sleepguard` answers one question: *why will this Mac not go to sleep?* It reads
the live IOKit power-assertion table, names the process holding each
sleep-blocking assertion, how long it has held it, names any **kernel driver**
holding a documented idle-sleep assertion, and reports whether the standing
`SleepDisabled` system setting is on.

## Why

`pmset -g assertions` already exposes this data, but it prints assertion
bookkeeping (kernel USB assertions, `UserIsActive` tickles, hex assertion IDs)
with no separation between *blocks all sleep*, *blocks only the display*, and
*a standing setting that is not an assertion at all*. Activity Monitor's Energy
tab has the opposite problem: it hides CLI-launched and daemon-held assertions.
`sleepguard` collapses both into one honest answer and explicitly reports when a
scan is incomplete.

Verified locally on macOS 15.7.4 (24G517): a single Electron app held a
`NoIdleSleepAssertion` for over 30 hours, and `pmset -g` reported
`sleep 0 (sleep prevented by ChatGPT)`. `sleepguard` names the same owner.

## Safety contract — what it will never do

- Never kills, signals, force-quits, or force-restarts any process.
- Never creates, releases, or modifies a power assertion.
- Never changes power settings (`pmset`, `disablesleep`, hibernation, wake).
- Never requests administrator privileges or installs a helper.
- Never makes a network request; no telemetry, no accounts, no analytics.
- Never reads user documents; it reads only IOKit power-management state.
- An assertion snapshot is treated as an *observation*, not a live handle: PIDs
  can exit and be reused, so nothing is ever acted upon.
- Anything it cannot decode, cannot classify, or cannot read marks the scan
  **incomplete** (exit `2`) rather than reporting a clean result. Absence of
  evidence is not evidence of absence. This covers: an undecodable assertion
  record, an assertion type this build does not recognize, a failed
  `SleepDisabled` lookup, an assertion table that comes back empty (a running
  Mac always holds at least one process assertion, so zero entries means a
  failed or restricted read, not an idle system), an unreadable or
  self-inconsistent kernel driver assertion view, and an asserted kernel driver
  record whose bits carry no documented idle-sleep semantics.
- The fail-closed rule is enforced in `SleepGuardCore` itself, not just in the
  CLI: `SleepDiagnosis` requires a `sourceWasComplete` argument with no default,
  and both `systemSleepIsBlocked` and `canProveSleepIsUnblocked` are *functions*
  requiring the aggregate table **and** the kernel driver view as arguments with
  no defaults. A library consumer therefore cannot obtain a provably-clean
  verdict by forgetting to check a flag or by never consulting a view.

## Known scope limits

- **Kernel driver assertions ARE now covered, with owners.** `IOPMrootDomain`
  publishes two documented `IOPM.h` registry properties — `DriverPMAssertions`
  (`kIOPMAssertionsDriverKey`, an aggregate bitfield) and
  `DriverPMAssertionsDetailed` (`kIOPMAssertionsDriverDetailedKey`, a per-record
  array carrying an `Owner` string). `sleepguard` reads both, reconciles them in
  both directions, and reports a named kernel idle-sleep blocker when a record
  asserts `kIOPMDriverAssertionPreventSystemIdleSleepBit` (0x02), which `IOPM.h`
  documents as *"When set, the system should not idle sleep. This does not
  prevent demand sleep."* Verified against `pmset -g assertions` on macOS 15.7.4:
  the three live `0x4=USB` kernel records (ids 7017/7019/7020) decode with
  matching IDs, levels and bits.

  This build does **not** claim these properties always exist. They were
  measured present on one macOS 15.7.4 host; an absent or unreadable property
  makes the scan incomplete, and the live test skips with a stated reason
  rather than asserting presence.

  A caveat on names: `pmset` prints two strings per kernel record
  (`owner=USB3.1 Hub` and `description=com.apple.usb.externaldevice.0d400000`).
  The registry `Owner` key holds the *latter*, so that is what `sleepguard`
  prints. It is the authoritative field, not the friendlier one.

  Only bit `0x02` has an `IOPM.h` idle-sleep statement. Every other bit — `CPU`,
  `USBExternalDevice`, `BluetoothHIDDevicePaired`, `ExternalMediaMounted`,
  `PreventDisplaySleep`, the reserved bits and the network-wake bits — carries no
  statement about idle sleep in either direction, so an asserted record holding
  only those is reported as **unknown-effect** and makes the scan incomplete. It
  is never certified harmless and never reported as a blocker.
- **`Level > 0 means asserted` is an assumption, not a citation.** `IOPM.h`
  declares `kIOPMDriverAssertionLevelKey` but never defines its value
  semantics. Measured levels were only ever `0` or `255` (on macOS 15.7.4 and
  on a GitHub macos-15 runner), and `pmset` lists exactly the `level=255`
  records under `Kernel Assertions`, which is consistent with 0/nonzero meaning
  inactive/active. If a future OS gives levels a graded meaning this reading
  could misclassify. It is called out here because the project's citation-only
  rule applies to documentation claims too.
- **`Idle sleep preventers:` is still invisible.** The
  `Idle sleep preventers: IODisplayWrangler` line in `pmset -g assertions` is a
  power-plane concept, **not** a driver assertion and not an assertion-subsystem
  entry. It appears in neither of the driver properties above, and measured on
  macOS 15.7.4 it raised no key in the aggregate `IOPMCopyAssertionsStatus`
  table either. No documented public API known to this project exposes it, so no
  coverage is claimed.
- **`IOPMCopyAssertionsStatus` does not see the kernel.** Measured on macOS
  15.7.4 with three active kernel USB assertions and `IODisplayWrangler`
  reported as an active idle-sleep preventer, **no key in that aggregate table
  changed.** It aggregates the same accounting as
  `IOPMCopyAssertionsByProcess`. The kernel coverage above comes from the
  `IOPMrootDomain` registry properties instead, which is why they were added.
- **Process owners** are named only for **process-held** assertions. The
  aggregate table is used for one narrower purpose: if a sleep-blocking type is
  asserted system-wide with no readable process record to account for it, the
  scan is marked incomplete and the type is reported as **unattributed**. That
  catches an unreadable record or a holder the by-process enumeration missed.
  The owner still cannot be named.
- **Same-type masking is a known limit.** Measured on macOS 15.7.4, an aggregate
  level behaves as a 0/1 asserted flag rather than a holder count: three
  simultaneous holders of one type still reported level 1. So if a readable
  process record accounts for a type, a second *unreadable* holder of that same
  type cannot be detected through this API.
- Scheduled dark wakes and Power Nap are not covered.
- A clean `sleepguard` report therefore means "no process-held assertion and no
  documented kernel driver assertion is blocking idle sleep, every aggregate
  sleep-blocking level is accounted for, and no asserted kernel record has
  unknown sleep semantics". It does **not** mean "nothing can keep this Mac
  awake" — `IODisplayWrangler`-style idle sleep preventers remain outside every
  API used here. For those, read `pmset -g assertions`.

`PreventUserIdleDisplaySleep` is classified as an idle-sleep blocker on the
authority of `IOPMLib.h`: *"While the display is prevented from dimming, the
system cannot go into idle sleep."*

## Build and run

```sh
swift build -c release
./.build/release/sleepguard
```

Exit codes, in precedence order:

| Code | Meaning |
|---|---|
| `1` | IOKit read failure — nothing could be determined |
| `3` | Sleep confirmed blocked (a definitive finding, reported even if other parts of the scan were incomplete) |
| `2` | Cannot determine: something could not be decoded, classified, or read |
| `0` | Sleep provably unblocked |

`3` outranks `2` because a confirmed blocker is decisive — finding *more*
evidence could never turn a real blocker into a clean result, so incompleteness
elsewhere does not weaken it. The warnings are still printed above the findings.

`2` always outranks `0`. An unknown verdict is never reported as "provably
unblocked": that is the tool's core promise. Read the printed findings, not only
the status code.

## Classification authority

Every assertion type is classified only on a citable `IOPMLib.h` statement.
A type with no citation is left **unclassified** and makes the scan incomplete —
it is never assumed harmless.

| Type | Verdict | Header citation |
|---|---|---|
| `PreventUserIdleSystemSleep` | blocks | "will prevent the system from sleeping due to a period of idle user activity" |
| `PreventSystemSleep` | blocks | documented system-sleep prevention |
| `PreventUserIdleDisplaySleep` | blocks | "While the display is prevented from dimming, the system cannot go into idle sleep." |
| `NetworkClientActive` | blocks | "this assertion can prevent system from going into idle sleep" |
| `NoIdleSleepAssertion` | blocks | deprecated alias of the system-sleep type |
| `PreventDiskIdle` | does not block | "The system may still sleep while this assertion is active." |

`UserIsActive`, `BackgroundTask`, and similar names that appear in `pmset`
output but in no IOKit header are deliberately **not** enumerated as harmless.

## Tests

This host has only the Command Line Tools toolchain, so `XCTest` and
`swift-testing` are unavailable. Tests run as a self-contained harness
executable that exits non-zero on any failed assertion:

```sh
swift run sleepguard-tests                 # deterministic unit tests only
RUN_LIVE_TESTS=1 swift run sleepguard-tests # also reads live IOKit state
```

The two live-IOKit integration checks are opt-in behind `RUN_LIVE_TESTS=1`
(accepted values `1`, `true`, `yes`, case- and whitespace-insensitive). They
assert on real system state, so on a restricted or sandboxed host they would
report a product defect that does not exist. When the gate is off the run prints
an explicit `SKIP:` line — never a silent pass. CI runs both modes.

Coverage: assertion-type classification (blocking, known-non-blocking, and
unknown types), decoding of the `IOPMCopyAssertionsByProcess` dictionary shape,
malformed-record handling (evidence preserved, completeness flagged), negative
identifier rejection, unknown-duration handling, the tri-state `SleepDisabled`
lookup, the unexpected-shape throw path, aggregate-table decoding (malformed keys and
values, Booleans rejected as levels, NULL and empty tables), unattributed
aggregate blockers including the deprecated-alias equivalence, kernel driver
assertion decoding (real registry byte shapes, level-0 records excluded,
bidirectional aggregate/record reconciliation, unreadable bitfield, unreadable
detailed array, Boolean and negative bitfields, non-array payload, missing and
blank required fields, undecodable levels, non-integral and out-of-range
numbers rejected rather than truncated, bit-name rendering of unknown and
negative bitfields), the kernel blocker's effect on the tri-state verdict and
the clean proof, unknown-effect kernel bits being neither blockers nor certified
harmless, process-blocker precedence over an incomplete kernel view, and four
real live-IOKit integration checks against the running system (the kernel-view
check skips with a stated reason if the host publishes no readable driver
assertion properties).

## Verification against `pmset`

`pmset -g assertions` is the ground truth. On macOS 15.7.4 the `sleepguard`
release binary was diffed against it directly: the same process-held blocker
(`screensharingd` pid 33841, `PreventSystemSleep`, "Remote user is connected",
7h34m), the same two unclassified `UserIsActive` holders, and the same three
kernel `0x4=USB` records (ids 7017/7019/7020 at level 255) reported as
unknown-effect. Exit `3`, blocked, as expected.

The kernel records were also read back independently through `ioreg` before the
decoder was written, and again afterwards with every field included, so the
fixture IDs, levels and bits are transcribed rather than assumed. The raw
captures are `evidence/kernel-driver-assertions-feasibility-2026-09-07c.txt`
(header citations plus the initial capture) and
`evidence/kernel-driver-assertions-live-verification-2026-09-08.txt` (the full
seven-key record shape with `ID` values, alongside the matching `pmset` output).
Both are outside this package, in the parent factory workspace.

One host is one host. These are two measurements on a single macOS 15.7.4
laptop; nothing here establishes that `IOPMrootDomain` always publishes these
properties, which is why the live test skips with a stated reason rather than
failing when they are absent.

## APIs used

Documented public IOKit power-management API only:
`IOPMCopyAssertionsByProcess` (process-held assertions),
`IOPMCopyAssertionsStatus` (system-wide aggregate levels), and
`IOServiceGetMatchingService` / `IORegistryEntryCreateCFProperty` to read three
`IOPMrootDomain` registry properties.

Two of those three property names are declared as public constants in the SDK
header `IOKit/pwr_mgt/IOPM.h`: `DriverPMAssertions`
(`kIOPMAssertionsDriverKey`) and `DriverPMAssertionsDetailed`
(`kIOPMAssertionsDriverDetailedKey`), along with the per-record key names
(`kIOPMDriverAssertionIDKey`, `kIOPMDriverAssertionOwnerStringKey`,
`kIOPMDriverAssertionLevelKey`, `kIOPMDriverAssertionAssertedKey`) and the
`kIOPMDriverAssertion*Bit` enumeration.

The third, `SleepDisabled`, is **not** declared anywhere in the IOKit SDK
headers — it is an undocumented registry property name, read through the
documented registry API. That is a real gap in this tool's citation chain and is
stated here rather than glossed over: the *API* is public, the *property name*
is not. It is used only as a tri-state read whose failure marks the scan
incomplete, so an unknown name degrades confidence rather than producing a false
clean verdict.

No private APIs, no kernel extensions, no SIP changes.

## License

MIT. See `LICENSE`.
