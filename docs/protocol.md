# Wire protocol

The single reference for the wire format is the TypeScript in `src/protocol/` (`frame.ts` for v1/v2 messages and Bluetooth LE
framing, `mesh.ts` for mesh v3). iOS (Swift) and Android (Java) implement the same rules. `test/*.test.ts` and
`scripts/cross-verify/` check that the platforms produce and read the same bytes.

## Transports

| Transport | Platforms | Notes |
|---|---|---|
| Bluetooth LE GATT | iPhone ↔ Android, Android ↔ Android, iPhone ↔ iPhone | Every phone is peripheral (advertises service, GATT server) and central (scans, connects). Central writes to RX, peripheral notifies on TX. |
| MultipeerConnectivity | iPhone ↔ iPhone | Uses peer-to-peer Wi-Fi (not Bluetooth since iOS 11). Wi-Fi must be on; no network needed. Session encryption `.required`. Max 7 peers per session. Suspended by iOS in the background. |
| Wi-Fi Aware | iPhone ↔ iPhone, iOS 26+ | Optional. Only between devices paired once through the system sheet. Needs entitlement `com.apple.developer.wifi-aware`. **Not tested on real devices.** |
| Nearby Connections | Android ↔ Android | Optional, proprietary Google Play services SDK, off by default (`walkieTalkieNearby=true`). |

All transports carry the same UTF-8 JSON payloads. Every message is sent on every transport; receivers de-duplicate by message id.

## Interoperability identifiers (unchanged from the hangel app)

These constants were deliberately kept so that apps built from this repository and the hangel app can hear each other.
Changing any of them creates a separate, incompatible network.

| What | Value |
|---|---|
| BLE service UUID | `7A1E0001-4A6E-4C2B-9F3D-68616E67656C` (last 6 bytes = ASCII "hangel") |
| BLE RX / TX characteristic | `7A1E0002-…-68616E67656C` / `7A1E0003-…-68616E67656C` |
| MultipeerConnectivity service type | `hangel-tlz` (Info.plist `NSBonjourServices`: `_hangel-tlz._tcp`, `_hangel-tlz._udp`) |
| Wi-Fi Aware service | `_hangel-telsiz._tcp` |
| Nearby Connections service id | `com.hangel.telsiz` |
| Content key IKM / info | `hangel-afet-telsiz-v1` / `kanal-anahtari` |

## BLE frame

```
[0]      version (1)
[1..4]   message sequence (uint32, big-endian; per connection and sender)
[5..6]   part index (uint16, big-endian, from 0)
[7..8]   part count (uint16, big-endian, ≥ 1)
[9..]    payload slice
```

Max payload 262,144 bytes; reassembly accepts out-of-order and duplicate parts, at most 4 half-received messages per connection,
60 s timeout.

## Payloads

* **v1 message** `{v:1, id, kanal, t, atlama, sure, mime, veri}` — `veri` = base64(nonce(12) ‖ ChaCha20-Poly1305 ciphertext ‖ tag(16)).
  Plaintext JSON: `{ad, ses, metin?, enlem?, boylam?, durum?, kisi?, konumMs?}` (masked name, base64 audio or "", text ≤ 280 code
  points, latitude/longitude rounded to ~1 m, status, person code, location time).
* **v2 announcement** `{v:2, tur:"duyuru", id, t, atlama, etkinlikId, baslik, metin}` — plain text, lives 3 h.
* **v3 mesh** `{v:3, tur, id, t, atlama, kisi, ad, enlem?, boylam?, konumMs?, …}` — plain text. Types: `varlik` (presence, every
  30–45 s, max 3 hops, forgotten after 3 min), `davet` / `davetYaniti` (private-channel invitation 1–99, 15 min), `yardim`
  (help call: `ihtiyac` enkaz|yarali|su-gida|barinma|ilac|diger, `kisiSayisi` 1–99, `not` ≤ 140; 24 h, 16 hops),
  `yardimaGidiyorum` (I'm coming; 24 h, 16 hops). **v3 is implemented on iOS only; the Android engine drops v3 frames and does
  not relay them.**

## Content key

`key = HKDF-SHA256(ikm = "hangel-afet-telsiz-v1", salt = channel id, info = "kanal-anahtari", 32 bytes)`.

This is **not confidentiality**: the input keying material is public and channel ids are short (`k0`…`k99`), so anyone can derive
the key. It only keeps relays on other channels from showing the content by accident and makes tampering by relays detectable
(AEAD). Treat every channel as a public radio frequency.

## Relaying rules

* Sender sends `atlama = 0`; a receiver stores `atlama + 1` and relays if the stored value is below the limit
  (v1/v2: 12; v3: per type, see above).
* Messages older than their lifetime or more than 5 minutes in the future are rejected.
* No relaying when the battery is below 20 %.
* A newly connected neighbour receives recent history: over BLE all texts plus the newest 3 voice messages (max 30 items); over
  MultipeerConnectivity / Wi-Fi Aware the newest 30 items of the last 72 h.
* Local storage: messages 72 h, help calls 24 h, then deleted from the device.
