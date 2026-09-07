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
- A record it cannot decode marks the scan **incomplete** and exits `2` rather
  than reporting a clean result. Absence of evidence is not evidence of absence.

## Build and run

```sh
swift build -c release
./.build/release/sleepguard
```

Exit codes: `0` complete scan, `1` IOKit read failure, `2` scan incomplete.

## Tests

This host has only the Command Line Tools toolchain, so `XCTest` and
`swift-testing` are unavailable. Tests run as a self-contained harness
executable that exits non-zero on any failed assertion:

```sh
swift run sleepguard-tests
```

Coverage: assertion-type classification, decoding of the
`IOPMCopyAssertionsByProcess` dictionary shape, malformed-record handling
(evidence preserved, completeness flagged), and a real live-IOKit integration
check against the running system.

## APIs used

Documented public IOKit power-management API only:
`IOPMCopyAssertionsByProcess`, `IOServiceGetMatchingService` /
`IORegistryEntryCreateCFProperty` for `IOPMrootDomain.SleepDisabled`. No private
APIs, no kernel extensions, no SIP changes.

## License

MIT. See `LICENSE`.
