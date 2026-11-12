# hangel Disaster Walkie-Talkie

[Türkçe](README.tr.md)

An open-source [Capacitor](https://capacitorjs.com) plugin that lets nearby phones exchange **push-to-talk voice messages, short
text messages, "I am safe" statuses and help calls without internet or mobile network**, over Bluetooth LE and peer-to-peer
Wi-Fi. Every phone also relays what it receives (store-and-forward), so a message can travel further than one radio hop.

It is the open-source release of the "Afet Telsizi" (Disaster Radio) feature of [hangel](https://hangel.org), a free civil-society
platform run by the Uluslararası Sosyal Fayda Derneği (Social Business Global), Istanbul.

> [!WARNING]
> **This is not a replacement for 112 or any official emergency channel.** If you can reach emergency services, call them first.
> Delivery is best-effort: a message may arrive late, once, or never. Range is short (typically tens of metres per hop,
> depending on walls, devices and settings). Do not build a product that implies guaranteed delivery or rescue.

## What it does

* **Push-to-talk voice** (up to 30 s, AAC 16 kHz mono) and **short text** (up to 280 characters) on channels `k0` (general) to `k99`.
* **Location** (if the user allowed it) attached to messages, so helpers can find the sender.
* **Quick status**: "I am safe", "I am at the assembly point", "I need help" — with a per-channel count of the latest status per person.
* **Help calls** with a category (trapped, injured, water/food, shelter, medicine, other), number of people and a short note;
  others can answer "I'm coming". *(iOS only for now.)*
* **Nearby devices list** and **private-channel invitations**. *(iOS only for now.)*
* **Announcements**: short plain-text notices for people nearby (for example from event organisers).
* **Optional internet bridge**: when a phone gets connectivity, your app can upload what was collected offline to *your own*
  server and inject server messages back into the offline mesh. This repository contains no server.

## How it works

```
 phone A ──BLE / P2P Wi-Fi──► phone B ──BLE──► phone C ──► …   (each phone stores, de-duplicates and relays)
```

* **Transports**: Bluetooth LE GATT (iPhone ↔ Android, Android ↔ Android, iPhone ↔ iPhone); Apple MultipeerConnectivity
  (iPhone ↔ iPhone over peer-to-peer Wi-Fi; Wi-Fi must be on, no network needed); optional Apple Wi-Fi Aware (iOS 26+, paired
  devices); optional Google Nearby Connections (Android ↔ Android, off by default).
* **Store-and-forward**: every message has an id, a creation time and a hop counter. Receivers drop duplicates, relay up to 12 hops
  (help calls 16, presence 3), stop relaying when battery < 20 %, and give recent history to newly connected neighbours.
* **Lifetime**: messages are kept on the device for 72 h, help calls 24 h, announcements 3 h, then deleted.
* **Background**: on iOS the engine keeps listening and relaying over Bluetooth LE in the background (and can be relaunched by
  iOS for Bluetooth events) when the app enables the Bluetooth background modes; MultipeerConnectivity only works in the
  foreground. On Android the engine runs while the app process is alive; there is no foreground service in this release.

Details: [docs/protocol.md](docs/protocol.md) · native contract: [docs/native-bridge.md](docs/native-bridge.md) ·
Turkish identifiers: [docs/glossary.md](docs/glossary.md).

## Status — what has and has not been tested

Be careful when relying on this code. This table is the honest state on 2026-11-12.

| Part | State |
|---|---|
| iPhone ↔ iPhone over MultipeerConnectivity | Shipped in the hangel iOS app (App Store 2.0.5, Nov 2026). |
| iPhone ↔ iPhone / iPad over Bluetooth LE (iPhone as central) | Relaying observed in a TestFlight build (2.0.7) on 2026-11-09. Not yet in an App Store release. |
| iPhone ↔ Android over Bluetooth LE | Protocol checked with shared test vectors (Swift, Node.js, Java unit test). **No recorded real-device field test.** |
| Android engine | Ran in hangel's Android builds; **this repository's Android module has not been compiled** (no Android SDK on the release machine, see below). |
| Mesh v3 (presence, invitations, help calls) | iOS only, TestFlight builds. Android ignores and does not relay these messages. |
| Wi-Fi Aware transport | Compiles; **never tested on real devices**. |
| Native fallback screens (SwiftUI / Android Activity) | Experimental. hangel uses its own web UI; the Android screen has not been used in production since 2026-11-05. |
| Changes made for this open-source release | Renamed plugin, removed hangel-specific URLs/keys, optional Nearby on Android, name masking in JS — **not field-tested**. |

### Verification done for this release

* `npm run typecheck` (TypeScript 5.7, strict) — passes.
* `npm test` (Vitest) — 57 protocol tests pass.
* `npm run verify:ios` — Swift package builds for the iOS Simulator with Xcode 27.2 against capacitor-swift-pm 8.6.0, and for a generic iOS device without code signing (both `BUILD SUCCEEDED`; the Wi-Fi Aware code is compiled because the SDK contains WiFiAware).
* `npm run verify:cross` — real Swift code is compiled and exchanges frames with the TypeScript reference (both directions, out of
  order, duplicates) — all checks pass; `swift scripts/cross-verify/vektor-dogrula.swift` — iOS CryptoKit decrypts the shared vector.
* Android Java sources were **only syntax-checked** (java-parser). They were not compiled and the JUnit test was not run, because
  installing the Android SDK requires accepting Google's licence terms. Please report build problems.

## Installation (Capacitor 8)

```bash
npm install github:hangelapp/hangel-disaster-walkie-talkie
npx cap sync
```

### iOS (15+)

Add to `ios/App/App/Info.plist` (write the descriptions in your users' languages):

| Key | Value |
|---|---|
| `NSBluetoothAlwaysUsageDescription` | Why you use Bluetooth (offline messages with nearby phones). |
| `NSMicrophoneUsageDescription` | Push-to-talk voice messages. |
| `NSLocalNetworkUsageDescription` | Peer-to-peer Wi-Fi with nearby iPhones. |
| `NSBonjourServices` | `_hangel-tlz._tcp`, `_hangel-tlz._udp` |
| `NSLocationWhenInUseUsageDescription` | Attaching your location to messages so helpers can find you. |
| `UIBackgroundModes` | `bluetooth-central`, `bluetooth-peripheral` (for background listening; omit if you do not want it) |
| `WiFiAwareServices` *(optional)* | `{"_hangel-telsiz._tcp": {"Publishable": {}, "Subscribable": {}}}` + entitlement `com.apple.developer.wifi-aware` |

In `AppDelegate.swift`:

```swift
import DisasterWalkieTalkiePlugin

func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
    // Restores Bluetooth state when iOS relaunches the app for a Bluetooth event, or starts background
    // listening if the user already granted Bluetooth permission. Shows no permission prompt.
    DisasterWalkieTalkie.acilistaBaslat(launchOptions)
    return true
}
```

Optionally, in your `UNUserNotificationCenterDelegate.didReceive`, call `DisasterWalkieTalkie.bildirimeDokunuldu(userInfo)` to get a
`notificationTapped` event in JavaScript.

### Android (API 24+, encryption needs Android 9+)

The library manifest adds the Bluetooth, microphone, location (Android ≤ 11 BLE scanning), notification, network-state and
vibration permissions. Nothing else is required for the default build, which uses only Android's own Bluetooth LE APIs.

Optional faster Android ↔ Android transport (Google Play services Nearby Connections, **proprietary**): add
`walkieTalkieNearby=true` to your app's `android/gradle.properties`.

### JavaScript

```ts
import { DisasterWalkieTalkie as WT } from 'hangel-disaster-walkie-talkie';

await WT.start({ channel: 'k0', displayName: 'Ayşe Yılmaz' }); // the name is masked to "A*** Y*****" before use
await WT.on('changed', async () => render(await WT.listMessages()));
button.onpointerdown = () => WT.startRecording();
button.onpointerup = () => WT.stopRecording();
await WT.sendText('Two people under debris, block C');
await WT.sendHelpCall({ type: 'trapped', people: 2, note: 'block C' }); // iOS
window.addEventListener('online', () => WT.syncWithServer(myServerAdapter)); // optional, your backend
```

A complete minimal page is in [example/](example/). All functions resolve with neutral values on the web or when a native method
is missing; they do not throw.

### Building a UI responsibly

* Show "call 112 / your local emergency number" prominently.
* Explain that messages are visible to everyone nearby on the same channel.
* Keep the walkie-talkie usable with screen readers (the example uses labelled buttons; the native screens have accessibility labels).
* Keep the screen awake only while your walkie-talkie page is open (`start()` does it, `release()` undoes it).

## Privacy

| Data | Where it goes | Protection |
|---|---|---|
| Voice, text, status, masked name, location in channel messages | Over Bluetooth/Wi-Fi to nearby devices, relayed up to 12 hops; stored on each device for 72 h | Encrypted with a key derived from the **channel id and a public constant** — anyone who knows the channel id can decrypt. Treat channels as public radio. |
| Help calls, presence ("I'm here"), invitations (iOS) | Same, up to 16 / 3 / 12 hops; help calls stored 24 h | **Plain text** (masked name + location visible to everyone nearby). |
| Announcements | Same, 3 h | Plain text. |
| Display name | Your app passes it to `start()`; the wrapper masks it ("Ayşe Yılmaz" → "A*** Y*****") before it reaches native code. Only the masked form is stored and sent. | — |
| Person code | Random 12-character code per device, stored on the device, sent with messages to count people once. Not linked to an identity by this plugin. | — |
| Location | Only if the OS location permission is granted; rounded to ~1 m; attached to every outgoing message on iOS, on Android only when the page passes it. | Same as the message it is in. |
| Storage on device | iOS: Application Support/`walkie-talkie`, file protection *complete until first user authentication*; Android: app-private files dir. Settings in UserDefaults / SharedPreferences. | OS app sandbox. |
| Servers | **None.** The plugin never contacts a server. If you implement `RelayAdapter`, you are responsible for that data flow and its legal basis. | — |

MultipeerConnectivity sessions use Apple's link encryption (`.required`) and Wi-Fi Aware links are authenticated and encrypted by
the OS; Bluetooth LE links in this plugin are not paired or encrypted at the link layer.

If you deploy this in a product, describe these flows in your privacy notice (e.g. GDPR / KVKK) and provide a way to clear local
data (uninstalling the app removes it).

## Limitations and warnings

* **Not a replacement for 112 / official emergency channels.** No delivery guarantee, no acknowledgement of receipt.
* Range per hop is short and varies widely; a mesh only helps when enough phones running a compatible app are nearby.
* **No confidentiality**: see Privacy. Do not use it for sensitive conversations.
* **No authentication**: anyone can send messages, statuses or help calls; names can be spoofed. Messages could be false or
  malicious. Moderation/reporting is not possible offline.
* Android does not implement mesh v3 yet (help calls, presence, invitations), so those do not cross Android phones.
* iOS suspends MultipeerConnectivity in the background; background relaying relies on Bluetooth LE and iOS scheduling.
* No Android foreground service: Android may stop the engine when the app is in the background.
* Relaying uses battery; relaying stops below 20 % battery.
* The protocol identifiers are shared with the hangel app on purpose (interoperability). Changing them creates a separate network.
* Internal identifiers and comments are in Turkish (see the glossary). Contributions translating them are welcome.

## Dependencies and licences

| Dependency | Used for | Licence |
|---|---|---|
| `@capacitor/core` (peer) | JS bridge | MIT |
| Capacitor iOS (`capacitor-swift-pm` / `Capacitor` pod) | iOS bridge | MIT |
| Capacitor Android (`capacitor-android`) | Android bridge | MIT |
| `androidx.appcompat:appcompat`, `androidx.core:core` | Android UI and compat | Apache-2.0 |
| Apple system frameworks (MultipeerConnectivity, CoreBluetooth, CryptoKit, AVFoundation, CoreLocation, WiFiAware…) | iOS | Part of iOS (Apple SDK terms) |
| `com.google.android.gms:play-services-nearby` *(optional, off by default)* | Android ↔ Android Wi-Fi transport | **Proprietary** (Android Software Development Kit License). Not needed for the default build. |
| Dev only: `typescript` (Apache-2.0), `vitest` (MIT), `tsx` (MIT), `@types/node` (MIT), `junit` 4 (EPL-1.0, tests only) | build/test | — |

All mandatory runtime dependencies are under permissive licences compatible with Apache-2.0. The only proprietary component is
optional; the default build is independent of it (DPG "platform independence").

## Contributing, security, conduct

* [CONTRIBUTING.md](CONTRIBUTING.md) — how to build, test and send changes.
* [SECURITY.md](SECURITY.md) — report vulnerabilities privately.
* [CODE_OF_CONDUCT.md](CODE_OF_CONDUCT.md) — Contributor Covenant 2.1.
* [CHANGELOG.md](CHANGELOG.md)

## Licence and ownership

Copyright 2026 **Uluslararası Sosyal Fayda Derneği (Social Business Global)** (International Social Benefit Association), Istanbul,
Türkiye. Licensed under the [Apache License, Version 2.0](LICENSE). See [NOTICE](NOTICE). "hangel" is the association's brand;
the licence does not grant trademark rights, so please use your own app name in forks.

Contact: info@socialbusinessglobal.org · https://hangel.org
