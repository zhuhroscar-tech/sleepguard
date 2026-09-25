# Changelog

All notable source-quality changes to `sleepguard` are recorded here.

This project is a development prototype. GitHub release archives and the locally built `SleepGuard.zip` are ad-hoc signed for local validation only, not Developer ID signed or notarized app distributions.

## v0.2.2 — 2026-09-25

- Made GitHub Actions validation run explicitly for `v*` release tags as well as `main` pushes.
- Added repository-contract coverage so release-tag CI wiring cannot regress silently.
- Kept the release source-quality only; the last downloadable local app artifact remains the v0.2.0 ad-hoc `SleepGuard.zip` build.

## v0.2.1 — 2026-09-24

- Added this changelog and source-release contract coverage.
- Documented the v0.2.0 ad-hoc local build boundary in English and Chinese READMEs.
- Published a source-quality maintenance release with no new signed or notarized app artifact.

## v0.2.0 — 2026-09-23

- Added repository-contract tests for required files, README links/assets, public Swift package products, CI coverage, and unsigned/local-release claims.
- Wired the repository-contract tests into GitHub Actions.
- Verified the deterministic Swift harness, live-test path, release build, local app packaging, ad-hoc code signature, and extracted archive.
- Published `SleepGuard.zip` as an ad-hoc signed local build artifact.

## Earlier source changes

- Added the menu-bar app surface shared with `SleepGuardCore`.
- Added deterministic sleep-scan decoding and presentation coverage.
- Added English and Simplified Chinese documentation, a demo video, and example output assets.
