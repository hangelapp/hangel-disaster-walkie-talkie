# Changelog

All notable changes to this project are documented here. Format: [Keep a Changelog](https://keepachangelog.com/en/1.1.0/);
versioning: [SemVer](https://semver.org/).

## [Unreleased]

### Added
- Static analysis: ESLint with `typescript-eslint` (`npm run lint`, run in CI) and a GitHub CodeQL workflow for JavaScript/TypeScript
  (push, pull request, weekly).

### Security
- Dev/test tooling upgraded to releases without known vulnerabilities: Vitest 2.1.8 → 4.1.12 (fixes CVE-2025-24964 and the
  vulnerable vite / esbuild / tinypool chain), tsx 4.19.2 → 4.23.15; `minimatch` pinned to 11.0.3 via `overrides` (ESLint toolchain).
  `npm audit` reports 0 vulnerabilities. These packages are not part of the published plugin.

## [0.1.0] — 2026-11-12

First open-source release, extracted from the hangel app's "Afet Telsizi" feature (developed 2026-11-04 → 2026-11-09).

### Added
- Capacitor plugin `DisasterWalkieTalkie` for iOS (Swift) and Android (Java) with an English TypeScript API (`src/index.ts`).
- Wire protocol reference in TypeScript (`src/protocol/`) with 57 tests, and Swift ↔ TypeScript cross-verification scripts.
- `RelayAdapter` interface for an optional bridge to the host app's own server.
- Docs: protocol, native bridge contract, Turkish→English glossary; minimal example page.

### Changed (compared to the code inside the hangel app)
- Plugin renamed from `HangelTelsiz` to `DisasterWalkieTalkie`; Android package `org.hangel.walkietalkie`.
- Storage keys/folders renamed (`walkieTalkie…`, `walkie-talkie`); no migration from the hangel app's data.
- hangel-specific links removed from notifications and from the iOS fallback opener (it no longer loads hangel.org).
- Android: Google Nearby Connections transport is optional and off by default (`walkieTalkieNearby=true` to enable).
- Android: the native fallback screen is reachable again via `openNativeScreen()` (it was unused in hangel since 2026-11-05).
- The JS wrapper masks display names before they reach native code (the hangel Android build sent the full name inside
  channel-encrypted content).
- UI strings use the host app's name instead of "hangel".

### Not included
- Apple Push to Talk (lock-screen push-to-talk) — depends on hangel's server and APNs.
- hangel's server endpoints, Firebase storage and web UI.

### Known limitations
- Android module not compiled in this release preparation (syntax-checked only). Wi-Fi Aware not tested on devices.
  Mesh v3 is iOS-only. See README → Status.
