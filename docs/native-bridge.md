# Native bridge contract

Capacitor plugin name: **`DisasterWalkieTalkie`** (iOS class `DisasterWalkieTalkiePlugin`, Android
`org.hangel.walkietalkie.DisasterWalkieTalkiePlugin`). Native method and field names are Turkish because the code comes from the
hangel app; use the English wrapper in `src/index.ts` unless you need the raw contract.

| English API (`src/index.ts`) | Native method | Arguments → result | iOS | Android |
|---|---|---|---|---|
| `getStatus()` | `durum` | → status object | ✓ | ✓ |
| `start(opts)` | `motor` | `{kanal, kanalAdi, ad, testPaneli}` → status | ✓ | ✓ |
| `setChannel()` | `kanalSec` | `{kanal, kanalAdi}` | ✓ | ✓ |
| `requestPermissions()` | `izinIste` | → status | ✓ | ✓ |
| `startRecording()` / `stopRecording()` | `kayitBaslat` / `kayitBitir` | | ✓ | ✓ |
| `sendText()` | `metinGonder` | `{metin, konumla, enlem?, boylam?}` | ✓ (own GPS) | ✓ (uses given location) |
| `sendStatus()` | `durumGonder` | `{durum: guvende\|toplanma\|yardim, metin, konumla, enlem?, boylam?}` | ✓ | ✓ |
| `listMessages()` | `liste` | → `{mesajlar}` | ✓ | ✓ |
| `play(id)` | `cal` | `{id}` | ✓ | ✓ |
| `release()` | `birak` | | ✓ | ✓ |
| `openNativeScreen()` | `ac` | same as `motor` | ✓ | ✓ (experimental) |
| `getPendingUploads()` / `markUploaded()` | `bekleyenler` / `yuklendi` | → `{mesajlar}` / `{idler}` | ✓ | ✓ |
| `injectFromServer()` | `disaridan` | `{mesajlar}` | ✓ | ✓ |
| `broadcastAnnouncement()` | `duyuruYay` | `{etkinlikId, baslik, metin}` | ✓ | ✓ |
| `setBackgroundListening()` | `arkaPlanAyarla` | `{acik}` → status | ✓ | — |
| `setDisplayName()` | `adAyarla` | `{ad}` | ✓ | — |
| `devices()` | `cihazlar` | → `{cihazlar, dogrudanSayi, agdakiSayi, ben}` | ✓ | — |
| `sendInvitation()` | `davetGonder` | `{kisi, kanal: 1–99}` → `{id}` | ✓ | — |
| `respondToInvitation()` | `davetYanitla` | `{id, kabul}` → `{kabul, kanal?}` | ✓ | — |
| `pendingInvitations()` | `davetler` | → `{davetler}` | ✓ | — |
| `sendHelpCall()` | `yardimGonder` | `{tur, kisiSayisi, not}` → `{id}` | ✓ | — |
| `listHelpCalls()` | `yardimListe` | → `{yardimlar}` | ✓ | — |
| `respondToHelpCall()` | `yardimaGidiyorum` | `{id}` | ✓ | — |
| `getWifiAwareStatus()` | `waDurum` | → `{destek, eslesmis, bagli}` | ✓ (iOS 26+) | — |
| `pairWifiAware()` | `waEsles` | `{rol: gorunur\|ara, kapat}` | ✓ (iOS 26+) | — |

Events (`on(event)` → native event): `changed` → `degisti`, `devices` → `cihazlar`, `invitation` → `davet`,
`invitationReply` → `davetYaniti`, `helpCall` → `yardim`, `channelChanged` → `kanalDegisti`,
`notificationTapped` → `bildirimeDokunuldu`. Only `degisti` exists on Android.

Methods marked "—" are missing on Android; the wrapper resolves them with empty values.
