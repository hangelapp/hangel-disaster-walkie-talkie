# hangel Afet Telsizi (Disaster Walkie-Talkie)

[English](README.md)

Yakındaki telefonların **internet ve baz istasyonu olmadan** birbirine **bas-konuş sesli mesaj, kısa yazılı mesaj, "güvendeyim"
durumu ve yardım çağrısı** göndermesini sağlayan açık kaynak bir [Capacitor](https://capacitorjs.com) eklentisi. Bluetooth LE ve
eşler arası Wi-Fi kullanır. Her telefon aldığını yakındakilere aktarır (sakla-ilet); böylece mesaj tek telsiz menzilinden daha
uzağa gidebilir.

[hangel](https://hangel.org) platformundaki "Afet Telsizi" özelliğinin açık kaynak sürümüdür. hangel'i Uluslararası Sosyal Fayda
Derneği (Social Business Global, İstanbul) yürütür.

> [!WARNING]
> **112'nin ve resmî acil durum kanallarının yerine geçmez.** Acil servise ulaşabiliyorsan önce onu ara. Teslim garantisi yoktur:
> mesaj geç, bir kez ya da hiç ulaşmayabilir. Menzil kısadır (duvara, cihaza ve ayara göre genellikle her adımda onlarca metre).
> Kesin teslim ya da kurtarma vaat eden bir ürün kurma.

## Ne işe yarar

* **Bas-konuş ses** (en çok 30 sn) ve **kısa metin** (en çok 280 karakter), `k0` (genel) – `k99` kanallarında.
* Kullanıcı izin verdiyse mesaja **konum** eklenir; yardım edecek kişi göndereni bulabilir.
* **Hızlı durum**: "Güvendeyim", "Toplanma alanındayım", "Yardım lazım"; kanalda her kişinin son durumu sayılır.
* **Yardım çağrısı**: tür (enkaz, yaralı, su/gıda, barınma, ilaç, diğer), kişi sayısı, kısa not; başkaları "Geliyorum" der.
  *(Şimdilik yalnız iOS.)*
* **Yakındaki cihazlar listesi** ve **özel kanala davet**. *(Şimdilik yalnız iOS.)*
* **Duyuru**: yakındakilere kısa, düz metin duyuru (ör. etkinlik düzenleyicisinden).
* **İsteğe bağlı internet köprüsü**: telefon internete kavuşunca uygulaman çevrimdışı toplananları *kendi* sunucuna yükleyebilir,
  sunucudaki mesajları çevrimdışı ağa verebilir. Bu depoda sunucu yoktur.

## Nasıl çalışır

* **Taşımalar**: Bluetooth LE (iPhone ↔ Android, Android ↔ Android, iPhone ↔ iPhone); Apple MultipeerConnectivity (iPhone ↔ iPhone,
  eşler arası Wi-Fi; Wi-Fi açık olmalı, ağa bağlı olması gerekmez); isteğe bağlı Apple Wi-Fi Aware (iOS 26+, eşleştirilmiş cihazlar);
  isteğe bağlı Google Nearby Connections (Android ↔ Android, varsayılan kapalı).
* **Sakla-ilet**: her mesajın kimliği, zamanı ve aktarım sayacı vardır. Alan telefon tekrarları atar, en çok 12 aktarım yapar
  (yardım çağrısı 16, varlık 3), pil %20'nin altındaysa aktarmaz, yeni bağlanan komşuya son mesajları verir.
* **Ömür**: mesajlar cihazda 72 saat, yardım çağrıları 24 saat, duyurular 3 saat tutulur, sonra silinir.
* **Arka plan**: iOS'ta Bluetooth arka plan kipleri açıksa motor arka planda Bluetooth LE ile dinler ve aktarır; MultipeerConnectivity
  yalnız ön planda çalışır. Android'de motor uygulama süreci yaşadıkça çalışır; bu sürümde ön plan hizmeti yoktur.

Ayrıntı: [docs/protocol.md](docs/protocol.md) · yerel sözleşme: [docs/native-bridge.md](docs/native-bridge.md) ·
Türkçe adlar sözlüğü: [docs/glossary.md](docs/glossary.md).

## Durum — neler denendi, neler denenmedi (12.11.2026)

| Parça | Durum |
|---|---|
| iPhone ↔ iPhone, MultipeerConnectivity | hangel iOS uygulamasında yayında (App Store 2.0.5, Kasım 2026). |
| iPhone ↔ iPhone/iPad, Bluetooth LE (iPhone merkez rolünde) | 09.11.2026'da TestFlight derlemesinde (2.0.7) aktarım gözlendi. App Store sürümünde henüz yok. |
| iPhone ↔ Android, Bluetooth LE | Protokol ortak test vektörleriyle (Swift, Node.js, Java birim testi) denetlendi. **Gerçek cihazla saha denemesi kaydı yok.** |
| Android motoru | hangel'in Android derlemelerinde çalıştı; **bu depodaki Android modülü derlenmedi** (aşağıya bak). |
| AĞ v3 (varlık, davet, yardım çağrısı) | Yalnız iOS, TestFlight derlemeleri. Android bu iletileri yok sayar ve aktarmaz. |
| Wi-Fi Aware | Derleniyor; **gerçek cihazda hiç denenmedi**. |
| Yerel yedek ekranlar (SwiftUI / Android Activity) | Deneysel. hangel kendi web arayüzünü kullanır; Android ekranı 05.11.2026'dan beri üretimde kullanılmadı. |
| Açık kaynak sürüm için yapılan değişiklikler | Eklenti adı, hangel'e özgü bağlantı/anahtarların kaldırılması, Android'de isteğe bağlı Nearby, adın JS'te maskelenmesi — **sahada denenmedi**. |

### Bu sürüm için yapılan doğrulamalar

* `npm run typecheck` (TypeScript 5.7, strict) — geçti.
* `npm test` (Vitest) — 57 protokol testi geçti.
* `npm run verify:ios` — Swift paketi Xcode 27.2 ve capacitor-swift-pm 8.6.0 ile iOS Simulator için ve imzasız genel iOS cihazı için derlendi (ikisi de `BUILD SUCCEEDED`; SDK WiFiAware içerdiği için Wi-Fi Aware kodu da derlendi).
* `npm run verify:cross` — gerçek Swift kodu derlenip TypeScript başvurusuyla iki yönde çerçeve alışverişi yaptı (sırasız, yinelenen
  parça) — hepsi geçti; `swift scripts/cross-verify/vektor-dogrula.swift` — iOS CryptoKit ortak vektörü çözdü.
* Android Java kaynakları **yalnız sözdizimi denetiminden** (java-parser) geçti. Android SDK kurulumu Google'ın lisans şartlarının
  kabulünü gerektirdiği için derlenmedi, JUnit testi çalıştırılmadı. Derleme sorunlarını lütfen bildir.

## Kurulum (Capacitor 8)

```bash
npm install github:hangelapp/hangel-disaster-walkie-talkie
npx cap sync
```

**iOS (15+)** — `Info.plist`'e ekle: `NSBluetoothAlwaysUsageDescription`, `NSMicrophoneUsageDescription`,
`NSLocalNetworkUsageDescription`, `NSBonjourServices` = `_hangel-tlz._tcp`, `_hangel-tlz._udp`,
`NSLocationWhenInUseUsageDescription`, `UIBackgroundModes` = `bluetooth-central`, `bluetooth-peripheral` (arka planda dinleme
istemiyorsan ekleme); isteğe bağlı `WiFiAwareServices` + `com.apple.developer.wifi-aware` yetkisi. `AppDelegate`'te
`import DisasterWalkieTalkiePlugin` ve `didFinishLaunchingWithOptions` içinde `DisasterWalkieTalkie.acilistaBaslat(launchOptions)`.
Ayrıntılı tablo İngilizce README'de.

**Android (API 24+, şifre için Android 9+)** — kütüphane manifesti gerekli izinleri ekler. Varsayılan derleme yalnız Android'in
kendi Bluetooth LE API'lerini kullanır. Daha hızlı Android ↔ Android yolu (Google Play hizmetleri Nearby Connections, **kapalı
kaynak**) için uygulamanın `android/gradle.properties` dosyasına `walkieTalkieNearby=true` yaz.

**JavaScript**

```ts
import { DisasterWalkieTalkie as WT } from 'hangel-disaster-walkie-talkie';

await WT.start({ channel: 'k0', displayName: 'Ayşe Yılmaz' }); // ad kullanılmadan önce "A*** Y*****" olarak maskelenir
await WT.on('changed', async () => goster(await WT.listMessages()));
await WT.sendText('Enkaz altında 2 kişi var, C blok');
await WT.sendHelpCall({ type: 'trapped', people: 2, note: 'C blok' }); // iOS
```

Tam örnek sayfa: [example/](example/). Bütün işlevler web'de ya da yerel yöntem yoksa hata fırlatmaz, boş değer döner.

## Gizlilik

| Veri | Nereye gider | Koruma |
|---|---|---|
| Kanal mesajındaki ses, metin, durum, maskeli ad, konum | Bluetooth/Wi-Fi ile yakındaki cihazlara, 12 aktarıma kadar; her cihazda 72 saat | **Kanal adından ve herkese açık bir sabitten** türeyen anahtarla şifreli — kanal adını bilen herkes çözebilir. Kanalları herkese açık telsiz frekansı gibi düşün. |
| Yardım çağrısı, varlık ("buradayım"), davet (iOS) | Aynı yol; 16 / 3 / 12 aktarım; yardım çağrısı 24 saat | **Şifresiz** (maskeli ad + konum yakındaki herkese görünür). |
| Duyuru | Aynı yol, 3 saat | Şifresiz. |
| Görünen ad | Uygulama `start()`'a verir; sarmalayıcı yerel koda gitmeden maskeler ("Ayşe Yılmaz" → "A*** Y*****"). Yalnız maskeli hâl saklanır ve gönderilir. | — |
| Kişi kodu | Cihaza özgü rastgele 12 karakter; kişiyi bir kez saymak için mesajla gider. Eklenti bunu bir kimliğe bağlamaz. | — |
| Konum | Yalnız işletim sistemi konum izni varsa; ~1 m'ye yuvarlanır; iOS'ta her giden mesaja, Android'de yalnız sayfa verirse eklenir. | İçinde bulunduğu mesajla aynı. |
| Cihazda saklama | iOS: Application Support/`walkie-talkie` (ilk kilit açılışına kadar tam koruma); Android: uygulamaya özel dosya klasörü. | İşletim sistemi korumalı alanı. |
| Sunucu | **Yok.** Eklenti hiçbir sunucuya bağlanmaz. `RelayAdapter` yazarsan o veri akışının ve hukuki dayanağının (KVKK / GDPR) sorumlusu sensin. | — |

MultipeerConnectivity oturumu Apple'ın bağlantı şifrelemesini (`.required`), Wi-Fi Aware işletim sisteminin kimlik doğrulamalı
şifrelemesini kullanır; bu eklentideki Bluetooth LE bağlantıları bağlantı katmanında eşleştirilmez/şifrelenmez.

## Sınırlar ve uyarılar

* **112'nin ve resmî acil durum kanallarının yerine geçmez.** Teslim garantisi ve alındı bildirimi yoktur.
* Menzil kısadır ve çok değişir; ağ ancak yakında uyumlu uygulama çalıştıran yeterince telefon varsa işe yarar.
* **Gizlilik yoktur** (yukarıya bak); hassas konuşmalar için kullanma.
* **Kimlik doğrulama yoktur**: herkes mesaj, durum ya da yardım çağrısı gönderebilir; ad taklit edilebilir; içerik yanlış ya da kötü
  niyetli olabilir. Çevrimdışıyken denetim/şikâyet mümkün değildir.
* Android AĞ v3'ü (yardım çağrısı, varlık, davet) henüz uygulamıyor; bu iletiler Android telefonlardan geçmez.
* iOS arka planda MultipeerConnectivity'yi askıya alır; arka planda aktarım Bluetooth LE'ye ve iOS'un zamanlamasına bağlıdır.
* Android'de ön plan hizmeti yok: uygulama arka plandayken sistem motoru durdurabilir.
* Aktarım pil harcar; pil %20'nin altında aktarım durur.
* Protokol sabitleri hangel uygulamasıyla bilerek ortak tutuldu (birlikte çalışabilirlik). Değiştirmek ayrı bir ağ kurar.
* Yerel koddaki adlar ve yorumlar Türkçedir (sözlüğe bak).

## Bağımlılıklar ve lisanslar

Zorunlu çalışma zamanı bağımlılıkları Apache-2.0 ile uyumlu izin verici lisanslardadır: `@capacitor/core` ve Capacitor iOS/Android
(MIT), `androidx.appcompat` / `androidx.core` (Apache-2.0), Apple sistem çerçeveleri. Tek kapalı kaynak bileşen
`play-services-nearby` **isteğe bağlıdır ve varsayılan derlemede yoktur**. Geliştirme araçları: TypeScript (Apache-2.0), Vitest,
tsx, @types/node (MIT), JUnit 4 (EPL-1.0, yalnız test). Tam tablo İngilizce README'de.

## Katkı, güvenlik, davranış kuralları

[CONTRIBUTING.md](CONTRIBUTING.md) · [SECURITY.md](SECURITY.md) · [CODE_OF_CONDUCT.md](CODE_OF_CONDUCT.md) · [CHANGELOG.md](CHANGELOG.md)

## Lisans ve sahiplik

Telif hakkı 2026 **Uluslararası Sosyal Fayda Derneği (Social Business Global)**, İstanbul. [Apache Lisansı 2.0](LICENSE) ile
lisanslanmıştır; bkz. [NOTICE](NOTICE). "hangel" derneğin markasıdır; lisans marka hakkı vermez, çatallarda kendi uygulama adını kullan.

İletişim: info@socialbusinessglobal.org · https://hangel.org
