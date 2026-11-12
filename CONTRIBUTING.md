# Contributing

Thank you for helping! Issues and pull requests are welcome in English or Turkish.

## Ground rules

* Be kind — see [CODE_OF_CONDUCT.md](CODE_OF_CONDUCT.md).
* Security problems go to [SECURITY.md](SECURITY.md), not to public issues.
* Never claim that a feature "works" in docs or PRs unless you tested it; say how you tested (devices, OS versions, distance).
* The wire protocol is shared by iOS, Android and the TypeScript reference (`src/protocol/`). A change to it must update all three,
  the tests and [docs/protocol.md](docs/protocol.md). Keep the interoperability identifiers unless the change is discussed first.
* No telemetry, analytics or network calls in the plugin. Data stays on devices unless the host app implements `RelayAdapter`.

## Development

```bash
npm install
npm run typecheck     # TypeScript
npm test              # protocol tests (Vitest)
npm run verify:ios    # Swift package build for the iOS Simulator (macOS + Xcode)
npm run verify:cross  # Swift ↔ TypeScript wire compatibility (macOS)
swift scripts/cross-verify/vektor-dogrula.swift   # iOS decrypts the shared test vector
```

Android: open a Capacitor 8 app that depends on this package in Android Studio and build it; unit test:
`./gradlew :hangel-disaster-walkie-talkie:testDebugUnitTest` (module name depends on your app). The maintainers' release machine
currently has no Android SDK, so **Android build reports and fixes are especially welcome**.

## Pull requests

1. Fork, create a branch, keep the change focused.
2. Add or update tests for protocol changes.
3. Describe what you tested on real devices, if anything.
4. By submitting, you agree that your contribution is licensed under Apache-2.0 (see LICENSE, section 5).

Good first contributions: Android implementation of mesh v3 (help calls, presence, invitations), an Android foreground service for
background relaying, English translations of internal identifiers/comments, more languages in the native fallback screens.
