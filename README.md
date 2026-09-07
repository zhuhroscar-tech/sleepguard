# sleepguard — read-only macOS sleep-blocker inspector

**Status: development prototype. Not a release. Not notarized. Not signed with a Developer ID.**

`sleepguard` answers one question: *why will this Mac not go to sleep?* It reads
the live IOKit power-assertion table, names the process holding each
sleep-blocking assertion, how long it has held it, and whether the standing
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
  evidence is not evidence of absence. This covers four distinct cases: an
  undecodable assertion record, an assertion type this build does not recognize,
  a failed `SleepDisabled` lookup, and an assertion table that comes back empty
  (a running Mac always holds at least one process assertion, so zero entries
  means a failed or restricted read, not an idle system).
- The fail-closed rule is enforced in `SleepGuardCore` itself, not just in the
  CLI: `SleepDiagnosis` requires a `sourceWasComplete` argument with no default,
  so a library consumer cannot obtain a provably-clean verdict from an
  incomplete snapshot by forgetting to check a flag.

## Known scope limits

- **Kernel-level preventers remain structurally invisible.** The
  `Kernel Assertions` and `Idle sleep preventers: IODisplayWrangler` lines in
  `pmset -g assertions` are not exposed by any API this tool uses. Measured on
  macOS 15.7.4 with three active kernel USB assertions and `IODisplayWrangler`
  reported as an active idle-sleep preventer, **no key in the aggregate
  `IOPMCopyAssertionsStatus` table changed.** That table aggregates the same
  assertion accounting as `IOPMCopyAssertionsByProcess`; IOPMLib.h documents
  nothing about kernel contribution to its levels, so per this project's
  citation-only rule no coverage is claimed.
- **Owners** are named only for **process-held** assertions. The aggregate table
  is used for one narrower purpose: if a sleep-blocking type is asserted
  system-wide with no readable process record to account for it, the scan is
  marked incomplete and the type is reported as **unattributed**. That catches an
  unreadable record or a holder the by-process enumeration missed — not a kernel
  assertion. The owner still cannot be named.
- **Same-type masking is a known limit.** Measured on macOS 15.7.4, an aggregate
  level behaves as a 0/1 asserted flag rather than a holder count: three
  simultaneous holders of one type still reported level 1. So if a readable
  process record accounts for a type, a second *unreadable* holder of that same
  type cannot be detected through this API.
- Scheduled dark wakes and Power Nap are not covered.
- A clean `sleepguard` report therefore means "no process-held assertion is
  blocking idle sleep, and every aggregate sleep-blocking level is accounted
  for". It does **not** mean "nothing can keep this Mac awake". For that, read
  `pmset -g assertions`.

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
aggregate blockers including the deprecated-alias equivalence, and three real
live-IOKit integration checks against the running system.

## APIs used

Documented public IOKit power-management API only:
`IOPMCopyAssertionsByProcess` (process-held assertions),
`IOPMCopyAssertionsStatus` (system-wide aggregate levels),
`IOServiceGetMatchingService` / `IORegistryEntryCreateCFProperty` for
`IOPMrootDomain.SleepDisabled`. No private APIs, no kernel extensions, no SIP
changes.

## License

MIT. See `LICENSE`.
