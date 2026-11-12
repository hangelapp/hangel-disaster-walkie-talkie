// DisasterWalkieTalkiePlugin — internetsiz afet telsizi (bas-konuş + kısa metin + yardım çağrısı), iOS tarafı.
// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Uluslararası Sosyal Fayda Derneği (Social Business Global)
//
// İlk olarak hangel uygulamasının "Afet Telsizi" özelliği olarak yazıldı (2026-11-04 → 2026-11-09); bu dosya onun açık kaynak
// sürümüdür. Kimlikler ve yorumlar Türkçedir — sözlük: docs/glossary.md. İngilizce JS arayüzü: src/index.ts.
//
// Taşıma: MultipeerConnectivity — DİKKAT: iOS 11'den beri Bluetooth KULLANMAZ, yalnız eşler arası Wi-Fi (Wi-Fi açık olmalı, bir
// ağa bağlı olması gerekmez). Bluetooth yolu TelsizBLE'dir (aşağıda; iPhone ↔ Android ve iPhone ↔ iPhone).
// Servis türü "hangel-tlz" (Info.plist NSBonjourServices: _hangel-tlz._tcp / _udp) — hangel uygulamasıyla aynı ağda
// konuşabilmek için protokol sabitleri değiştirilmedi (docs/protocol.md). MultipeerConnectivity oturumu şifreli (.required).
// Ağ: her telefon hem gönderen hem alan hem AKTARICI. Sakla-ilet: görülmemiş mesaj (kimlikle tekilleştirme) diğer bağlı
// telefonlara iletilir; en çok 12 aktarım (src/protocol/channel.ts MAKS_ATLAMA); pil %20 altındaysa aktarılmaz.
// Yeni bağlanan telefona son 72 saatin mesajları (en çok 30) gönderilir → zincir koptuğunda da mesaj yayılır.
// İçerik: ses + gönderen adı + metin + konum kanal anahtarıyla (HKDF-SHA256 → ChaChaPoly) şifreli. UYARI: anahtar herkese açık
// bir sabitten ve kanal adından türer → kanal adını bilen herkes (bu kaynak kodu okuyan dahil) içeriği çözebilir. Bu bir GİZLİLİK
// garantisi DEĞİLDİR; yalnız başka kanaldaki aktarıcının içeriği kendiliğinden göstermemesini sağlar (README "Privacy").
// Mesajlar 72 saat sonra cihazdan silinir.
// İnternet gelince (isteğe bağlı) uygulama `bekleyenler()` ile kuyruğu alır, KENDİ sunucusuna yükler, `yuklendi()` ile işaretler.
// iOS sınırı: uygulama arka plana geçince iOS MultipeerConnectivity'yi askıya alır; Bluetooth LE arka plan kipleri açıksa sürer.
//
// Bluetooth LE: iPhone hem ÇEVRE BİRİMİ (Android ve diğer iPhone'lar bağlanır) hem MERKEZDİR (yakındaki iPhone'lara bağlanır).
// Biçim ve şifre iki platformda aynıdır — tek başvuru: src/protocol/frame.ts (çerçeve, UUID'ler, ortak test vektörü). Her mesaj
// tüm taşımalara aktarılır (kimlikle tekilleştirme). Kısa METİN mesajı (mime "text/plain", ≤280 kod noktası) ve konum.
// Her giden iletiye maskeli ad ("A*** Y*****") + varsa konum (≤2 dk taze GPS ya da ön planda tek seferlik istek) + cihaza özgü
// rastgele kişi kodu eklenir.
// AĞ v3 iletileri (varlık, davet, davet yanıtı, yardım çağrısı, yardıma gidiyorum) — kurallar src/protocol/mesh.ts; ŞİFRESİZDİR
// (maskeli ad + konum yakındaki herkese açıktır). Yalnız iOS'ta uygulanmıştır; Android sürümü bu iletileri yok sayar.

import Foundation
import UIKit
import SwiftUI
import Capacitor
import MultipeerConnectivity
import AVFoundation
import CryptoKit
import Network
import UserNotifications
import CoreBluetooth
import CoreLocation
import Combine

// MARK: - Model

struct TelsizMesaj: Codable, Identifiable, Equatable {
    let id: String
    let kanal: String
    let olusturulduMs: Int64
    var atlama: Int
    let sureMs: Int
    let mime: String
    /// ChaChaPoly combined (nonce + şifreli + etiket), base64. İçinde {ad, ses(base64)} JSON'u.
    let veri: String
    var alindiMs: Int64
    var kendim: Bool
    var yuklendi: Bool
}

private struct TelsizIcerik: Codable {
    var ad: String
    /// Sesli mesajda base64; metin mesajında "".
    let ses: String
    /// 2026-11-05: metin mesajı (mime "text/plain") ve isteğe bağlı konum. Eski derlemeler bu alanları yok sayar.
    var metin: String? = nil
    var enlem: Double? = nil
    var boylam: Double? = nil
    /// 2026-11-08 (Yakın ağ): durum mesajı — "guvende" | "toplanma" | "yardim" + cihaza özgü rastgele kişi kodu (sayım için).
    /// Eski derlemeler bu alanları yok sayar ve `metin`i (gönderenin dilindeki okunur cümle) düz metin olarak gösterir.
    var durum: String? = nil
    var kisi: String? = nil
    /// 2026-11-09: konumun alındığı an (ms). Eski derlemeler yok sayar.
    var konumMs: Int64? = nil
}

/// Çözülmüş mesaj içeriği.
struct TelsizCozum {
    let ad: String
    let ses: Data?
    let metin: String?
    let enlem: Double?
    let boylam: Double?
    var durum: String? = nil
    var kisi: String? = nil
    var konumMs: Int64? = nil
}

/// Mesajın geldiği yol: iPhone (MultipeerConnectivity) ya da Android (Bluetooth LE bağlantı kimliği).
/// 2026-11-06: `ek` — ek taşıma (Wi-Fi Aware, iOS 26+; TelsizWifiAware.swift) bağlantı kimliği.
enum TelsizKaynak: Equatable {
    case mpc(MCPeerID)
    case ble(String)
    case ek(String)
}

/// 2026-11-06: MultipeerConnectivity ve Bluetooth LE'nin yanına takılan ek taşıma (Wi-Fi Aware). Aynı kablo biçimini taşır;
/// motor her mesajı tüm taşımalara verir, kimlikle tekilleştirir.
protocol TelsizEkTasima: AnyObject {
    var yukAlindi: ((String, Data) -> Void)? { get set }
    var yeniBaglanti: ((String) -> Void)? { get set }
    var baglantilarDegisti: (([String]) -> Void)? { get set }
    func baslat()
    func durdur()
    func gonder(_ veri: Data, haric: String?)
    func gonderKime(_ id: String, _ veri: Data)
}

/// 2026-11-04: etkinlik duyurusu (düz metin; duyuru zaten katılımcılara açık). v=2, tur="duyuru".
private struct DuyuruKablo: Codable {
    let v: Int
    let tur: String
    let id: String
    let t: Int64
    let atlama: Int
    let etkinlikId: String
    let baslik: String
    let metin: String
}

private struct TelsizKablo: Codable {
    let v: Int
    let id: String
    let kanal: String
    let t: Int64
    let atlama: Int
    let sure: Int
    let mime: String
    let veri: String
}

// MARK: - Metinler (11 dil; cihaz dili, yoksa Türkçe)

struct TelsizMetin {
    /// Uygulamanın görünen adı (metinlerde). Info.plist CFBundleDisplayName → CFBundleName → "app".
    static var uygulamaAdi: String {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
            ?? (Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String) ?? "app"
    }
    let baslik, kapat, internetsiz, cevrimici, bagliTelefon, basKonus, kaydediliyor, mesajYok, sen, aktarim, ekranAcik, testPaneli, teslim, mikrofonIzni, gonderildi: String
    // 2026-11-05: metin + konum (Android TelsizMetin ile aynı ifadeler)
    var metinIpucu = "", gonder = "", konumEkle = "", konumYok = "", konum = ""

    fileprivate func with(metinIpucu v: String) -> TelsizMetin { var c = self; c.metinIpucu = v; return c }
    fileprivate func with(gonder v: String) -> TelsizMetin { var c = self; c.gonder = v; return c }
    fileprivate func with(konumEkle v: String) -> TelsizMetin { var c = self; c.konumEkle = v; return c }
    fileprivate func with(konumYok v: String) -> TelsizMetin { var c = self; c.konumYok = v; return c }
    fileprivate func with(konum v: String) -> TelsizMetin { var c = self; c.konum = v; return c }

    static func simdiki() -> TelsizMetin {
        let dil = String((Locale.preferredLanguages.first ?? "tr").prefix(2))
        switch dil {
        case "en": return TelsizMetin(baslik: "Disaster Radio", kapat: "Close", internetsiz: "Offline", cevrimici: "Online", bagliTelefon: "devices nearby", basKonus: "Hold to talk", kaydediliyor: "Recording… release to send", mesajYok: "No messages yet. Keep Wi-Fi and Bluetooth on; nearby \(TelsizMetin.uygulamaAdi) phones will appear here.", sen: "You", aktarim: "hops", ekranAcik: "Keep this screen open: iOS pauses the connection in the background.", testPaneli: "Test panel", teslim: "delivery", mikrofonIzni: "Microphone permission is needed (Settings › \(TelsizMetin.uygulamaAdi)).", gonderildi: "Sent to nearby phones").with(metinIpucu: "Write a short message…").with(gonder: "Send").with(konumEkle: "Add my location").with(konumYok: "Couldn't get location; sent without it.").with(konum: "Location")
        case "ru": return TelsizMetin(baslik: "Рация при ЧС", kapat: "Закрыть", internetsiz: "Без интернета", cevrimici: "Онлайн", bagliTelefon: "устройств рядом", basKonus: "Удерживай и говори", kaydediliyor: "Запись… отпусти, чтобы отправить", mesajYok: "Сообщений пока нет. Держи Wi-Fi и Bluetooth включёнными — телефоны \(TelsizMetin.uygulamaAdi) рядом появятся здесь.", sen: "Ты", aktarim: "перед.", ekranAcik: "Не закрывай экран: в фоне iOS приостанавливает связь.", testPaneli: "Тестовая панель", teslim: "доставка", mikrofonIzni: "Нужен доступ к микрофону (Настройки › \(TelsizMetin.uygulamaAdi)).", gonderildi: "Отправлено телефонам рядом").with(metinIpucu: "Напиши короткое сообщение…").with(gonder: "Отправить").with(konumEkle: "Добавить моё местоположение").with(konumYok: "Не удалось определить местоположение; отправлено без него.").with(konum: "Местоположение")
        case "ar": return TelsizMetin(baslik: "لاسلكي الكوارث", kapat: "إغلاق", internetsiz: "دون إنترنت", cevrimici: "متصل", bagliTelefon: "أجهزة قريبة", basKonus: "اضغط مطولًا وتحدث", kaydediliyor: "جارٍ التسجيل… اترك للإرسال", mesajYok: "لا رسائل بعد. أبقِ Wi-Fi وBluetooth مفعّلين، وستظهر هواتف \(TelsizMetin.uygulamaAdi) القريبة هنا.", sen: "أنت", aktarim: "قفزات", ekranAcik: "أبقِ هذه الشاشة مفتوحة: يوقف iOS الاتصال في الخلفية.", testPaneli: "لوحة الاختبار", teslim: "التسليم", mikrofonIzni: "يلزم إذن الميكروفون (الإعدادات › \(TelsizMetin.uygulamaAdi)).", gonderildi: "أُرسلت إلى الهواتف القريبة").with(metinIpucu: "اكتب رسالة قصيرة…").with(gonder: "إرسال").with(konumEkle: "أضف موقعي").with(konumYok: "تعذّر تحديد الموقع؛ أُرسلت دونه.").with(konum: "الموقع")
        case "fa": return TelsizMetin(baslik: "بی‌سیم بحران", kapat: "بستن", internetsiz: "آفلاین", cevrimici: "آنلاین", bagliTelefon: "دستگاه نزدیک", basKonus: "نگه دار و صحبت کن", kaydediliyor: "در حال ضبط… رها کن تا ارسال شود", mesajYok: "هنوز پیامی نیست. وای‌فای و بلوتوث روشن بماند؛ گوشی‌های نزدیک دارای \(TelsizMetin.uygulamaAdi) اینجا دیده می‌شوند.", sen: "تو", aktarim: "انتقال", ekranAcik: "این صفحه را باز نگه دار: iOS در پس‌زمینه اتصال را متوقف می‌کند.", testPaneli: "پنل آزمایش", teslim: "تحویل", mikrofonIzni: "اجازهٔ میکروفون لازم است (تنظیمات › \(TelsizMetin.uygulamaAdi)).", gonderildi: "به گوشی‌های نزدیک ارسال شد").with(metinIpucu: "یک پیام کوتاه بنویس…").with(gonder: "ارسال").with(konumEkle: "موقعیتم را اضافه کن").with(konumYok: "موقعیت پیدا نشد؛ بدون آن ارسال شد.").with(konum: "موقعیت")
        case "es": return TelsizMetin(baslik: "Radio de emergencias", kapat: "Cerrar", internetsiz: "Sin conexión", cevrimici: "En línea", bagliTelefon: "dispositivos cerca", basKonus: "Mantén pulsado para hablar", kaydediliyor: "Grabando… suelta para enviar", mesajYok: "Aún no hay mensajes. Deja Wi-Fi y Bluetooth activados; los teléfonos cercanos con \(TelsizMetin.uygulamaAdi) aparecerán aquí.", sen: "Tú", aktarim: "saltos", ekranAcik: "Mantén esta pantalla abierta: iOS pausa la conexión en segundo plano.", testPaneli: "Panel de prueba", teslim: "entrega", mikrofonIzni: "Se necesita permiso de micrófono (Ajustes › \(TelsizMetin.uygulamaAdi)).", gonderildi: "Enviado a teléfonos cercanos").with(metinIpucu: "Escribe un mensaje corto…").with(gonder: "Enviar").with(konumEkle: "Añadir mi ubicación").with(konumYok: "No se pudo obtener la ubicación; se envió sin ella.").with(konum: "Ubicación")
        case "ha": return TelsizMetin(baslik: "Rediyon Bala'i", kapat: "Rufe", internetsiz: "Babu intanet", cevrimici: "A kan layi", bagliTelefon: "na'urori a kusa", basKonus: "Riƙe ka yi magana", kaydediliyor: "Ana ɗauka… saki don aikawa", mesajYok: "Babu saƙo tukuna. Bar Wi-Fi da Bluetooth a kunne; wayoyin \(TelsizMetin.uygulamaAdi) na kusa za su bayyana nan.", sen: "Kai", aktarim: "miƙa", ekranAcik: "Bar wannan allon a buɗe: iOS yana dakatar da haɗi a bayan fage.", testPaneli: "Allon gwaji", teslim: "isarwa", mikrofonIzni: "Ana buƙatar izinin makirofo (Saituna › \(TelsizMetin.uygulamaAdi)).", gonderildi: "An aika ga wayoyin kusa").with(metinIpucu: "Rubuta gajeren saƙo…").with(gonder: "Aika").with(konumEkle: "Ƙara wurin da nake").with(konumYok: "Ba a samu wuri ba; an aika ba tare da shi ba.").with(konum: "Wuri")
        case "de": return TelsizMetin(baslik: "Katastrophenfunk", kapat: "Schließen", internetsiz: "Offline", cevrimici: "Online", bagliTelefon: "Geräte in der Nähe", basKonus: "Gedrückt halten und sprechen", kaydediliyor: "Aufnahme… zum Senden loslassen", mesajYok: "Noch keine Nachrichten. WLAN und Bluetooth eingeschaltet lassen – \(TelsizMetin.uygulamaAdi)-Handys in der Nähe erscheinen hier.", sen: "Du", aktarim: "Weiterl.", ekranAcik: "Diesen Bildschirm offen lassen: iOS pausiert die Verbindung im Hintergrund.", testPaneli: "Testpanel", teslim: "Zustellung", mikrofonIzni: "Mikrofonzugriff nötig (Einstellungen › \(TelsizMetin.uygulamaAdi)).", gonderildi: "An Handys in der Nähe gesendet").with(metinIpucu: "Kurze Nachricht schreiben…").with(gonder: "Senden").with(konumEkle: "Meinen Standort anhängen").with(konumYok: "Standort nicht verfügbar; ohne Standort gesendet.").with(konum: "Standort")
        case "hu": return TelsizMetin(baslik: "Katasztrófarádió", kapat: "Bezárás", internetsiz: "Offline", cevrimici: "Online", bagliTelefon: "eszköz a közelben", basKonus: "Tartsd lenyomva és beszélj", kaydediliyor: "Felvétel… engedd el a küldéshez", mesajYok: "Még nincs üzenet. Hagyd bekapcsolva a Wi-Fi-t és a Bluetooth-t; a közeli \(TelsizMetin.uygulamaAdi)es telefonok itt jelennek meg.", sen: "Te", aktarim: "továbbítás", ekranAcik: "Hagyd nyitva ezt a képernyőt: háttérben az iOS szünetelteti a kapcsolatot.", testPaneli: "Tesztpanel", teslim: "kézbesítés", mikrofonIzni: "Mikrofon-engedély kell (Beállítások › \(TelsizMetin.uygulamaAdi)).", gonderildi: "Elküldve a közeli telefonoknak").with(metinIpucu: "Írj egy rövid üzenetet…").with(gonder: "Küldés").with(konumEkle: "Helyzetem hozzáadása").with(konumYok: "Nem sikerült helyzetet kérni; nélküle küldtük el.").with(konum: "Helyzet")
        case "fr": return TelsizMetin(baslik: "Radio de crise", kapat: "Fermer", internetsiz: "Hors ligne", cevrimici: "En ligne", bagliTelefon: "appareils à proximité", basKonus: "Maintiens pour parler", kaydediliyor: "Enregistrement… relâche pour envoyer", mesajYok: "Aucun message. Garde le Wi-Fi et le Bluetooth activés ; les téléphones \(TelsizMetin.uygulamaAdi) proches apparaîtront ici.", sen: "Toi", aktarim: "relais", ekranAcik: "Garde cet écran ouvert : iOS suspend la connexion en arrière-plan.", testPaneli: "Panneau de test", teslim: "livraison", mikrofonIzni: "Autorisation du micro nécessaire (Réglages › \(TelsizMetin.uygulamaAdi)).", gonderildi: "Envoyé aux téléphones proches").with(metinIpucu: "Écris un court message…").with(gonder: "Envoyer").with(konumEkle: "Ajouter ma position").with(konumYok: "Position indisponible ; envoyé sans elle.").with(konum: "Position")
        case "az": return TelsizMetin(baslik: "Fəlakət Ratsiyası", kapat: "Bağla", internetsiz: "İnternetsiz", cevrimici: "Onlayn", bagliTelefon: "cihaz yaxında", basKonus: "Basılı saxla və danış", kaydediliyor: "Yazılır… göndərmək üçün burax", mesajYok: "Hələ mesaj yoxdur. Wi-Fi və Bluetooth açıq qalsın; yaxındakı \(TelsizMetin.uygulamaAdi)-li telefonlar burada görünəcək.", sen: "Sən", aktarim: "ötürmə", ekranAcik: "Bu ekranı açıq saxla: iOS arxa planda bağlantını dayandırır.", testPaneli: "Test paneli", teslim: "çatdırılma", mikrofonIzni: "Mikrofon icazəsi lazımdır (Ayarlar › \(TelsizMetin.uygulamaAdi)).", gonderildi: "Yaxındakı telefonlara göndərildi").with(metinIpucu: "Qısa mesaj yaz…").with(gonder: "Göndər").with(konumEkle: "Məkanımı əlavə et").with(konumYok: "Məkan alınmadı; mesaj məkansız göndərildi.").with(konum: "Məkan")
        case "da": return TelsizMetin(baslik: "Katastroferadio", kapat: "Luk", internetsiz: "Offline", cevrimici: "Online", bagliTelefon: "enheder i nærheden", basKonus: "Hold nede for at tale", kaydediliyor: "Optager… slip for at sende", mesajYok: "Ingen beskeder endnu. Lad Wi-Fi og Bluetooth være slået til; \(TelsizMetin.uygulamaAdi)-telefoner i nærheden vises her.", sen: "Dig", aktarim: "hop", ekranAcik: "Hold denne skærm åben: iOS sætter forbindelsen på pause i baggrunden.", testPaneli: "Testpanel", teslim: "levering", mikrofonIzni: "Der kræves tilladelse til mikrofonen (Indstillinger › \(TelsizMetin.uygulamaAdi)).", gonderildi: "Sendt til telefoner i nærheden").with(metinIpucu: "Skriv en kort besked…").with(gonder: "Send").with(konumEkle: "Tilføj min placering").with(konumYok: "Placeringen kunne ikke hentes; sendt uden.").with(konum: "Placering")
        default: return TelsizMetin(baslik: "Afet Telsizi", kapat: "Kapat", internetsiz: "İnternetsiz", cevrimici: "Çevrimiçi", bagliTelefon: "cihaz yakında", basKonus: "Basılı tut ve konuş", kaydediliyor: "Kaydediliyor… göndermek için bırak", mesajYok: "Henüz mesaj yok. Wi-Fi ve Bluetooth açık kalsın; yakındaki \(TelsizMetin.uygulamaAdi)'li telefonlar burada görünür.", sen: "Sen", aktarim: "aktarım", ekranAcik: "Bu ekran açık kalsın: iOS arka planda bağlantıyı durdurur.", testPaneli: "Test paneli", teslim: "teslim", mikrofonIzni: "Mikrofon izni gerekli (Ayarlar › \(TelsizMetin.uygulamaAdi)).", gonderildi: "Yakındaki telefonlara gönderildi").with(metinIpucu: "Kısa mesaj yaz…").with(gonder: "Gönder").with(konumEkle: "Konumumu ekle").with(konumYok: "Konum alınamadı; mesaj konumsuz gönderildi.").with(konum: "Konum")
        }
    }
}

// MARK: - Motor

final class TelsizMotoru: NSObject, ObservableObject {
    static let shared = TelsizMotoru()

    static let servisTuru = "hangel-tlz"
    static let maksAtlama = 12
    static let omurMs: Int64 = 72 * 3600 * 1000
    static let maksSureSn: TimeInterval = 30
    /// Etkinlik duyurusu en çok 3 saat dolaşır.
    static let duyuruOmurMs: Int64 = 3 * 3600 * 1000
    static let metinMime = "text/plain"
    static let maksMetin = 280
    /// Yakın ağ durum mesajları (src/protocol/frame.ts DURUMLAR / DURUM_OMRU_MS / kisiGecerli ile aynı).
    static let durumlar: Set<String> = ["guvende", "toplanma", "yardim"]
    static let durumOmrMs: Int64 = 12 * 3600 * 1000
    static func kisiGecerli(_ k: String) -> Bool {
        (8...16).contains(k.count) && k.allSatisfy { $0.isASCII && ($0.isLowercase || $0.isNumber) }
    }
    /// Bluetooth'ta yeni bağlanana geçmiş: metinlerin hepsi + en yeni 3 ses (src/protocol/frame.ts bleGecmisi).
    static let bleGecmisSes = 3

    @Published private(set) var baglilar: [String] = []
    private var mpcBaglilar: [String] = []
    private var bleBaglilar: [String] = []
    private let ble = TelsizBLE()
    /// 2026-11-06: ek taşıma (Wi-Fi Aware) ve bağlı telefonları.
    private var ek: TelsizEkTasima?
    private var ekBaglilar: [String] = []
    @Published private(set) var mesajlar: [TelsizMesaj] = []
    @Published private(set) var kayitta = false
    @Published private(set) var calanId: String?
    @Published private(set) var internetVar = false
    @Published var bilgi: String?
    /// 2026-11-05 (tek ekran): web sayfası çalmayı kendisi yönetir (sesli dinleme anahtarı) → yerel otomatik çalma kapalı.
    var otomatikCal = true

    private(set) var kanal = "test"
    private(set) var kanalAdi = ""
    private(set) var ad = ""
    private(set) var testPaneli = false

    private var benimPeer: MCPeerID?
    private var oturum: MCSession?
    private var yayinci: MCNearbyServiceAdvertiser?
    private var arayici: MCNearbyServiceBrowser?
    private var tumu: [String: TelsizMesaj] = [:]
    private var duyurular: [String: DuyuruKablo] = [:]
    private var kayitci: AVAudioRecorder?
    private var kayitBaslangic: Date?
    private var calici: AVAudioPlayer?
    private var calKuyrugu: [TelsizMesaj] = []
    private let yol = NWPathMonitor()
    private let kuyruk = DispatchQueue(label: "org.hangel.telsiz")
    private var calisiyor = false
    /// TAM kip çalışıyor mu (kullanıcı telsizi açtı: Wi-Fi + Bluetooth); yalnız Bluetooth kipinde false.
    private var tamCalisiyor = false
    /// Telsiz ekranı en az bir kez açıldı mı (bilgi satırı görüldü). Kapalıyken cihaz ağda aktarıcıdır ama "buradayım" sinyali adsız ve
    /// konumsuz gider, kanal iletileri için bildirim gösterilmez (ör. etkinlikte işaretçi için Bluetooth izni vermiş biri rahatsız olmasın).
    static let kullanildiAnahtari = "walkieTalkieKullanildi"
    var telsizKullanildi: Bool { UserDefaults.standard.bool(forKey: Self.kullanildiAnahtari) }
    /// Kullanıcı hâlâ basılı tutuyor mu (izin penceresi sürerken bırakırsa kayıt hiç başlamasın / hemen bitsin).
    private var basiliIstek = false
    /// 2026-11-08: tarayıcının "bulundu" dediği ve kaybolmadığı iPhone'lar (yalnız ana iş parçacığı). MultipeerConnectivity bir telefonu
    /// yalnız BİR KEZ "bulundu" bildirir; bağlantı kopunca ya da davet zaman aşımına uğrayınca kendiliğinden yeniden davet edilmezdi
    /// → telefon yanında durduğu hâlde "0 telefon bağlı" kalıyordu. Kopunca kısa beklemeyle yeniden davet edilir.
    private var bulunanlar: Set<MCPeerID> = []
    private var davetDenemesi: [MCPeerID: Int] = [:]
    /// Bağlanmakta olan iPhone'lar (davet kabul edildi, oturum kuruluyor) — yedek davet araya girmesin.
    private var baglaniyor: Set<MCPeerID> = []
    /// Süresi geçen (72 sa) mesajlar çalışırken de bellekten ve diskten atılır (önceden yalnız açılışta).
    private var sonBudamaMs: Int64 = 0
    /// 2026-11-08 FAZ 2 (2.0.7): "Arka planda dinlemeye devam et" (telsiz kartı, varsayılan KAPALI). Info.plist'te
    /// UIBackgroundModes bluetooth-central + bluetooth-peripheral var; anahtar KAPALIYKEN uygulama arka plana geçince Bluetooth LE
    /// burada durdurulur (eski davranış: iOS askıya alırdı), ön plana dönünce yeniden başlar. AÇIKKEN arka planda da Bluetooth LE ile
    /// mesaj alınır ve aktarılır (MultipeerConnectivity / Wi-Fi Aware'i iOS yine askıya alır); kanaldaki yeni mesaj yerel bildirimle duyurulur.
    /// 2026-11-09: HER ZAMAN AÇIK. Soru arayüzden kalktı;
    /// eski anahtar ("walkieTalkieArkaPlan", 2.0.7 deneme derlemelerinde kapatılmış olabilir) artık okunmaz. Yeni anahtar yalnız
    /// `arkaPlanAyarla` (geriye uyum) çağrılırsa yazılır; yoksa açık. Teşhis 09.11: anahtar kapalıyken ekran kilitlenince Bluetooth LE
    /// duruyor, açılınca yeni adresle yeniden kuruluyordu → bağlantı 1–3 dk'da bir kopuyordu.
    static let arkaPlanAnahtari = "walkieTalkieArkaPlanHep"
    private(set) var arkaPlan = (UserDefaults.standard.object(forKey: TelsizMotoru.arkaPlanAnahtari) as? Bool) ?? true
    /// Arka plana geçerken (anahtar kapalı) Bluetooth LE durduruldu mu — ön plana dönüşte yeniden başlatmak için.
    private var bleArkaPlandaDurdu = false

    // 2026-11-09 AĞ v3 durumu (yalnız ana iş parçacığı) — "AĞ v3" bölümünde kullanılır.
    /// Bağlantı anahtarı ("mpc:ad", "ble:uuid", "ek:kimlik") → o bağlantının kişi kodu (atlama 0 varlık iletisinden öğrenilir).
    fileprivate var baglantiKisi: [String: String] = [:]
    fileprivate var agdakiler: [String: TelsizAgCihaz] = [:]
    /// Görülen v3 ileti kimlikleri → unutulma anı (ms).
    fileprivate var agGorulen: [String: Int64] = [:]
    /// Kişi başına son varlık iletisi (yeni bağlanana aktarmak için; aktarım hakkı kalmışsa).
    fileprivate var sonVarliklar: [String: TelsizAgKablo] = [:]
    fileprivate var yardimlar: [String: TelsizYardimKaydi] = [:]
    /// "Yardıma gidiyorum" iletileri (yeni bağlanana aktarmak için).
    fileprivate var gidiyorumlar: [String: TelsizAgKablo] = [:]
    fileprivate var gelenDavetler: [String: TelsizAgKablo] = [:]
    fileprivate var gidenDavetler: [String: TelsizAgKablo] = [:]
    fileprivate var sonrakiVarlikMs: Int64 = 0
    fileprivate var sonKonumTazelemeMs: Int64 = 0
    fileprivate var sonTaramaTazelemeMs: Int64 = 0
    fileprivate var nabiz: Timer?
    fileprivate var sonCihazOzeti = ""
    fileprivate var sonYardimBildirimMs: Int64 = 0
    /// Bağlantı anahtarı → ilk görülme (ms) ve o bağlantıya son doğrudan varlık (ms).
    fileprivate var baglantiIlkMs: [String: Int64] = [:]
    fileprivate var varlikGonderilen: [String: Int64] = [:]
    /// Web'e giden olaylar (eklenti dinler): ("cihazlar" | "davet" | "davetYaniti" | "yardim" | "bildirimeDokunuldu", veri).
    let olaylar = PassthroughSubject<(String, [String: Any]), Never>()

    private override init() {
        super.init()
        ble.yukAlindi = { [weak self] id, veri in self?.al(veri, kimden: .ble(id)) }
        ble.yeniBaglanti = { [weak self] id in self?.bleYeniBaglanti(id) }
        ble.baglantilarDegisti = { [weak self] adlar in
            guard let self else { return }
            self.bleBaglilar = adlar
            self.bagliGuncelle()
        }
        yol.pathUpdateHandler = { [weak self] p in
            DispatchQueue.main.async { self?.internetVar = (p.status == .satisfied && !p.usesInterfaceType(.other)) }
        }
        yol.start(queue: kuyruk)
        diskYukle()
        yardimDiskYukle()
        // Arka plandan dönünce: iOS arka planda MultipeerConnectivity yayın/aramasını askıya alır ve oturumları düşürür; ön plana
        // dönüşte yeniden başlatılır (yakındaki telefonlar yeniden "bulunur" ve davet edilir). Bluetooth LE kendini toparlar.
        NotificationCenter.default.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main) { [weak self] _ in
            self?.onPlanaDondu()
        }
        NotificationCenter.default.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
            self?.arkaPlanaGecti()
        }
    }

    /// Anahtar kapalıysa Bluetooth LE'yi durdurur (arka plan Bluetooth modu yalnız kullanıcı açtığında kullanılır).
    private func arkaPlanaGecti() {
        guard calisiyor else { return }
        if arkaPlan {
            // Arka planda iOS yinelenen tarama sonuçlarını vermez: taramayı yeniden başlatmak "görüldü" listesini sıfırlar → bağlantısı
            // kopan telefon arka planda da yeniden bulunur. Bekleyen bağlanma istekleri (connect) arka planda da sürer.
            ble.taramayiTazele()
            return
        }
        ble.durdur()
        bleArkaPlandaDurdu = true
    }

    /// Geriye uyum (2.0.7 deneme derlemelerinin sayfası). Arayüzde artık soru yok; varsayılan ve beklenen değer AÇIK.
    func arkaPlanAyarla(_ acik: Bool) {
        arkaPlan = acik
        UserDefaults.standard.set(acik, forKey: Self.arkaPlanAnahtari)
        yayinla()
    }

    private func onPlanaDondu() {
        if bleArkaPlandaDurdu {
            bleArkaPlandaDurdu = false
            if calisiyor { ble.baslat() }
        }
        guard calisiyor else { return }
        ble.taramayiTazele()
        TelsizKonum.shared.tazele()
        // Ön plana dönüşte hemen "buradayım" (arka planda zamanlayıcı çalışmamış olabilir).
        sonrakiVarlikMs = 0
        yayinci?.stopAdvertisingPeer()
        yayinci?.startAdvertisingPeer()
        arayici?.stopBrowsingForPeers()
        bulunanlar.removeAll()
        davetDenemesi.removeAll()
        baglaniyor.removeAll()
        arayici?.startBrowsingForPeers()
    }

    /// Yakındaki iPhone'u oturuma davet eder. Ana iş parçacığında.
    /// Kural: adı küçük olan hemen davet eder (çift davet yarışı olmasın). 2026-11-08: Bonjour çözümü TEK YÖNLÜ kalabiliyor — iki
    /// simülatörde ölçüldü: B, A'yı "buldu" ama A, B'nin kaydını hiç çözemedi; adı küçük olan A olduğu için kimse davet etmedi ve
    /// iki telefon yan yana dururken bağlanmadı. Artık adı büyük olan da 8 sn sonra hâlâ bağlı/bağlanıyor değilse kendisi davet eder.
    fileprivate func davetEt(_ p: MCPeerID, yedek: Bool = false) {
        guard calisiyor, let s = oturum, let ben = benimPeer, let a = arayici, bulunanlar.contains(p),
              !s.connectedPeers.contains(p), !baglaniyor.contains(p), s.connectedPeers.count < 7 else { return }
        if ben.displayName < p.displayName || yedek {
            a.invitePeer(p, to: s, withContext: nil, timeout: 20)
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self] in self?.davetEt(p, yedek: true) }
        }
    }

    // MARK: Ayarlar

    func ayarla(kanal: String?, kanalAdi: String?, ad: String?, testPaneli: Bool?) {
        let d = UserDefaults.standard
        if let k = kanal, !k.isEmpty { d.set(k, forKey: "walkieTalkieKanal") }
        if let k = kanalAdi { d.set(k, forKey: "walkieTalkieKanalAdi") }
        if let a = ad, !a.isEmpty { d.set(a, forKey: "walkieTalkieAd") }
        if let s = testPaneli { d.set(s, forKey: "walkieTalkieTestPaneli") }
        self.kanal = d.string(forKey: "walkieTalkieKanal") ?? "test"
        self.kanalAdi = d.string(forKey: "walkieTalkieKanalAdi") ?? ""
        self.ad = d.string(forKey: "walkieTalkieAd") ?? ""
        self.testPaneli = d.bool(forKey: "walkieTalkieTestPaneli")
        yayinla()
    }

    // MARK: Bağlantı

    /// Kullanıcı telsizi açtı (sayfa `motor` / `izinIste`, yerel ekran, duyuru, yardım): TAM kip — Bluetooth LE + MultipeerConnectivity
    /// (Wi-Fi) + ek taşıma; ilk kez konum ve bildirim izni sorulur.
    func baslat() { baslat(kip: .tam) }

    /// 2026-11-09:
    ///  - `.yalnizBluetooth`: uygulama açılışında (Bluetooth izni ÖNCEDEN verilmişse) ya da iOS uygulamayı Bluetooth olayıyla arka
    ///    planda yeniden başlattığında (CoreBluetooth durum geri yükleme) — arayüzsüz; yalnız Bluetooth LE + AĞ v3. HİÇBİR izin penceresi
    ///    açılmaz: MultipeerConnectivity "yerel ağ" iznini, konum/bildirim de kendi izinlerini sorardı → bunlar yalnız `.tam`da.
    ///  - `.tam`: yukarıdaki; Bluetooth kipinde çalışıyorsa eksik kısımlar eklenir.
    enum BaslatKipi { case tam, yalnizBluetooth }

    func baslat(kip: BaslatKipi) {
        if !calisiyor {
            calisiyor = true
            UIDevice.current.isBatteryMonitoringEnabled = true
            ble.baslat(gucUyarisi: kip == .tam)
            agBaslat()
        }
        guard kip == .tam, !tamCalisiyor else { return }
        tamCalisiyor = true
        ble.tamKip()
        // Telsiz ekranını gören kişi (paylaşım bilgi satırı) — "buradayım" sinyalinde maskeli ad ve konum yalnız bundan sonra gider.
        UserDefaults.standard.set(true, forKey: Self.kullanildiAnahtari)
        TelsizKonum.shared.izinIsteGerekirse()
        bildirimIzniGerekirse()
        let ad = String((UIDevice.current.name.isEmpty ? "telsiz" : UIDevice.current.name).prefix(20))
        let peer = MCPeerID(displayName: "\(ad)-\(Int.random(in: 1000...9999))")
        benimPeer = peer
        let s = MCSession(peer: peer, securityIdentity: nil, encryptionPreference: .required)
        s.delegate = self
        oturum = s
        let y = MCNearbyServiceAdvertiser(peer: peer, discoveryInfo: ["v": "1"], serviceType: Self.servisTuru)
        y.delegate = self
        y.startAdvertisingPeer()
        yayinci = y
        let a = MCNearbyServiceBrowser(peer: peer, serviceType: Self.servisTuru)
        a.delegate = self
        a.startBrowsingForPeers()
        arayici = a
        ek?.baslat()
    }

    /// Açılışta / Bluetooth geri yüklemesinde arayüzsüz başlatma (DisasterWalkieTalkie.acilistaBaslat). Kanal kayıtlı değilse Genel (k0);
    /// sesli mesajlar kendiliğinden ÇALINMAZ (kişi başka sayfadayken hoparlörden ses çıkmasın) — telsiz sayfası açılınca sayfa yönetir.
    func kendiligindenBaslat() {
        guard !calisiyor else { return }
        let d = UserDefaults.standard
        if d.string(forKey: "walkieTalkieKanal") == nil { d.set("k0", forKey: "walkieTalkieKanal") }
        ayarla(kanal: nil, kanalAdi: nil, ad: nil, testPaneli: nil)
        otomatikCal = false
        baslat(kip: .yalnizBluetooth)
    }

    /// `bleBaglilar` tam Bluetooth kimlikleridir (AĞ v3 bağlantı eşlemesi için); görünen liste kısaltılır.
    private func bagliGuncelle() {
        DispatchQueue.main.async {
            self.baglilar = self.mpcBaglilar + self.bleBaglilar.map { "BLE·" + String($0.suffix(5)) } + self.ekBaglilar
            self.cihazlarDegistiyse()
        }
    }

    /// Şu an açık doğrudan bağlantıların anahtarları ("mpc:…", "ble:…", "ek:…"). Ana iş parçacığında.
    fileprivate var aktifBaglantilar: [String] {
        mpcBaglilar.map { "mpc:" + $0 } + bleBaglilar.map { "ble:" + $0 } + ekBaglilar.map { "ek:" + $0 }
    }

    fileprivate static func kaynakAnahtari(_ k: TelsizKaynak) -> String {
        switch k {
        case .mpc(let p): return "mpc:" + p.displayName
        case .ble(let b): return "ble:" + b
        case .ek(let e): return "ek:" + e
        }
    }

    func durdur() {
        calisiyor = false
        tamCalisiyor = false
        bleArkaPlandaDurdu = false
        bulunanlar.removeAll()
        davetDenemesi.removeAll()
        baglaniyor.removeAll()
        yayinci?.stopAdvertisingPeer()
        arayici?.stopBrowsingForPeers()
        oturum?.disconnect()
        yayinci = nil
        arayici = nil
        oturum = nil
        ble.durdur()
        ek?.durdur()
        nabiz?.invalidate()
        nabiz = nil
        mpcBaglilar = []
        bleBaglilar = []
        ekBaglilar = []
        bagliGuncelle()
    }

    private func pilYeterli() -> Bool {
        let p = UIDevice.current.batteryLevel
        return p < 0 || p >= 0.2
    }

    private static func kablo(_ m: TelsizMesaj) -> Data? {
        let k = TelsizKablo(v: 1, id: m.id, kanal: m.kanal, t: m.olusturulduMs, atlama: m.atlama, sure: m.sureMs, mime: m.mime, veri: m.veri)
        return try? JSONEncoder().encode(k)
    }

    /// `kime` verilirse yalnız o iPhone'lara (MultipeerConnectivity); verilmezse bütün iPhone'lara ve Android'lere (BLE).
    private func gonder(_ m: TelsizMesaj, haric: TelsizKaynak? = nil, kime: [MCPeerID]? = nil) {
        guard let veri = Self.kablo(m) else { return }
        if let s = oturum {
            let hedef = (kime ?? s.connectedPeers).filter { haric != .mpc($0) }
            if !hedef.isEmpty { try? s.send(veri, toPeers: hedef, with: .reliable) }
        }
        if kime == nil {
            var haricBle: String?
            if case .ble(let b) = haric { haricBle = b }
            ble.gonder(veri, haric: haricBle)
            var haricEk: String?
            if case .ek(let e) = haric { haricEk = e }
            ek?.gonder(veri, haric: haricEk)
        }
    }

    /// Android yeni bağlandı: Bluetooth yavaştır → metinlerin hepsi + en yeni 3 ses (≤30) + süren duyurular.
    private func bleYeniBaglanti(_ id: String) {
        // 2026-11-09: kendi varlığımız (yanıt isteğiyle) ve yardım çağrıları
        // EN ÖNCE gider — önceden 30 iletilik geçmişin (3 ses ≈ yüzlerce KB) ARDINDAN gidiyordu, Bluetooth'ta onlarca saniye gecikiyordu.
        for v in agGecmisi() { ble.gonderKime(id, v) }
        let simdi = Int64(Date().timeIntervalSince1970 * 1000)
        let uygun = tumu.values.filter { simdi - $0.olusturulduMs < Self.omurMs && $0.atlama < Self.maksAtlama }
            .sorted { $0.olusturulduMs > $1.olusturulduMs }
        var ses = 0, n = 0
        for m in uygun {
            if m.mime != Self.metinMime {
                if ses >= Self.bleGecmisSes { continue }
                ses += 1
            }
            if let v = Self.kablo(m) { ble.gonderKime(id, v) }
            n += 1
            if n >= 30 { break }
        }
        for d in duyurular.values where simdi - d.t < Self.duyuruOmurMs && d.atlama < Self.maksAtlama {
            if let v = try? JSONEncoder().encode(d) { ble.gonderKime(id, v) }
        }
    }

    private struct SurumBakisi: Decodable { let v: Int? }

    private func al(_ veri: Data, kimden: TelsizKaynak) {
        // 2026-11-09: v3 ağ iletileri (varlık, davet, yardım) önce ayrılır; eski biçimler aşağıda aynen.
        if let s = try? JSONDecoder().decode(SurumBakisi.self, from: veri), s.v == TelsizAg.surum {
            if let a = try? JSONDecoder().decode(TelsizAgKablo.self, from: veri) { agAl(a, kimden: kimden) }
            return
        }
        if let d = try? JSONDecoder().decode(DuyuruKablo.self, from: veri), d.v == 2, d.tur == "duyuru" {
            duyuruAl(d, kimden: kimden)
            return
        }
        guard let k = try? JSONDecoder().decode(TelsizKablo.self, from: veri), k.v == 1 else { return }
        let simdi = Int64(Date().timeIntervalSince1970 * 1000)
        guard simdi - k.t < Self.omurMs, k.t <= simdi + 5 * 60_000, k.atlama >= 0, k.atlama < Self.maksAtlama + 1,
              k.id.count >= 8, k.id.count <= 64, k.id.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }),
              !k.kanal.isEmpty, k.kanal.count <= 64 else { return }
        DispatchQueue.main.async {
            if self.tumu[k.id] != nil { return }
            let m = TelsizMesaj(id: k.id, kanal: k.kanal, olusturulduMs: k.t, atlama: k.atlama + 1, sureMs: k.sure, mime: k.mime, veri: k.veri, alindiMs: simdi, kendim: false, yuklendi: false)
            self.tumu[m.id] = m
            self.diskeYaz(m)
            self.yayinla()
            if m.atlama < Self.maksAtlama && self.pilYeterli() {
                self.gonder(m, haric: kimden)
            }
            if m.kanal == self.kanal {
                if self.arkaPlan && UIApplication.shared.applicationState == .background {
                    if self.telsizKullanildi { self.arkaPlanBildir(m) }
                } else if m.mime == Self.metinMime {
                    UINotificationFeedbackGenerator().notificationOccurred(.warning)
                } else if self.otomatikCal {
                    self.calKuyrugu.append(m)
                    self.siradakiniCal()
                }
            }
        }
    }

    /// Arka planda (anahtar açık) kanala gelen mesaj: kilit ekranında görünsün diye yerel bildirim. Ses çalınmaz (arka planda
    /// ses modu yok); kullanıcı dokununca telsiz sekmesi açılır ve mesaj listede durur.
    private func arkaPlanBildir(_ m: TelsizMesaj) {
        let c = Self.coz(m)
        let maskeli = TelsizAg.maskele(c?.ad ?? "")
        let ad = maskeli.isEmpty ? TelsizMetin.uygulamaAdi : maskeli
        let icerik = UNMutableNotificationContent()
        icerik.title = TelsizMetin.simdiki().baslik
        if let metin = c?.metin, !metin.isEmpty { icerik.body = "\(ad): \(metin)" } else { icerik.body = "🎙 \(ad)" }
        icerik.sound = .default
        icerik.threadIdentifier = "walkie-talkie"
        icerik.userInfo = ["telsiz": "mesaj", "id": m.id]
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "telsiz-\(m.id)", content: icerik, trigger: nil), withCompletionHandler: nil)
    }

    // MARK: Şifre

    private static func anahtar(_ kanal: String) -> SymmetricKey {
        let ham = SymmetricKey(data: Data("hangel-afet-telsiz-v1".utf8))
        return HKDF<SHA256>.deriveKey(inputKeyMaterial: ham, salt: Data(kanal.utf8), info: Data("kanal-anahtari".utf8), outputByteCount: 32)
    }

    private static func sifrele(ad: String, ses: Data, kanal: String) -> String? {
        sifrele(TelsizIcerik(ad: ad, ses: ses.base64EncodedString()), kanal: kanal)
    }

    private static func sifrele(_ ic: TelsizIcerik, kanal: String) -> String? {
        guard let d = try? JSONEncoder().encode(ic), let kutu = try? ChaChaPoly.seal(d, using: anahtar(kanal)) else { return nil }
        return kutu.combined.base64EncodedString()
    }

    static func coz(_ m: TelsizMesaj) -> TelsizCozum? {
        guard let d = Data(base64Encoded: m.veri), let kutu = try? ChaChaPoly.SealedBox(combined: d),
              let acik = try? ChaChaPoly.open(kutu, using: anahtar(m.kanal)),
              let ic = try? JSONDecoder().decode(TelsizIcerik.self, from: acik) else { return nil }
        let ses = ic.ses.isEmpty ? nil : Data(base64Encoded: ic.ses)
        var enlem: Double?, boylam: Double?
        if let a = ic.enlem, let b = ic.boylam, abs(a) <= 90, abs(b) <= 180 { enlem = a; boylam = b }
        var durum: String?, kisi: String?
        // 2026-11-09: kişi kodu artık her iletide (durumdan bağımsız); durum yine yalnız geçerli kişi koduyla sayılır.
        if let k = ic.kisi, Self.kisiGecerli(k) { kisi = k }
        if let d = ic.durum, Self.durumlar.contains(d), kisi != nil { durum = d }
        let konumMs = enlem == nil ? nil : ic.konumMs
        return TelsizCozum(ad: ic.ad, ses: ses, metin: ic.metin, enlem: enlem, boylam: boylam, durum: durum, kisi: kisi, konumMs: konumMs)
    }

    func gorunenAd(_ m: TelsizMesaj) -> String {
        Self.coz(m)?.ad ?? ""
    }

    // MARK: Kayıt / çalma

    func kayitBaslat() {
        guard !kayitta else { return }
        basiliIstek = true
        let ses = AVAudioSession.sharedInstance()
        ses.requestRecordPermission { [weak self] izin in
            DispatchQueue.main.async {
                guard let self else { return }
                guard izin else { self.bilgi = TelsizMetin.simdiki().mikrofonIzni; return }
                guard self.basiliIstek, !self.kayitta else { return }
                do {
                    try ses.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .allowBluetooth])
                    try ses.setActive(true)
                    let url = FileManager.default.temporaryDirectory.appendingPathComponent("telsiz-\(UUID().uuidString).m4a")
                    let ayar: [String: Any] = [
                        AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
                        AVSampleRateKey: 16_000,
                        AVNumberOfChannelsKey: 1,
                        AVEncoderBitRateKey: 32_000,
                        AVEncoderAudioQualityKey: AVAudioQuality.medium.rawValue,
                    ]
                    let r = try AVAudioRecorder(url: url, settings: ayar)
                    r.delegate = self
                    r.record(forDuration: Self.maksSureSn)
                    self.kayitci = r
                    self.kayitBaslangic = Date()
                    self.kayitta = true
                    UIImpactFeedbackGenerator(style: .heavy).impactOccurred()
                    if !self.basiliIstek { r.stop() }
                } catch {
                    self.kayitta = false
                }
            }
        }
    }

    func kayitBitir() {
        basiliIstek = false
        guard kayitta, let r = kayitci else { return }
        r.stop() // audioRecorderDidFinishRecording → gonderKayit
    }

    fileprivate func kayitTamam(_ url: URL) {
        let sure = Date().timeIntervalSince(kayitBaslangic ?? Date())
        kayitci = nil
        kayitta = false
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        defer { try? FileManager.default.removeItem(at: url) }
        guard sure >= 0.5, let ses = try? Data(contentsOf: url), !ses.isEmpty else { return }
        let k = kanal
        let sureMs = Int(min(sure, Self.maksSureSn) * 1000)
        // 2026-11-09: konum her iletide (≤2 dk taze ya da en çok 4 sn'lik tek seferlik istek; yoksa konumsuz).
        TelsizKonum.shared.gonderimKonumu(bekleSn: 4) { [weak self] konum in
            guard let self else { return }
            var ic = TelsizIcerik(ad: "", ses: ses.base64EncodedString())
            self.gidenIcerik(&ic, konum: konum)
            guard let veri = Self.sifrele(ic, kanal: k) else { return }
            self.kendiMesajim(mime: "audio/mp4", sureMs: sureMs, veri: veri, kanal: k)
            self.bilgi = TelsizMetin.simdiki().gonderildi
        }
    }

    /// Giden her iletiye: maskeli ad, kişi kodu ve (varsa) konum + konum zamanı (~1 m'ye yuvarlı).
    fileprivate func gidenIcerik(_ ic: inout TelsizIcerik, konum: CLLocation?) {
        ic.ad = TelsizAg.maskele(gonderenTamAd())
        ic.kisi = Self.kisiKodu()
        if let k = konum {
            ic.enlem = (k.coordinate.latitude * 1e5).rounded() / 1e5
            ic.boylam = (k.coordinate.longitude * 1e5).rounded() / 1e5
            ic.konumMs = Int64(k.timestamp.timeIntervalSince1970 * 1000)
        }
    }

    /// Motorun adı (sayfa verdiyse) yoksa kayıtlı ad (çevrimiçiyken `adAyarla` ile yazılan).
    fileprivate func gonderenTamAd() -> String {
        ad.isEmpty ? (UserDefaults.standard.string(forKey: "walkieTalkieAd") ?? "") : ad
    }

    private func kendiMesajim(mime: String, sureMs: Int, veri: String, kanal k: String? = nil) {
        let simdi = Int64(Date().timeIntervalSince1970 * 1000)
        let id = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        let m = TelsizMesaj(id: id, kanal: k ?? kanal, olusturulduMs: simdi, atlama: 0, sureMs: sureMs, mime: mime, veri: veri, alindiMs: simdi, kendim: true, yuklendi: false)
        tumu[id] = m
        diskeYaz(m)
        yayinla()
        gonder(m)
    }

    /// Denetim karakterleri atılır, kırpılır, 280 KOD NOKTASINA kısaltılır — src/protocol/frame.ts metinTemizle ve Java ile
    /// BİREBİR (2026-11-08, scripts/cross-verify/capraz-dogrula.sh): önceden grafem sayılıyordu (emoji/aksanla 500+ kod noktası geçiyordu) ve
    /// Foundation'ın boşluk kümesi JS trim()'den farklıydı (U+FEFF kalıyor, U+0085 kırpılıyordu).
    static func metinTemizle(_ m: String) -> String? {
        func bosluk(_ c: Unicode.Scalar) -> Bool {
            c == "\n" || c.value == 0xFEFF || c.value == 0x2028 || c.value == 0x2029 || c.properties.generalCategory == .spaceSeparator
        }
        let s = Array(m.unicodeScalars.filter { $0 == "\n" || $0.value >= 32 })
        var bas = 0, son = s.count
        while bas < son, bosluk(s[bas]) { bas += 1 }
        while son > bas, bosluk(s[son - 1]) { son -= 1 }
        guard bas < son else { return nil }
        var v = String.UnicodeScalarView()
        v.append(contentsOf: s[bas..<min(son, bas + maksMetin)])
        return String(v)
    }

    /// Kısa metin gönderir. 2026-11-09: konum HER ZAMAN eklenir (soru yok; `konumla` geriye uyum için yok sayılır) — ≤2 dk taze konum
    /// ya da en çok 4 sn'lik tek seferlik istek; alınamazsa konumsuz gider.
    func metinGonder(_ metin: String, konumla: Bool) {
        guard let temiz = Self.metinTemizle(metin) else { return }
        let k0 = kanal
        TelsizKonum.shared.gonderimKonumu(bekleSn: 4) { [weak self] k in
            guard let self else { return }
            var ic = TelsizIcerik(ad: "", ses: "")
            ic.metin = temiz
            self.gidenIcerik(&ic, konum: k)
            guard let veri = Self.sifrele(ic, kanal: k0) else { return }
            self.kendiMesajim(mime: Self.metinMime, sureMs: 0, veri: veri, kanal: k0)
            self.bilgi = TelsizMetin.simdiki().gonderildi
        }
    }

    /// Cihaza özgü rastgele kişi kodu (kişi/ad değil; aynı kişinin tekrar basışını sayımda tek saymak için). Kanal şifresi içinde gider.
    private static func kisiKodu() -> String {
        let d = UserDefaults.standard
        if let k = d.string(forKey: "walkieTalkieKisi"), kisiGecerli(k) { return k }
        let k = String(UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased().prefix(12))
        d.set(k, forKey: "walkieTalkieKisi")
        return k
    }

    /// 2026-11-08 (Yakın ağ): "Güvendeyim" / "Toplanma alanındayım" / "Yardım lazım". `metin` web'in kullanıcı dilinde verdiği okunur
    /// cümledir (eski derlemeler bunu düz metin gösterir). Konum yalnız `konumla` ise eklenir. Yalnız web özellik anahtarı açıkken çağrılır.
    func durumGonder(_ durum: String, metin: String, konumla: Bool) {
        guard Self.durumlar.contains(durum), let temiz = Self.metinTemizle(metin) else { return }
        let k0 = kanal
        TelsizKonum.shared.gonderimKonumu(bekleSn: 4) { [weak self] k in
            guard let self else { return }
            var ic = TelsizIcerik(ad: "", ses: "")
            ic.metin = temiz
            ic.durum = durum
            self.gidenIcerik(&ic, konum: k)
            guard let veri = Self.sifrele(ic, kanal: k0) else { return }
            self.kendiMesajim(mime: Self.metinMime, sureMs: 0, veri: veri, kanal: k0)
            self.bilgi = TelsizMetin.simdiki().gonderildi
        }
    }

    /// Geçerli kanalda son 12 saatteki durumlar: her kişi kodunun SON durumu sayılır (guvende / toplanma / yardim).
    func durumOzeti() -> [String: Int] {
        let simdi = Int64(Date().timeIntervalSince1970 * 1000)
        var son: [String: (Int64, String)] = [:]
        for m in tumu.values where m.kanal == kanal && m.mime == Self.metinMime && simdi - m.olusturulduMs < Self.durumOmrMs {
            guard let c = Self.coz(m), let d = c.durum, let k = c.kisi else { continue }
            if let o = son[k], o.0 >= m.olusturulduMs { continue }
            son[k] = (m.olusturulduMs, d)
        }
        var ozet = ["guvende": 0, "toplanma": 0, "yardim": 0]
        for (_, v) in son { ozet[v.1, default: 0] += 1 }
        return ozet
    }

    func cozum(_ m: TelsizMesaj) -> TelsizCozum? { Self.coz(m) }

    func cal(_ m: TelsizMesaj) {
        calKuyrugu.removeAll { $0.id == m.id }
        calici?.stop()
        calici = nil
        calKuyrugu.insert(m, at: 0)
        siradakiniCal()
    }

    private func siradakiniCal() {
        guard calici == nil, !kayitta, !calKuyrugu.isEmpty else { return }
        let m = calKuyrugu.removeFirst()
        guard let c = Self.coz(m), let ses = c.ses else { siradakiniCal(); return }
        do {
            let s = AVAudioSession.sharedInstance()
            try s.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .allowBluetooth])
            try s.setActive(true)
            let p = try AVAudioPlayer(data: ses)
            p.delegate = self
            calici = p
            calanId = m.id
            p.play()
        } catch {
            calici = nil
            calanId = nil
            siradakiniCal()
        }
    }

    // MARK: Kuyruk (web yükler)

    func bekleyenler() -> [[String: Any]] {
        // 2026-11-09: önce yüklenmemiş yardım çağrıları (kanal k0'a kısa metin + `yardim` alanı; sunucu 24 sa saklar).
        var cikti: [[String: Any]] = yardimBekleyenler()
        for m in tumu.values.sorted(by: { $0.olusturulduMs < $1.olusturulduMs }) where !m.yuklendi {
            guard let c = Self.coz(m) else { continue }
            var o: [String: Any] = ["id": m.id, "kanal": m.kanal, "ad": c.ad, "olusturulduMs": m.olusturulduMs, "atlama": m.atlama,
                                    "sureMs": m.sureMs, "mime": m.mime, "kendim": m.kendim, "sesBase64": c.ses?.base64EncodedString() ?? ""]
            if let t = c.metin { o["metin"] = t }
            if let a = c.enlem, let b = c.boylam { o["enlem"] = a; o["boylam"] = b }
            cikti.append(o)
            if cikti.count >= 20 { break }
        }
        return cikti
    }

    func yuklendiIsaretle(_ idler: [String]) {
        for id in idler {
            if var y = yardimlar[id] {
                y.yuklendi = true
                yardimlar[id] = y
                yardimDiskeYaz(y)
                continue
            }
            guard var m = tumu[id] else { continue }
            m.yuklendi = true
            tumu[id] = m
            diskeYaz(m)
        }
    }

    // MARK: Disk

    private var klasor: URL {
        let u = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("walkie-talkie", isDirectory: true)
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true, attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
        return u
    }

    private func diskeYaz(_ m: TelsizMesaj) {
        guard let d = try? JSONEncoder().encode(m) else { return }
        try? d.write(to: klasor.appendingPathComponent("\(m.id).json"), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    private func diskYukle() {
        let simdi = Int64(Date().timeIntervalSince1970 * 1000)
        let fm = FileManager.default
        guard let dosyalar = try? fm.contentsOfDirectory(at: klasor, includingPropertiesForKeys: nil) else { return }
        for u in dosyalar where u.pathExtension == "json" {
            guard let d = try? Data(contentsOf: u), let m = try? JSONDecoder().decode(TelsizMesaj.self, from: d) else { continue }
            if simdi - m.olusturulduMs > Self.omurMs { try? fm.removeItem(at: u); continue }
            tumu[m.id] = m
        }
    }

    private func yayinla() {
        budaGerekirse()
        let k = kanal
        let liste = tumu.values.filter { $0.kanal == k }.sorted { $0.olusturulduMs > $1.olusturulduMs }
        DispatchQueue.main.async { self.mesajlar = Array(liste.prefix(50)) }
    }

    /// En çok 10 dk'da bir: ömrü (72 sa) dolan mesajlar ve süresi (3 sa) geçen duyurular bellekten ve diskten atılır. Yeniden gelirlerse
    /// `al` yaşları yüzünden zaten reddeder (döngü olmaz).
    private func budaGerekirse() {
        let simdi = Int64(Date().timeIntervalSince1970 * 1000)
        guard simdi - sonBudamaMs > 10 * 60_000 else { return }
        sonBudamaMs = simdi
        for (id, m) in tumu where simdi - m.olusturulduMs >= Self.omurMs {
            tumu.removeValue(forKey: id)
            try? FileManager.default.removeItem(at: klasor.appendingPathComponent("\(id).json"))
        }
        duyurular = duyurular.filter { simdi - $0.value.t < Self.duyuruOmurMs }
        yardimBuda(simdi)
    }

    fileprivate func yeniBaglanana(_ p: MCPeerID) {
        if let s = oturum { for v in agGecmisi() { try? s.send(v, toPeers: [p], with: .reliable) } } // önce varlık + yardım
        let simdi = Int64(Date().timeIntervalSince1970 * 1000)
        let son = tumu.values.filter { simdi - $0.olusturulduMs < Self.omurMs && $0.atlama < Self.maksAtlama }
            .sorted { $0.olusturulduMs > $1.olusturulduMs }.prefix(30)
        for m in son { gonder(m, kime: [p]) }
        for d in duyurular.values where simdi - d.t < Self.duyuruOmurMs && d.atlama < Self.maksAtlama {
            duyuruGonder(d, kime: [p])
        }
    }

    // MARK: Etkinlik duyurusu (2026-11-04)

    /// Yöneticinin yazdığı duyuruyu yakındaki açık uyumlu uygulamalara yayar. Bağlı kimse yoksa yeni bağlanana iletilir.
    func duyuruYay(etkinlikId: String, baslik: String, metin: String) {
        let temiz = String(metin.trimmingCharacters(in: .whitespacesAndNewlines).prefix(140))
        guard !temiz.isEmpty else { return }
        baslat()
        let d = DuyuruKablo(v: 2, tur: "duyuru", id: UUID().uuidString, t: Int64(Date().timeIntervalSince1970 * 1000),
                            atlama: 0, etkinlikId: etkinlikId, baslik: String(baslik.prefix(80)), metin: temiz)
        duyurular[d.id] = d
        duyuruGonder(d)
    }

    private func duyuruGonder(_ d: DuyuruKablo, haric: TelsizKaynak? = nil, kime: [MCPeerID]? = nil) {
        guard let veri = try? JSONEncoder().encode(d) else { return }
        if let s = oturum {
            let hedef = (kime ?? s.connectedPeers).filter { haric != .mpc($0) }
            if !hedef.isEmpty { try? s.send(veri, toPeers: hedef, with: .reliable) }
        }
        if kime == nil {
            var haricBle: String?
            if case .ble(let b) = haric { haricBle = b }
            ble.gonder(veri, haric: haricBle)
            var haricEk: String?
            if case .ek(let e) = haric { haricEk = e }
            ek?.gonder(veri, haric: haricEk)
        }
    }

    private func duyuruAl(_ d: DuyuruKablo, kimden: TelsizKaynak) {
        let simdi = Int64(Date().timeIntervalSince1970 * 1000)
        guard simdi - d.t < Self.duyuruOmurMs, d.atlama < Self.maksAtlama + 1 else { return }
        DispatchQueue.main.async {
            if self.duyurular[d.id] != nil { return }
            let yeni = DuyuruKablo(v: 2, tur: "duyuru", id: d.id, t: d.t, atlama: d.atlama + 1,
                                   etkinlikId: d.etkinlikId, baslik: d.baslik, metin: d.metin)
            self.duyurular[yeni.id] = yeni
            if yeni.atlama < Self.maksAtlama && self.pilYeterli() { self.duyuruGonder(yeni, haric: kimden) }
            let icerik = UNMutableNotificationContent()
            icerik.title = yeni.baslik.isEmpty ? TelsizMetin.uygulamaAdi : "📣 \(yeni.baslik)"
            icerik.body = yeni.metin
            icerik.sound = .default
            icerik.userInfo = ["telsiz": "duyuru", "id": yeni.etkinlikId]
            let istek = UNNotificationRequest(identifier: "duyuru-\(yeni.id)", content: icerik, trigger: nil)
            UNUserNotificationCenter.current().add(istek, withCompletionHandler: nil)
        }
    }
}

extension TelsizMotoru: MCSessionDelegate {
    func session(_ session: MCSession, peer peerID: MCPeerID, didChange state: MCSessionState) {
        DispatchQueue.main.async {
            guard session === self.oturum else { return }
            self.mpcBaglilar = session.connectedPeers.map { $0.displayName }
            self.bagliGuncelle()
            if state == .connecting { self.baglaniyor.insert(peerID) } else { self.baglaniyor.remove(peerID) }
            if state == .connected {
                self.davetDenemesi[peerID] = nil
                self.yeniBaglanana(peerID)
            } else if state == .notConnected, self.bulunanlar.contains(peerID) {
                // Koptu ya da davet zaman aşımı: telefon hâlâ görünüyorsa artan beklemeyle (3, 6 … en çok 30 sn) yeniden davet.
                let n = (self.davetDenemesi[peerID] ?? 0) + 1
                self.davetDenemesi[peerID] = n
                DispatchQueue.main.asyncAfter(deadline: .now() + Double(min(30, 3 * n))) { [weak self] in self?.davetEt(peerID) }
            }
        }
    }
    func session(_ session: MCSession, didReceive data: Data, fromPeer peerID: MCPeerID) { al(data, kimden: .mpc(peerID)) }
    func session(_ session: MCSession, didReceive stream: InputStream, withName streamName: String, fromPeer peerID: MCPeerID) {}
    func session(_ session: MCSession, didStartReceivingResourceWithName resourceName: String, fromPeer peerID: MCPeerID, with progress: Progress) {}
    func session(_ session: MCSession, didFinishReceivingResourceWithName resourceName: String, fromPeer peerID: MCPeerID, at localURL: URL?, withError error: Error?) {}
}

extension TelsizMotoru: MCNearbyServiceAdvertiserDelegate {
    func advertiser(_ advertiser: MCNearbyServiceAdvertiser, didReceiveInvitationFromPeer peerID: MCPeerID, withContext context: Data?, invitationHandler: @escaping (Bool, MCSession?) -> Void) {
        DispatchQueue.main.async {
            guard let s = self.oturum, advertiser === self.yayinci else { invitationHandler(false, nil); return }
            // MultipeerConnectivity oturumu en çok 8 cihaz: 7 bağlantıyı aşma, kalan yer ağın diğer kollarına.
            invitationHandler(s.connectedPeers.count < 7, s)
        }
    }
}

extension TelsizMotoru: MCNearbyServiceBrowserDelegate {
    // Tarayıcı geri çağrıları MultipeerConnectivity'nin kendi kuyruğunda gelir; oturum ve küme ana iş parçacığında değişir → oraya geçilir.
    func browser(_ browser: MCNearbyServiceBrowser, foundPeer peerID: MCPeerID, withDiscoveryInfo info: [String: String]?) {
        DispatchQueue.main.async {
            guard browser === self.arayici else { return }
            self.bulunanlar.insert(peerID)
            self.davetEt(peerID)
        }
    }
    func browser(_ browser: MCNearbyServiceBrowser, lostPeer peerID: MCPeerID) {
        DispatchQueue.main.async {
            self.bulunanlar.remove(peerID)
            self.davetDenemesi[peerID] = nil
            self.baglaniyor.remove(peerID)
        }
    }
}

extension TelsizMotoru: AVAudioRecorderDelegate, AVAudioPlayerDelegate {
    func audioRecorderDidFinishRecording(_ recorder: AVAudioRecorder, successfully flag: Bool) {
        let url = recorder.url
        DispatchQueue.main.async { self.kayitTamam(url) }
    }
    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        DispatchQueue.main.async {
            self.calici = nil
            self.calanId = nil
            self.siradakiniCal()
        }
    }
}

// MARK: - Ekran

struct TelsizEkrani: View {
    @ObservedObject var motor = TelsizMotoru.shared
    var kapat: () -> Void
    @State private var basili = false
    @State private var metin = ""
    @FocusState private var metinOdak: Bool
    private let m = TelsizMetin.simdiki()
    private let nar = Color(red: 0.953, green: 0.278, blue: 0.137)

    var body: some View {
        VStack(spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(m.baslik).font(.title2.weight(.black))
                    Text(motor.kanalAdi.isEmpty ? motor.kanal : motor.kanalAdi).font(.subheadline).foregroundColor(.secondary)
                }
                Spacer()
                Button(m.kapat, action: kapat).font(.body.weight(.semibold))
            }
            HStack(spacing: 8) {
                Label(motor.internetVar ? m.cevrimici : m.internetsiz, systemImage: motor.internetVar ? "wifi" : "wifi.slash")
                    .font(.footnote.weight(.semibold))
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .background(Capsule().fill(Color.secondary.opacity(0.15)))
                Label("\(motor.dogrudanCihazSayisi()) \(m.bagliTelefon)", systemImage: "antenna.radiowaves.left.and.right")
                    .font(.footnote.weight(.semibold))
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .background(Capsule().fill(motor.baglilar.isEmpty ? Color.secondary.opacity(0.15) : Color.green.opacity(0.18)))
                Spacer()
            }
            .accessibilityElement(children: .combine)

            ZStack {
                Circle().fill(motor.kayitta ? nar.opacity(0.85) : nar)
                    .frame(width: 180, height: 180)
                    .scaleEffect(motor.kayitta ? 1.06 : 1)
                    .shadow(radius: motor.kayitta ? 12 : 6)
                Image(systemName: "mic.fill").font(.system(size: 64, weight: .bold)).foregroundColor(.white)
            }
            .padding(.top, 8)
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in if !basili { basili = true; motor.kayitBaslat() } }
                    .onEnded { _ in basili = false; motor.kayitBitir() }
            )
            .accessibilityElement()
            .accessibilityLabel(motor.kayitta ? m.kaydediliyor : m.basKonus)
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { if motor.kayitta { motor.kayitBitir() } else { motor.kayitBaslat() } }

            Text(motor.kayitta ? m.kaydediliyor : (motor.bilgi ?? m.basKonus))
                .font(.headline)
                .multilineTextAlignment(.center)

            // 2026-11-05: kısa metin + isteğe bağlı konum (Android'le aynı mesaj)
            HStack(spacing: 8) {
                TextField(m.metinIpucu, text: $metin)
                    .textFieldStyle(.roundedBorder)
                    .submitLabel(.send)
                    .focused($metinOdak)
                    .onSubmit(metniGonder)
                    .onChange(of: metin) { y in
                        if y.unicodeScalars.count > TelsizMotoru.maksMetin {
                            var v = String.UnicodeScalarView()
                            v.append(contentsOf: y.unicodeScalars.prefix(TelsizMotoru.maksMetin))
                            metin = String(v)
                        }
                    }
                Button(m.gonder, action: metniGonder)
                    .font(.body.weight(.semibold))
                    .disabled(TelsizMotoru.metinTemizle(metin) == nil)
            }
            // 2026-11-09: "Konumumu ekle" sorusu kalktı — konum her iletide.

            if motor.mesajlar.isEmpty {
                Text(m.mesajYok).font(.footnote).foregroundColor(.secondary).multilineTextAlignment(.center).padding(.top, 8)
                Spacer()
            } else {
                List(motor.mesajlar) { x in
                    satir(x)
                }
                .listStyle(.plain)
            }

            if motor.testPaneli {
                VStack(alignment: .leading, spacing: 4) {
                    Text(m.testPaneli).font(.caption.weight(.bold))
                    Text("peer: \(motor.baglilar.joined(separator: ", "))").font(.caption2.monospaced())
                    if let s = motor.mesajlar.first(where: { !$0.kendim }) {
                        Text("son: \(s.atlama) \(m.aktarim) · \(m.teslim) \(String(format: "%.1f", Double(max(0, s.alindiMs - s.olusturulduMs)) / 1000)) s").font(.caption2.monospaced())
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 12).stroke(style: StrokeStyle(lineWidth: 1, dash: [4])).foregroundColor(.secondary))
            }

            Text(m.ekranAcik).font(.caption2).foregroundColor(.secondary).multilineTextAlignment(.center)
        }
        .padding()
        .onAppear {
            UIApplication.shared.isIdleTimerDisabled = true
            motor.baslat()
        }
        .onDisappear {
            UIApplication.shared.isIdleTimerDisabled = false
        }
    }

    private func altSatir(_ x: TelsizMesaj) -> String {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .short
        let zaman = f.localizedString(for: Date(timeIntervalSince1970: Double(x.olusturulduMs) / 1000), relativeTo: Date())
        let sn = x.mime == TelsizMotoru.metinMime ? "" : " · \(max(1, x.sureMs / 1000)) s"
        return x.kendim ? "\(zaman)\(sn)" : "\(zaman)\(sn) · \(x.atlama) \(m.aktarim)"
    }

    private func metniGonder() {
        guard TelsizMotoru.metinTemizle(metin) != nil else { return }
        let t = metin
        metin = ""
        metinOdak = false
        motor.metinGonder(t, konumla: true)
    }

    @ViewBuilder
    private func satir(_ x: TelsizMesaj) -> some View {
        let c = motor.cozum(x)
        let maskeli = TelsizAg.maskele(c?.ad ?? "")
        let ad = x.kendim ? m.sen : (maskeli.isEmpty ? TelsizMetin.uygulamaAdi : maskeli)
        if x.mime == TelsizMotoru.metinMime {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "envelope.fill").font(.title2).foregroundColor(nar).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text(ad).font(.body.weight(.semibold))
                    if let t = c?.metin { Text(t).font(.body).textSelection(.enabled) }
                    if let a = c?.enlem, let b = c?.boylam {
                        let k = String(format: "%.5f, %.5f", a, b)
                        Button(action: {
                            if let u = URL(string: "maps://?ll=\(a),\(b)&q=\(a),\(b)") { UIApplication.shared.open(u) }
                        }) {
                            Label("\(m.konum): \(k)", systemImage: "mappin.and.ellipse").font(.footnote.weight(.semibold))
                        }
                        .buttonStyle(.borderless)
                        .foregroundColor(nar)
                    }
                    Text(altSatir(x)).font(.caption).foregroundColor(.secondary)
                }
            }
            .accessibilityElement(children: .combine)
        } else {
            Button(action: { motor.cal(x) }) {
                HStack(spacing: 12) {
                    Image(systemName: motor.calanId == x.id ? "speaker.wave.2.fill" : "play.circle.fill").font(.title2).foregroundColor(nar)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(ad).font(.body.weight(.semibold))
                        Text(altSatir(x)).font(.caption).foregroundColor(.secondary)
                    }
                }
            }
            .accessibilityHint(altSatir(x))
        }
    }
}

// MARK: - Bluetooth LE (Android ↔ iPhone; 2026-11-08: iPhone ↔ iPhone da)

/// Çerçeveleme — src/protocol/frame.ts ile aynı: [0] sürüm(1) · [1..4] sıra (BE) · [5..6] parça (BE) · [7..8] sayı (BE) · [9..] dilim.
enum TelsizCerceve {
    static let surum: UInt8 = 1
    static let baslik = 9
    static let maksYuk = 262_144

    static func cercevele(_ yuk: Data, sira: UInt32, parcaBoyutu: Int) -> [Data] {
        let dilim = parcaBoyutu - baslik
        guard !yuk.isEmpty, yuk.count <= maksYuk, dilim >= 1 else { return [] }
        let sayi = (yuk.count + dilim - 1) / dilim
        guard sayi <= 0xffff else { return [] }
        let b = [UInt8](yuk)
        var cikti: [Data] = []
        cikti.reserveCapacity(sayi)
        for i in 0..<sayi {
            var c: [UInt8] = [surum, UInt8(sira >> 24 & 0xff), UInt8(sira >> 16 & 0xff), UInt8(sira >> 8 & 0xff), UInt8(sira & 0xff),
                              UInt8(i >> 8 & 0xff), UInt8(i & 0xff), UInt8(sayi >> 8 & 0xff), UInt8(sayi & 0xff)]
            c.append(contentsOf: b[(i * dilim)..<min(b.count, (i + 1) * dilim)])
            cikti.append(Data(c))
        }
        return cikti
    }
}

/// Bağlantı başına birleştirici (sırasız parça, yineleme, 60 sn zaman aşımı, en çok 4 yarım mesaj).
final class TelsizBirlestirici {
    private struct Yarim { var parcalar: [Data?]; var gelen = 0; var bayt = 0; let ilk: Date }
    private var yarim: [UInt32: Yarim] = [:]

    func ekle(_ c: Data) -> Data? {
        let b = [UInt8](c)
        guard b.count > TelsizCerceve.baslik, b[0] == TelsizCerceve.surum else { return nil }
        let sira = UInt32(b[1]) << 24 | UInt32(b[2]) << 16 | UInt32(b[3]) << 8 | UInt32(b[4])
        let parca = Int(b[5]) << 8 | Int(b[6])
        let sayi = Int(b[7]) << 8 | Int(b[8])
        guard sayi >= 1, parca < sayi else { return nil }
        let simdi = Date()
        yarim = yarim.filter { simdi.timeIntervalSince($0.value.ilk) <= 60 }
        if yarim[sira] == nil {
            if yarim.count >= 4, let eski = yarim.min(by: { $0.value.ilk < $1.value.ilk })?.key { yarim.removeValue(forKey: eski) }
            yarim[sira] = Yarim(parcalar: Array(repeating: nil, count: sayi), ilk: simdi)
        }
        guard var y = yarim[sira], y.parcalar.count == sayi else { yarim.removeValue(forKey: sira); return nil }
        guard y.parcalar[parca] == nil else { return nil }
        let dilim = Data(b[TelsizCerceve.baslik...])
        y.parcalar[parca] = dilim
        y.gelen += 1
        y.bayt += dilim.count
        guard y.bayt <= TelsizCerceve.maksYuk else { yarim.removeValue(forKey: sira); return nil }
        guard y.gelen == sayi else { yarim[sira] = y; return nil }
        yarim.removeValue(forKey: sira)
        var tum = Data(capacity: y.bayt)
        for p in y.parcalar { if let p { tum.append(p) } }
        return tum
    }
}

/// iPhone ÇEVRE BİRİMİDİR: telsiz hizmetini yayınlar, Android merkezler bağlanır (Android → RX'e yazar, iPhone → TX'ten bildirir).
/// 2026-11-08 (2.0.7, saha testi "internetle çalışıyor, Bluetooth'la çalışmıyor"): iPhone ayrıca MERKEZDİR — yakındaki
/// iPhone'ların telsiz yayınına kendisi bağlanır. Neden: iPhone ↔ iPhone yalnız MultipeerConnectivity'yle konuşuyordu; o iOS 11'den
/// beri Bluetooth DEĞİL eşler arası Wi-Fi kullanır → Wi-Fi kapalıyken (uçak modu + Bluetooth) iki iPhone hiç buluşamıyordu.
/// Kim bağlanır: reklam adı "h" (eski iPhone, yalnız çevre birimi) → biz bağlanırız; "h" + 6 onaltılık jeton (yeni iPhone) →
/// jetonu küçük olan bağlanır (çift bağlantı olmasın); adsız yayın (Android ya da arka plandaki iPhone) → bağlanmayız, Android
/// bize kendisi bağlanır. Aynı mesaj iki yoldan gelse de motor kimlikle tekilleştirir.
/// Bluetooth izni bu sınıf ilk kez başladığında (telsiz ekranı açılınca) sorulur.
final class TelsizBLE: NSObject, CBPeripheralManagerDelegate, CBCentralManagerDelegate, CBPeripheralDelegate {
    static let servis = CBUUID(string: "7A1E0001-4A6E-4C2B-9F3D-68616E67656C")
    static let rx = CBUUID(string: "7A1E0002-4A6E-4C2B-9F3D-68616E67656C")
    static let tx = CBUUID(string: "7A1E0003-4A6E-4C2B-9F3D-68616E67656C")
    private static let maksKuyrukBayt = 3 * 1024 * 1024
    /// Bu açılışın jetonu (6 onaltılık) — reklam adı "h" + jeton; iki yeni iPhone'dan küçük olan bağlanır.
    static let jeton = String(format: "%06x", UInt32.random(in: 0...0xffffff))
    private static let maksCevre = 5
    /// 2026-11-09: 10 → 4 sn (kopan telefon kısa sürede yeniden denensin).
    private static let yenidenDenemeSn: TimeInterval = 4
    private static let baglanmaZamanAsimiSn: TimeInterval = 15
    /// Beklenmedik kopuştan sonra aynı telefona bekleyen bağlanma isteği bu kadar açık kalır (iOS isteği arka planda da sürdürür;
    /// telefon menzile dönünce kendiliğinden bağlanır). Sonra tarama yoluna dönülür (adres değişmiş olabilir).
    private static let yenidenBaglanmaSn: TimeInterval = 90

    var yukAlindi: ((String, Data) -> Void)?
    var yeniBaglanti: ((String) -> Void)?
    var baglantilarDegisti: (([String]) -> Void)?

    private final class Baglanti {
        let merkez: CBCentral
        var kuyruk: [Data] = []
        var kuyrukBayt = 0
        var sira = UInt32.random(in: 0...UInt32.max)
        var birlestirici = TelsizBirlestirici()
        init(_ m: CBCentral) { merkez = m }
    }

    /// Bizim merkez olarak bağlandığımız iPhone (çevre birimi). Biz RX'e yanıtsız yazarız, o TX'ten bildirir.
    private final class Cevre {
        let cihaz: CBPeripheral
        var rx: CBCharacteristic?
        var hazir = false
        var kuyruk: [Data] = []
        var kuyrukBayt = 0
        var sira = UInt32.random(in: 0...UInt32.max)
        let birlestirici = TelsizBirlestirici()
        init(_ p: CBPeripheral) { cihaz = p }
    }

    private var yonetici: CBPeripheralManager?
    private var txOzellik: CBMutableCharacteristic?
    private var hizmetHazir = false
    private var calisiyor = false
    private var baglantilar: [UUID: Baglanti] = [:]
    /// Abone olmadan önce yazmaya başlayan merkezler.
    private var yazanlar: [UUID: TelsizBirlestirici] = [:]
    private var merkezYonetici: CBCentralManager?
    private var cevreler: [UUID: Cevre] = [:]
    private var sonDeneme: [UUID: Date] = [:]
    /// willRestoreState ile geri gelen, güç açılınca hazırlanacak çevre birimleri.
    private var geriYuklenen: Set<UUID> = []
    /// Ön planda yinelemeli tarama yalnız telsiz açıkken (TAM kip); arayüzsüz kipte false.
    private var yinelemeli = false

    /// Telsiz ekranı açıldı: yinelemeli taramaya geç.
    func tamKip() {
        guard !yinelemeli else { return }
        yinelemeli = true
        taramayiTazele()
    }

    /// Bluetooth radyosu açık mı (web "Bluetooth kapalı" yazsın diye, 2026-11-08). Telsiz henüz başlamadıysa ya da durum
    /// bilinmiyorsa (izin yok, desteklenmiyor) nil.
    var acikMi: Bool? {
        let durumlar = [yonetici?.state, merkezYonetici?.state].compactMap { $0 }
        if durumlar.contains(.poweredOn) { return true }
        if durumlar.contains(.poweredOff) { return false }
        return nil
    }

    /// 2026-11-09 CoreBluetooth DURUM GERİ YÜKLEME: iki yönetici sabit geri yükleme kimlikleriyle kurulur → iOS uygulamayı bellek için
    /// kapattıktan sonra telsiz bağlantısı/aboneliği/taraması için olay gelince uygulamayı ARKA PLANDA yeniden başlatır; AppDelegate
    /// (DisasterWalkieTalkie.acilistaBaslat) didFinishLaunching'de motoru arayüzsüz başlatır ve yöneticiler AYNI kimliklerle yeniden kurulur;
    /// bağlantılar ve abonelikler willRestoreState ile korunur. iOS sınırı: kullanıcı uygulamayı uygulama değiştiriciden kaydırıp
    /// kapatırsa ya da cihaz yeniden başlarsa iOS geri yüklemez — uygulama bir kez açılınca (Bluetooth izni varsa) kendiliğinden başlar.
    static let merkezGeriYuklemeKimligi = "org.hangel.telsiz.merkez"
    static let cevreGeriYuklemeKimligi = "org.hangel.telsiz.cevre"

    /// `gucUyarisi`: Bluetooth kapalıysa iOS'un "Bluetooth'u aç" penceresi — yalnız kullanıcı telsizi açtığında (açılışta/arka planda asla).
    func baslat(gucUyarisi: Bool = true) {
        guard !calisiyor else { return }
        calisiyor = true
        if yonetici == nil {
            yonetici = CBPeripheralManager(delegate: self, queue: .main, options: [CBPeripheralManagerOptionShowPowerAlertKey: gucUyarisi,
                                                                                    CBPeripheralManagerOptionRestoreIdentifierKey: Self.cevreGeriYuklemeKimligi])
        } else {
            kur()
        }
        if merkezYonetici == nil {
            merkezYonetici = CBCentralManager(delegate: self, queue: .main, options: [CBCentralManagerOptionShowPowerAlertKey: false,
                                                                                    CBCentralManagerOptionRestoreIdentifierKey: Self.merkezGeriYuklemeKimligi])
        } else {
            taramayiBaslat()
        }
    }

    // MARK: Durum geri yükleme (iOS uygulamayı arka planda yeniden başlattı)

    /// Çevre birimi: yayınlanmış hizmet ve abone merkezler korunur — hizmet yeniden EKLENMEZ (eklenseydi bağlı merkezlerin tutamaçları
    /// geçersizleşir, bağlantı koptu sayılırdı). Reklam açık değilse güç açılınca yeniden başlatılır.
    func peripheralManager(_ p: CBPeripheralManager, willRestoreState dict: [String: Any]) {
        let hizmetler = (dict[CBPeripheralManagerRestoredStateServicesKey] as? [CBMutableService]) ?? []
        guard let h = hizmetler.first(where: { $0.uuid == Self.servis }),
              let tx = h.characteristics?.compactMap({ $0 as? CBMutableCharacteristic }).first(where: { $0.uuid == Self.tx }) else { return }
        txOzellik = tx
        hizmetHazir = true
        for m in tx.subscribedCentrals ?? [] where baglantilar[m.identifier] == nil {
            baglantilar[m.identifier] = Baglanti(m)
        }
        bildir()
    }

    /// Merkez: bağlı/bağlanmakta olan iPhone'lar geri gelir; güç açılınca (centralManagerDidUpdateState) bildirim aboneliği denetlenir,
    /// gerekirse özellikler yeniden bulunur, kopuksa bekleyen bağlanma isteği verilir.
    func centralManager(_ m: CBCentralManager, willRestoreState dict: [String: Any]) {
        let cihazlar = (dict[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral]) ?? []
        for p in cihazlar.prefix(Self.maksCevre) where cevreler[p.identifier] == nil {
            p.delegate = self
            cevreler[p.identifier] = Cevre(p)
            geriYuklenen.insert(p.identifier)
        }
    }

    /// Geri yüklenen bir çevre birimini kullanıma hazırlar (yalnız güç açıkken).
    private func geriYukleneniHazirla(_ m: CBCentralManager) {
        for id in geriYuklenen {
            guard let c = cevreler[id] else { continue }
            let p = c.cihaz
            switch p.state {
            case .connected:
                if let h = p.services?.first(where: { $0.uuid == Self.servis }),
                   let rx = h.characteristics?.first(where: { $0.uuid == Self.rx }),
                   let tx = h.characteristics?.first(where: { $0.uuid == Self.tx }) {
                    c.rx = rx
                    if tx.isNotifying { c.hazir = true; yeniBaglanti?(p.identifier.uuidString) } else { p.setNotifyValue(true, for: tx) }
                } else {
                    p.discoverServices([Self.servis])
                }
            case .connecting:
                break // didConnect gelecek
            default:
                m.connect(p, options: nil) // bekleyen istek: cihaz menzile dönünce bağlanır
            }
        }
        geriYuklenen.removeAll()
        bildir()
    }

    func durdur() {
        calisiyor = false
        yonetici?.stopAdvertising()
        yonetici?.removeAllServices()
        hizmetHazir = false
        baglantilar.removeAll()
        yazanlar.removeAll()
        if let m = merkezYonetici {
            if m.state == .poweredOn { m.stopScan() }
            for c in cevreler.values { m.cancelPeripheralConnection(c.cihaz) }
        }
        cevreler.removeAll()
        sonDeneme.removeAll()
        geriYuklenen.removeAll()
        bildir()
    }

    private func kur() {
        guard calisiyor, let y = yonetici, y.state == .poweredOn, !hizmetHazir else { return }
        let rx = CBMutableCharacteristic(type: Self.rx, properties: [.write, .writeWithoutResponse], value: nil, permissions: [.writeable])
        let tx = CBMutableCharacteristic(type: Self.tx, properties: [.notify], value: nil, permissions: [.readable])
        let s = CBMutableService(type: Self.servis, primary: true)
        s.characteristics = [rx, tx]
        txOzellik = tx
        y.removeAllServices()
        y.add(s)
    }

    func peripheralManagerDidUpdateState(_ p: CBPeripheralManager) {
        if p.state == .poweredOn {
            if hizmetHazir {
                // Geri yüklenen hizmet: yeniden ekleme yok, yalnız reklam.
                if calisiyor, !p.isAdvertising { reklamiBaslat(p) }
            } else {
                kur()
            }
        } else {
            hizmetHazir = false
            baglantilar.removeAll()
            bildir()
        }
    }

    func peripheralManager(_ p: CBPeripheralManager, didAdd service: CBService, error: Error?) {
        guard error == nil, calisiyor else { return }
        hizmetHazir = true
        reklamiBaslat(p)
    }

    private func reklamiBaslat(_ p: CBPeripheralManager) {
        // Ad kısa tutulur (7 karakter): 128 bit hizmet kimliğiyle birlikte ana reklam paketine (31 bayt) sığar.
        p.startAdvertising([CBAdvertisementDataServiceUUIDsKey: [Self.servis], CBAdvertisementDataLocalNameKey: "h" + Self.jeton])
    }

    func peripheralManager(_ p: CBPeripheralManager, central: CBCentral, didSubscribeTo characteristic: CBCharacteristic) {
        guard characteristic.uuid == Self.tx else { return }
        let b = baglantilar[central.identifier] ?? Baglanti(central)
        if let y = yazanlar.removeValue(forKey: central.identifier) { b.birlestirici = y }
        baglantilar[central.identifier] = b
        bildir()
        yeniBaglanti?(central.identifier.uuidString)
    }

    func peripheralManager(_ p: CBPeripheralManager, central: CBCentral, didUnsubscribeFrom characteristic: CBCharacteristic) {
        baglantilar.removeValue(forKey: central.identifier)
        bildir()
    }

    func peripheralManager(_ p: CBPeripheralManager, didReceiveWrite requests: [CBATTRequest]) {
        for r in requests where r.characteristic.uuid == Self.rx && r.offset == 0 {
            guard let v = r.value, calisiyor else { continue }
            let id = r.central.identifier
            let bir: TelsizBirlestirici
            if let b = baglantilar[id] {
                bir = b.birlestirici
            } else {
                bir = yazanlar[id] ?? TelsizBirlestirici()
                yazanlar[id] = bir
            }
            if let yuk = bir.ekle(v) { yukAlindi?(id.uuidString, yuk) }
        }
        if let ilk = requests.first { p.respond(to: ilk, withResult: .success) }
    }

    func peripheralManagerIsReady(toUpdateSubscribers p: CBPeripheralManager) {
        pompalaMerkezler()
    }

    // MARK: Merkez rolü (iPhone → iPhone, 2.0.7)

    private func taramayiBaslat() {
        guard calisiyor, let m = merkezYonetici, m.state == .poweredOn else { return }
        // Yinelemeler açık: reklam adı tarama yanıtıyla sonradan gelebilir; bağlantı kopunca aynı telefon yeniden bulunur.
        // 2026-11-09: açılıştaki arayüzsüz kipte (yinelemeli = false) pil için yinelemesiz; motor dakikada bir taramayı tazeler.
        m.scanForPeripherals(withServices: [Self.servis], options: [CBCentralManagerScanOptionAllowDuplicatesKey: yinelemeli])
    }

    func centralManagerDidUpdateState(_ m: CBCentralManager) {
        if m.state == .poweredOn {
            if !geriYuklenen.isEmpty { geriYukleneniHazirla(m) }
            taramayiBaslat()
        } else {
            cevreler.removeAll()
            bildir()
        }
    }

    /// Reklam adına göre bağlanılır mı: "h" (eski iPhone) evet; "h" + jeton → jetonu küçük olan bağlanır; adsız (Android) hayır.
    /// 2026-11-08 FAZ 2: arka plandaki iPhone (arka planda dinleme açık) reklam adı göndermez, hizmet kimliği yalnız "taşma" alanında
    /// görünür → `arkaPlandakiIphone` true ise jeton karşılaştırılamaz; ön plandaki iPhone bağlanır. Android hizmet kimliğini ana
    /// pakette yayınlar (taşma alanında değil) → yine bağlanılmaz.
    static func baglanilirMi(reklamAdi: String?, benimJeton: String, arkaPlandakiIphone: Bool = false) -> Bool {
        if reklamAdi == nil && arkaPlandakiIphone { return true }
        guard let ad = reklamAdi, ad.hasPrefix("h") else { return false }
        let karsi = String(ad.dropFirst())
        if karsi.isEmpty { return true }
        guard karsi.count == 6, karsi.allSatisfy({ $0.isHexDigit }) else { return false }
        return benimJeton < karsi
    }

    /// Hizmet kimliği yalnız taşma alanında (ana pakette yok) → arka planda yayın yapan iPhone.
    static func arkaPlandakiIphoneMi(_ veri: [String: Any]) -> Bool {
        let ana = (veri[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID]) ?? []
        let tasma = (veri[CBAdvertisementDataOverflowServiceUUIDsKey] as? [CBUUID]) ?? []
        return !ana.contains(servis) && tasma.contains(servis)
    }

    func centralManager(_ m: CBCentralManager, didDiscover p: CBPeripheral, advertisementData: [String: Any], rssi RSSI: NSNumber) {
        guard calisiyor, cevreler[p.identifier] == nil, cevreler.count < Self.maksCevre,
              baglantilar[p.identifier] == nil, // aynı telefon bize zaten merkez olarak bağlı
              Self.baglanilirMi(reklamAdi: advertisementData[CBAdvertisementDataLocalNameKey] as? String, benimJeton: Self.jeton,
                                arkaPlandakiIphone: Self.arkaPlandakiIphoneMi(advertisementData)) else { return }
        let simdi = Date()
        if let s = sonDeneme[p.identifier], simdi.timeIntervalSince(s) < Self.yenidenDenemeSn { return }
        sonDeneme[p.identifier] = simdi
        let c = Cevre(p)
        cevreler[p.identifier] = c
        p.delegate = self
        m.connect(p, options: nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.baglanmaZamanAsimiSn) { [weak self] in
            guard let self, let simdiki = self.cevreler[p.identifier], simdiki === c, !simdiki.hazir else { return }
            self.cevreler.removeValue(forKey: p.identifier)
            self.merkezYonetici?.cancelPeripheralConnection(p)
            self.bildir()
        }
    }

    func centralManager(_ m: CBCentralManager, didConnect p: CBPeripheral) {
        // Geri yüklenen bekleyen istek bağlandı: cevreler'de kayıtlı (willRestoreState) — aşağıdaki yol aynen işler.
        guard calisiyor, cevreler[p.identifier] != nil else { m.cancelPeripheralConnection(p); return }
        p.discoverServices([Self.servis])
    }

    func centralManager(_ m: CBCentralManager, didFailToConnect p: CBPeripheral, error: Error?) {
        cevreler.removeValue(forKey: p.identifier)
        bildir()
    }

    func centralManager(_ m: CBCentralManager, didDisconnectPeripheral p: CBPeripheral, error: Error?) {
        let oncedenHazir = cevreler[p.identifier]?.hazir == true
        cevreler.removeValue(forKey: p.identifier)
        bildir()
        // 2026-11-09 (teşhis: bağlantı 1–3 dk'da bir kopuyordu): bizim kapatmadığımız kopuşta (error dolu) aynı telefona HEMEN yeniden
        // bağlanma isteği verilir. CoreBluetooth bu isteği zaman aşımsız ve arka planda da sürdürür → telefon menzile döner dönmez bağlanır.
        guard calisiyor, oncedenHazir, error != nil, m.state == .poweredOn, cevreler.count < Self.maksCevre else { return }
        let c = Cevre(p)
        cevreler[p.identifier] = c
        p.delegate = self
        sonDeneme[p.identifier] = Date()
        m.connect(p, options: nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.yenidenBaglanmaSn) { [weak self] in
            guard let self, let simdiki = self.cevreler[p.identifier], simdiki === c, !simdiki.hazir else { return }
            self.cevreler.removeValue(forKey: p.identifier)
            self.merkezYonetici?.cancelPeripheralConnection(p)
            self.bildir()
        }
    }

    /// Taramayı yeniden başlatır: arka planda iOS her telefonu tarama başına bir kez bildirir; yeniden başlatmak listeyi sıfırlar.
    /// Ön plana dönüşte ve AĞ v3 nabzında (dakikada bir) çağrılır.
    func taramayiTazele() {
        guard calisiyor, let m = merkezYonetici, m.state == .poweredOn else { return }
        m.stopScan()
        taramayiBaslat()
    }

    private func cevreyiBirak(_ p: CBPeripheral) {
        cevreler.removeValue(forKey: p.identifier)
        merkezYonetici?.cancelPeripheralConnection(p)
        bildir()
    }

    func peripheral(_ p: CBPeripheral, didDiscoverServices error: Error?) {
        guard error == nil, let s = p.services?.first(where: { $0.uuid == Self.servis }) else { cevreyiBirak(p); return }
        p.discoverCharacteristics([Self.rx, Self.tx], for: s)
    }

    func peripheral(_ p: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard error == nil, let c = cevreler[p.identifier],
              let rx = service.characteristics?.first(where: { $0.uuid == Self.rx }),
              let tx = service.characteristics?.first(where: { $0.uuid == Self.tx }) else { cevreyiBirak(p); return }
        c.rx = rx
        p.setNotifyValue(true, for: tx)
    }

    func peripheral(_ p: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        guard characteristic.uuid == Self.tx, let c = cevreler[p.identifier] else { return }
        guard error == nil, characteristic.isNotifying else { cevreyiBirak(p); return }
        guard !c.hazir else { return }
        c.hazir = true
        bildir()
        yeniBaglanti?(p.identifier.uuidString)
    }

    func peripheral(_ p: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard error == nil, calisiyor, characteristic.uuid == Self.tx, let c = cevreler[p.identifier], let v = characteristic.value else { return }
        if let yuk = c.birlestirici.ekle(v) { yukAlindi?(p.identifier.uuidString, yuk) }
    }

    func peripheralIsReady(toSendWriteWithoutResponse p: CBPeripheral) {
        pompalaCevreler()
    }

    func peripheral(_ p: CBPeripheral, didModifyServices invalidatedServices: [CBService]) {
        if invalidatedServices.contains(where: { $0.uuid == Self.servis }) { cevreyiBirak(p) }
    }

    // MARK: Gönderme (iki rol)

    func gonder(_ yuk: Data, haric: String?) {
        for b in baglantilar.values where b.merkez.identifier.uuidString != haric { kuyrugaEkle(b, yuk) }
        for c in cevreler.values where c.hazir && c.cihaz.identifier.uuidString != haric { cevreKuyrugu(c, yuk) }
        pompala()
    }

    /// `oncelikli`: çerçeveler kuyruğun BAŞINA girer (varlık yanıtı uzun ses geçmişini beklemesin). Alıcı birleştirici her iletiyi kendi
    /// sıra numarasıyla ayrı birleştirir (en çok 4 yarım ileti) → araya giren kısa ileti yarım kalan sesi bozmaz.
    func gonderKime(_ id: String, _ yuk: Data, oncelikli: Bool = false) {
        guard let u = UUID(uuidString: id) else { return }
        if let b = baglantilar[u] {
            kuyrugaEkle(b, yuk, oncelikli: oncelikli)
        } else if let c = cevreler[u], c.hazir {
            cevreKuyrugu(c, yuk, oncelikli: oncelikli)
        } else {
            return
        }
        pompala()
    }

    private func kuyrugaEkle(_ b: Baglanti, _ yuk: Data, oncelikli: Bool = false) {
        guard yuk.count <= TelsizCerceve.maksYuk, b.kuyrukBayt + yuk.count <= Self.maksKuyrukBayt else { return }
        let parca = max(TelsizCerceve.baslik + 1, min(512, b.merkez.maximumUpdateValueLength))
        let cerceveler = TelsizCerceve.cercevele(yuk, sira: b.sira, parcaBoyutu: parca)
        if oncelikli { b.kuyruk.insert(contentsOf: cerceveler, at: 0) } else { b.kuyruk.append(contentsOf: cerceveler) }
        b.kuyrukBayt += cerceveler.reduce(0) { $0 + $1.count }
        b.sira &+= 1
    }

    private func cevreKuyrugu(_ c: Cevre, _ yuk: Data, oncelikli: Bool = false) {
        guard yuk.count <= TelsizCerceve.maksYuk, c.kuyrukBayt + yuk.count <= Self.maksKuyrukBayt else { return }
        let parca = max(TelsizCerceve.baslik + 1, min(512, c.cihaz.maximumWriteValueLength(for: .withoutResponse)))
        let cerceveler = TelsizCerceve.cercevele(yuk, sira: c.sira, parcaBoyutu: parca)
        if oncelikli { c.kuyruk.insert(contentsOf: cerceveler, at: 0) } else { c.kuyruk.append(contentsOf: cerceveler) }
        c.kuyrukBayt += cerceveler.reduce(0) { $0 + $1.count }
        c.sira &+= 1
    }

    private func pompala() {
        pompalaMerkezler()
        pompalaCevreler()
    }

    /// Çevre birimi rolü: bağlantılar arasında sırayla; yığın dolunca (updateValue false) peripheralManagerIsReady'yi bekler.
    private func pompalaMerkezler() {
        guard let y = yonetici, let tx = txOzellik, hizmetHazir else { return }
        var ilerledi = true
        while ilerledi {
            ilerledi = false
            for b in baglantilar.values where !b.kuyruk.isEmpty {
                let c = b.kuyruk[0]
                guard y.updateValue(c, for: tx, onSubscribedCentrals: [b.merkez]) else { return }
                b.kuyruk.removeFirst()
                b.kuyrukBayt -= c.count
                ilerledi = true
            }
        }
    }

    /// Merkez rolü: yanıtsız yazma; yığın dolunca (canSendWriteWithoutResponse false) peripheralIsReady'yi bekler.
    private func pompalaCevreler() {
        for c in cevreler.values where c.hazir {
            guard let rx = c.rx else { continue }
            while !c.kuyruk.isEmpty && c.cihaz.canSendWriteWithoutResponse {
                let f = c.kuyruk.removeFirst()
                c.kuyrukBayt -= f.count
                c.cihaz.writeValue(f, for: rx, type: .withoutResponse)
            }
        }
    }

    /// 2026-11-09: tam kimlikler verilir (motor AĞ v3'te bağlantıyı kişi koduna eşler; görünen ad motorda kısaltılır).
    private func bildir() {
        let adlar = baglantilar.keys.map { $0.uuidString }
            + cevreler.values.filter { $0.hazir }.map { $0.cihaz.identifier.uuidString }
        baglantilarDegisti?(adlar)
    }
}

/// Tek seferlik konum (GPS internetsiz çalışır); 15 sn'de gelmezse son bilinen ya da nil.
/// 2026-11-09: konum HER iletiye eklenir — ≤2 dk taze konum önbellekten; yoksa ön planda tek seferlik istek
/// (en çok `bekleSn`); o da yoksa alan boş. Telsiz çalışırken ön planda 90 sn'de bir tazelenir (AĞ v3 nabzı) → gönderim beklemez.
final class TelsizKonum: NSObject, CLLocationManagerDelegate {
    static let shared = TelsizKonum()
    static let tazeSn: TimeInterval = 120
    private let yonetici = CLLocationManager()
    private var bekleyenler: [(CLLocation?) -> Void] = []
    private var sonKonum: CLLocation?

    private var izinli: Bool {
        let d = yonetici.authorizationStatus
        return d == .authorizedWhenInUse || d == .authorizedAlways
    }

    /// ≤2 dk taze konum (önbellek ya da sistemin son konumu); yoksa nil. Ana iş parçacığında.
    func taze() -> CLLocation? {
        let adaylar = [sonKonum, izinli ? yonetici.location : nil].compactMap { $0 }
        guard let en = adaylar.max(by: { $0.timestamp < $1.timestamp }), -en.timestamp.timeIntervalSinceNow <= Self.tazeSn,
              en.horizontalAccuracy >= 0 else { return nil }
        return en
    }

    /// Haritada uzaklık/yön için (gönderimde DEĞİL): en çok `maksYasSn` eski son konum.
    func son(maksYasSn: TimeInterval) -> CLLocation? {
        let adaylar = [sonKonum, izinli ? yonetici.location : nil].compactMap { $0 }
        guard let en = adaylar.max(by: { $0.timestamp < $1.timestamp }), -en.timestamp.timeIntervalSinceNow <= maksYasSn,
              en.horizontalAccuracy >= 0 else { return nil }
        return en
    }

    /// Gönderim için konum: taze varsa hemen; yoksa ön plandaysa en çok `bekleSn` bekleyen tek seferlik istek; değilse nil.
    /// Sonuç ana iş parçacığında verilir.
    func gonderimKonumu(bekleSn: TimeInterval, _ tamam: @escaping (CLLocation?) -> Void) {
        DispatchQueue.main.async {
            if let k = self.taze() { tamam(k); return }
            guard UIApplication.shared.applicationState == .active, self.izinli else { tamam(nil); return }
            var bitti = false
            let bir: (CLLocation?) -> Void = { k in
                guard !bitti else { return }
                bitti = true
                tamam(k.flatMap { -$0.timestamp.timeIntervalSinceNow <= Self.tazeSn ? $0 : nil })
            }
            self.al { k in DispatchQueue.main.async { bir(k) } }
            DispatchQueue.main.asyncAfter(deadline: .now() + bekleSn) { bir(self.taze()) }
        }
    }

    /// Ön planda ve izin varken arka arkaya olmayan tek seferlik konum isteği (sonuç önbelleğe yazılır).
    func tazele() {
        DispatchQueue.main.async {
            guard UIApplication.shared.applicationState == .active, self.izinli, self.bekleyenler.isEmpty else { return }
            self.al { _ in }
        }
    }

    /// Telsiz ilk açıldığında (ön planda) konum izni bir kez sorulur — mesajlar konumsuz kalmasın.
    func izinIsteGerekirse() {
        DispatchQueue.main.async {
            guard UIApplication.shared.applicationState == .active, self.yonetici.authorizationStatus == .notDetermined else { return }
            self.yonetici.requestWhenInUseAuthorization()
        }
    }

    override init() {
        super.init()
        yonetici.delegate = self
        yonetici.desiredAccuracy = kCLLocationAccuracyBest
    }

    func al(_ tamam: @escaping (CLLocation?) -> Void) {
        DispatchQueue.main.async {
            self.bekleyenler.append(tamam)
            guard self.bekleyenler.count == 1 else { return }
            switch self.yonetici.authorizationStatus {
            case .notDetermined: self.yonetici.requestWhenInUseAuthorization()
            case .authorizedWhenInUse, .authorizedAlways: self.yonetici.requestLocation()
            default: self.bitir(nil); return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 15) { self.bitir(self.yonetici.location) }
        }
    }

    private func bitir(_ k: CLLocation?) {
        if let k, k.horizontalAccuracy >= 0, sonKonum == nil || k.timestamp > sonKonum!.timestamp { sonKonum = k }
        let l = bekleyenler
        bekleyenler = []
        l.forEach { $0(k) }
    }

    func locationManagerDidChangeAuthorization(_ m: CLLocationManager) {
        // İzin yeni verildiyse ilk konum hemen alınır (sonraki ileti beklemesin).
        guard !bekleyenler.isEmpty else { if izinli { tazele() }; return }
        switch m.authorizationStatus {
        case .authorizedWhenInUse, .authorizedAlways: m.requestLocation()
        case .notDetermined: break
        default: bitir(nil)
        }
    }

    func locationManager(_ m: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        bitir(locations.last)
    }

    func locationManager(_ m: CLLocationManager, didFailWithError error: Error) {
        bitir(m.location)
    }
}

// MARK: - Web köprüsü (2026-11-05, tek ekran)
//
// uygulama sayfası artık ayrı yerel ekran açmaz; motoru doğrudan kullanır (src/index.ts `yerelMotor`):
// motor() başlatır, liste() geçerli kanalın mesajlarını (sessiz) verir, cal(id) yerelde çalar, kayitBaslat/Bitir ve
// metinGonder yerel ağa gönderir; internet varsa sayfa iki yönlü köprüdür: bekleyenler() → sunucu, disaridan() → yerel ağ.
// Kanal adları "k0" (Genel) … "k99"; şifre anahtarı kanal adından türediği için web ve iki platform aynı kanalı çözer.

extension TelsizMotoru {
    func webListe() -> [[String: Any]] {
        mesajlar.map { m in
            var o: [String: Any] = ["id": m.id, "kanal": m.kanal, "olusturulduMs": m.olusturulduMs, "atlama": m.atlama,
                                    "sureMs": m.sureMs, "mime": m.mime, "kendim": m.kendim, "yuklendi": m.yuklendi]
            if let c = Self.coz(m) {
                // Ad iletideki gibi (yeni derlemeler zaten maskeli yollar; eskilerin tam adını sayfa maskeler).
                o["ad"] = c.ad
                if let t = c.metin { o["metin"] = t }
                if let a = c.enlem, let b = c.boylam { o["enlem"] = a; o["boylam"] = b }
                if let km = c.konumMs { o["konumMs"] = km }
                if let d = c.durum { o["durum"] = d }
                if let k = c.kisi { o["kisi"] = k }
            } else {
                o["ad"] = ""
            }
            return o
        }
    }

    func webDurum() -> [String: Any] {
        var bt = "bilinmiyor"
        switch CBManager.authorization {
        case .allowedAlways: bt = "var"
        case .denied, .restricted: bt = "yok"
        default: break
        }
        var mik = "bilinmiyor"
        switch AVAudioSession.sharedInstance().recordPermission {
        case .granted: mik = "var"
        case .denied: mik = "yok"
        default: break
        }
        // 2026-11-09: "bagli" = yakındaki CİHAZ sayısı — aynı cihaz hem Bluetooth hem Wi-Fi'dan bağlıysa tek sayılır (AĞ v3 varlık eşlemesi).
        var d: [String: Any] = ["kullanilabilir": true, "surum": 2, "calisiyor": calisiyor, "bagli": dogrudanCihazSayisi(), "internetVar": internetVar,
                "kayitta": kayitta, "calanId": calanId ?? NSNull(), "bluetoothIzni": bt, "mikrofonIzni": mik, "kanal": kanal,
                "durumOzet": durumOzeti(),
                // 2026-11-08 (2.0.7): iPhone ↔ iPhone Bluetooth LE var (TelsizBLE merkez rolü). Web bu alan yoksa (2.0.6)
                // "iPhone'lar arası Wi-Fi ile; Bluetooth sonraki güncellemede" notunu gösterir (src/lib/acil/telsiz-ag.ts).
                "bleMerkez": true,
                // 2026-11-09: arka planda dinleme HER ZAMAN açık → "arkaPlan" alanı artık verilmez; web (çevrimiçi sayfa ve eski
                // çevrimdışı sayfa) alan yoksa anahtarı hiç çizmez. "agSurum" 3: varlık/davet/yardım yöntemleri var.
                "arkaPlanHep": arkaPlan, "agSurum": TelsizAg.surum]
        // 2026-11-08: Bluetooth kapalıyken (izin var) sayfa "Bluetooth kapalı" der; Android zaten veriyordu.
        if let a = ble.acikMi { d["bluetoothAcik"] = a }
        return d
    }

    func calKimlik(_ id: String) {
        guard let m = tumu[id] else { return }
        cal(m)
    }

    /// Sunucudaki mesajları (internetli bir telefon köprüyken) yerel ağa verir. Kimlik "c_" önekiyse öneksiz kullanılır →
    /// yerelden yüklenmiş mesaj ağa ikinci kez girmez. Yerel kayıtta "yüklendi" işaretlidir (sunucuya geri gitmez).
    func disaridanEkle(_ dizi: [[String: Any]]) {
        let simdi = Int64(Date().timeIntervalSince1970 * 1000)
        var eklendi = false
        for o in dizi.prefix(30) {
            var id = (o["id"] as? String) ?? ""
            if id.hasPrefix("c_") { id = String(id.dropFirst(2)) }
            // Sunucudaki yardım çağrısı (yerelden yüklenmiş) düz metin olarak ağa geri girmesin.
            guard id.count >= 8, id.count <= 64, id.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }),
                  tumu[id] == nil, yardimlar[id] == nil, o["yardim"] == nil else { continue }
            let kanal = (o["kanal"] as? String) ?? ""
            let t = (o["olusturulduMs"] as? NSNumber)?.int64Value ?? 0
            guard !kanal.isEmpty, kanal.count <= 64, simdi - t < Self.omurMs, t <= simdi + 5 * 60_000 else { continue }
            let mime = (o["mime"] as? String) ?? ""
            // 2026-11-09: sunucudaki tam ad internetsiz ağa maskeli girer (telsizde yalnız baş harfler paylaşılır).
            let ad = TelsizAg.maskele((o["ad"] as? String) ?? "")
            var ic: TelsizIcerik
            if mime == Self.metinMime {
                guard let mt = Self.metinTemizle((o["metin"] as? String) ?? "") else { continue }
                ic = TelsizIcerik(ad: ad, ses: "")
                ic.metin = mt
            } else {
                var b64 = (o["sesBase64"] as? String) ?? ""
                if let v = b64.firstIndex(of: ",") { b64 = String(b64[b64.index(after: v)...]) }
                guard mime.hasPrefix("audio/"), !b64.isEmpty, b64.count < 2_100_000, Data(base64Encoded: b64) != nil else { continue }
                ic = TelsizIcerik(ad: ad, ses: b64)
            }
            if let a = (o["enlem"] as? NSNumber)?.doubleValue, let b = (o["boylam"] as? NSNumber)?.doubleValue, abs(a) <= 90, abs(b) <= 180 {
                ic.enlem = a
                ic.boylam = b
            }
            guard let veri = Self.sifrele(ic, kanal: kanal) else { continue }
            let sure = max(0, min((o["sureMs"] as? NSNumber)?.intValue ?? 0, Int(Self.maksSureSn * 1000)))
            let m = TelsizMesaj(id: id, kanal: kanal, olusturulduMs: t, atlama: 1, sureMs: sure, mime: mime, veri: veri,
                                alindiMs: simdi, kendim: false, yuklendi: true)
            tumu[id] = m
            diskeYaz(m)
            if pilYeterli() { gonder(m) }
            eklendi = true
        }
        if eklendi { yayinla() }
    }
}

// MARK: - Uygulama tarafı API (AppDelegate)

/// Uygulamanın AppDelegate'inden çağrılan yardımcılar (README → iOS).
public enum DisasterWalkieTalkie {
    /// Yerel (SwiftUI) yedek telsiz ekranını en üstteki ekranın üzerinde açar. Ana iş parçacığında çağrılmalı.
    /// Asıl arayüz uygulamanın kendi sayfasıdır; bu ekran web arayüzü yüklenemediğinde kullanılabilecek basit bir yedektir.
    public static func goster(kanal: String? = nil, kanalAdi: String? = nil, ad: String? = nil, testPaneli: Bool? = nil) {
        TelsizMotoru.shared.ayarla(kanal: kanal, kanalAdi: kanalAdi, ad: ad, testPaneli: testPaneli)
        guard let pencere = UIApplication.shared.connectedScenes.compactMap({ ($0 as? UIWindowScene)?.windows.first(where: { $0.isKeyWindow }) }).first
                ?? UIApplication.shared.connectedScenes.compactMap({ ($0 as? UIWindowScene)?.windows.first }).first,
              var ust = pencere.rootViewController else { return }
        while let p = ust.presentedViewController { ust = p }
        if ust is UIHostingController<TelsizEkrani> { return }
        var vcRef: UIViewController?
        let ekran = TelsizEkrani(kapat: { vcRef?.dismiss(animated: true) })
        let vc = UIHostingController(rootView: ekran)
        vcRef = vc
        vc.modalPresentationStyle = .fullScreen
        ust.present(vc, animated: true)
    }

    /// AppDelegate `application(_:didFinishLaunchingWithOptions:)` içinde, ana iş parçacığında çağrılır. iOS uygulamayı telsiz
    /// Bluetooth olayı için arka planda yeniden başlattıysa (CoreBluetooth durum geri yükleme) ya da kişi Bluetooth iznini DAHA ÖNCE
    /// vermişse motor arayüzsüz, yalnız Bluetooth kipinde başlar → cihaz telsiz sayfası açılmadan da ağda dinler ve aktarır.
    /// İzin hiç sorulmadıysa hiçbir şey yapmaz (açılışta izin penceresi çıkmaz). Aktarma pil eşiği (%20) motorda aynen geçerli.
    public static func acilistaBaslat(_ secenekler: [UIApplication.LaunchOptionsKey: Any]?) {
        let uyandirildi = secenekler?[.bluetoothCentrals] != nil || secenekler?[.bluetoothPeripherals] != nil
        guard uyandirildi || CBManager.authorization == .allowedAlways else { return }
        TelsizMotoru.shared.kendiligindenBaslat()
    }

    /// Telsizin yerel bildirimine dokunulduysa (userInfo["telsiz"] var) JS'e "bildirimeDokunuldu" olayı gönderir ve true döner.
    /// UNUserNotificationCenterDelegate `didReceive` içinden çağrılabilir.
    @discardableResult
    public static func bildirimeDokunuldu(_ bilgi: [AnyHashable: Any]) -> Bool {
        TelsizMotoru.bildirimeDokunuldu(bilgi)
    }
}

// MARK: - Capacitor eklentisi

@objc(DisasterWalkieTalkiePlugin)
public class DisasterWalkieTalkiePlugin: CAPPlugin, CAPBridgedPlugin {
    public let identifier = "DisasterWalkieTalkiePlugin"
    public let jsName = "DisasterWalkieTalkie"
    public let pluginMethods: [CAPPluginMethod] = [
        CAPPluginMethod(name: "durum", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "ac", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "bekleyenler", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "yuklendi", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "duyuruYay", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "motor", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "kanalSec", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "izinIste", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "kayitBaslat", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "kayitBitir", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "metinGonder", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "durumGonder", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "liste", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "cal", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "disaridan", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "birak", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "arkaPlanAyarla", returnType: CAPPluginReturnPromise),
        // 2026-11-09 AĞ v3 (sözleşme: src/index.ts — ADLARI DEĞİŞTİRME; Yardım sekmesi bunlara göre yazıldı)
        CAPPluginMethod(name: "adAyarla", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "cihazlar", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "davetGonder", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "davetYanitla", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "davetler", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "yardimGonder", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "yardimListe", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "yardimaGidiyorum", returnType: CAPPluginReturnPromise),
        // Wi-Fi Aware ek taşıması (iOS 26+, isteğe bağlı; TelsizWifiAware.swift)
        CAPPluginMethod(name: "waDurum", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "waEsles", returnType: CAPPluginReturnPromise),
    ]

    private var abone: AnyCancellable?
    private var olayAbone: AnyCancellable?

    override public func load() {
        // Motordaki her değişiklik (yeni mesaj, bağlantı, kayıt, çalma) web'e "degisti" olarak gider; sayfa liste()/durum() ister.
        abone = TelsizMotoru.shared.objectWillChange
            .debounce(for: .milliseconds(200), scheduler: RunLoop.main)
            .sink { [weak self] _ in self?.notifyListeners("degisti", data: [:]) }
        // AĞ v3 olayları: cihazlar, davet, davetYaniti, yardim, kanalDegisti, bildirimeDokunuldu.
        olayAbone = TelsizMotoru.shared.olaylar
            .receive(on: RunLoop.main)
            .sink { [weak self] olay in self?.notifyListeners(olay.0, data: olay.1) }
        // Wi-Fi Aware: destekleyen cihazda (iOS 26+, Info.plist WiFiAwareServices + yetki) taşımayı motora bağlar.
        WifiAwareKopru.kur { [weak self] in self?.notifyListeners("degisti", data: [:]) }
    }

    @objc func waDurum(_ call: CAPPluginCall) {
        DispatchQueue.main.async { call.resolve(WifiAwareKopru.durum()) }
    }

    /// Sistemin Wi-Fi Aware eşleştirme ekranı. rol: "gorunur" (bu telefon görünür olur) | "ara" (yakındaki görünür telefonu seç).
    @objc func waEsles(_ call: CAPPluginCall) {
        let rol = call.getString("rol") == "gorunur" ? "gorunur" : "ara"
        let kapat = String((call.getString("kapat") ?? "").prefix(30))
        Task { @MainActor in
            if WifiAwareKopru.eslesmeEkraniniAc(rol: rol, kapat: kapat, uzerinde: self.bridge?.viewController) {
                call.resolve()
            } else {
                call.unavailable("wifi-aware")
            }
        }
    }

    @objc func adAyarla(_ call: CAPPluginCall) {
        let ad = call.getString("ad") ?? ""
        DispatchQueue.main.async {
            TelsizMotoru.shared.adAyarla(ad)
            call.resolve()
        }
    }

    @objc func cihazlar(_ call: CAPPluginCall) {
        DispatchQueue.main.async { call.resolve(TelsizMotoru.shared.cihazListesi()) }
    }

    @objc func davetGonder(_ call: CAPPluginCall) {
        let kisi = call.getString("kisi") ?? ""
        let kanal = call.getInt("kanal") ?? 0
        DispatchQueue.main.async {
            guard let id = TelsizMotoru.shared.davetGonder(kisi: kisi, kanal: kanal) else { call.reject("GECERSIZ"); return }
            call.resolve(["id": id])
        }
    }

    @objc func davetYanitla(_ call: CAPPluginCall) {
        let id = call.getString("id") ?? ""
        let kabul = call.getBool("kabul") ?? false
        DispatchQueue.main.async {
            let kn = TelsizMotoru.shared.davetYanitla(id: id, kabul: kabul)
            var o: [String: Any] = ["kabul": kabul]
            if let kn { o["kanal"] = "k\(kn)" }
            call.resolve(o)
        }
    }

    @objc func davetler(_ call: CAPPluginCall) {
        DispatchQueue.main.async { call.resolve(["davetler": TelsizMotoru.shared.davetListesi()]) }
    }

    @objc func yardimGonder(_ call: CAPPluginCall) {
        let tur = call.getString("tur") ?? ""
        let kisiSayisi = call.getInt("kisiSayisi") ?? 1
        let not = call.getString("not") ?? ""
        DispatchQueue.main.async {
            TelsizMotoru.shared.yardimGonder(tur: tur, kisiSayisi: kisiSayisi, not: not) { id in
                if let id { call.resolve(["id": id]) } else { call.reject("GECERSIZ") }
            }
        }
    }

    @objc func yardimListe(_ call: CAPPluginCall) {
        DispatchQueue.main.async { call.resolve(["yardimlar": TelsizMotoru.shared.yardimListesi()]) }
    }

    @objc func yardimaGidiyorum(_ call: CAPPluginCall) {
        let id = call.getString("id") ?? ""
        DispatchQueue.main.async {
            if TelsizMotoru.shared.yardimaGidiyorum(id: id) { call.resolve() } else { call.reject("YOK") }
        }
    }

    @objc func durum(_ call: CAPPluginCall) {
        DispatchQueue.main.async { call.resolve(TelsizMotoru.shared.webDurum()) }
    }

    /// Sayfa açıkken motoru başlatır (izin zaten verilmişse otomatik; değilse sayfa "İzin ver" ile izinIste çağırır).
    @objc func motor(_ call: CAPPluginCall) {
        let kanal = call.getString("kanal")
        let kanalAdi = call.getString("kanalAdi")
        let ad = call.getString("ad")
        let sa = call.getBool("testPaneli")
        DispatchQueue.main.async {
            let m = TelsizMotoru.shared
            m.otomatikCal = false
            m.ayarla(kanal: kanal, kanalAdi: kanalAdi, ad: ad, testPaneli: sa)
            m.baslat()
            UIApplication.shared.isIdleTimerDisabled = true
            call.resolve(m.webDurum())
        }
    }

    @objc func kanalSec(_ call: CAPPluginCall) {
        let kanal = call.getString("kanal")
        let kanalAdi = call.getString("kanalAdi")
        DispatchQueue.main.async {
            TelsizMotoru.shared.ayarla(kanal: kanal, kanalAdi: kanalAdi, ad: nil, testPaneli: nil)
            call.resolve()
        }
    }

    /// iOS izin penceresini Bluetooth yöneticisi ilk başlarken kendisi açar → başlatmak yeter.
    @objc func izinIste(_ call: CAPPluginCall) {
        DispatchQueue.main.async {
            TelsizMotoru.shared.baslat()
            call.resolve(TelsizMotoru.shared.webDurum())
        }
    }

    @objc func kayitBaslat(_ call: CAPPluginCall) {
        DispatchQueue.main.async {
            TelsizMotoru.shared.kayitBaslat()
            call.resolve(TelsizMotoru.shared.webDurum())
        }
    }

    @objc func kayitBitir(_ call: CAPPluginCall) {
        DispatchQueue.main.async {
            TelsizMotoru.shared.kayitBitir()
            call.resolve()
        }
    }

    @objc func metinGonder(_ call: CAPPluginCall) {
        let metin = call.getString("metin") ?? ""
        let konumla = call.getBool("konumla") ?? false
        DispatchQueue.main.async {
            TelsizMotoru.shared.metinGonder(metin, konumla: konumla)
            call.resolve()
        }
    }

    @objc func durumGonder(_ call: CAPPluginCall) {
        let durum = call.getString("durum") ?? ""
        let metin = call.getString("metin") ?? ""
        let konumla = call.getBool("konumla") ?? false
        DispatchQueue.main.async {
            TelsizMotoru.shared.durumGonder(durum, metin: metin, konumla: konumla)
            call.resolve()
        }
    }

    @objc func liste(_ call: CAPPluginCall) {
        DispatchQueue.main.async { call.resolve(["mesajlar": TelsizMotoru.shared.webListe()]) }
    }

    @objc func cal(_ call: CAPPluginCall) {
        let id = call.getString("id") ?? ""
        DispatchQueue.main.async {
            TelsizMotoru.shared.calKimlik(id)
            call.resolve()
        }
    }

    @objc func disaridan(_ call: CAPPluginCall) {
        let dizi = (call.getArray("mesajlar") as? [[String: Any]]) ?? []
        DispatchQueue.main.async {
            TelsizMotoru.shared.disaridanEkle(dizi)
            call.resolve()
        }
    }

    /// Sayfadan çıkılınca: ekran kilidi serbest, yerel otomatik çalma geri açık (motor ağda aktarıcı olarak sürer).
    /// 2026-11-08 FAZ 2: "Arka planda dinlemeye devam et" anahtarı (telsiz kartı). Yeni durumu döner.
    @objc func arkaPlanAyarla(_ call: CAPPluginCall) {
        let acik = call.getBool("acik") ?? false
        DispatchQueue.main.async {
            TelsizMotoru.shared.arkaPlanAyarla(acik)
            call.resolve(TelsizMotoru.shared.webDurum())
        }
    }

    @objc func birak(_ call: CAPPluginCall) {
        DispatchQueue.main.async {
            TelsizMotoru.shared.otomatikCal = true
            UIApplication.shared.isIdleTimerDisabled = false
            call.resolve()
        }
    }

    @objc func ac(_ call: CAPPluginCall) {
        let kanal = call.getString("kanal")
        let kanalAdi = call.getString("kanalAdi")
        let ad = call.getString("ad")
        let sa = call.getBool("testPaneli")
        DispatchQueue.main.async {
            DisasterWalkieTalkie.goster(kanal: kanal, kanalAdi: kanalAdi, ad: ad, testPaneli: sa)
            call.resolve()
        }
    }

    @objc func bekleyenler(_ call: CAPPluginCall) {
        DispatchQueue.main.async {
            call.resolve(["mesajlar": TelsizMotoru.shared.bekleyenler()])
        }
    }

    @objc func duyuruYay(_ call: CAPPluginCall) {
        let etkinlikId = call.getString("etkinlikId") ?? ""
        let baslik = call.getString("baslik") ?? ""
        let metin = call.getString("metin") ?? ""
        DispatchQueue.main.async {
            TelsizMotoru.shared.duyuruYay(etkinlikId: etkinlikId, baslik: baslik, metin: metin)
            call.resolve()
        }
    }

    @objc func yuklendi(_ call: CAPPluginCall) {
        let idler = (call.getArray("idler", String.self) ?? [])
        DispatchQueue.main.async {
            TelsizMotoru.shared.yuklendiIsaretle(idler)
            call.resolve()
        }
    }
}

// MARK: - 2026-11-06: ek taşıma (Wi-Fi Aware) + Apple Bas-Konuş (Push to Talk) sesi
//
// Ek taşıma: TelsizWifiAware.swift (iOS 26+, yalnız kullanıcı en az bir telefonla eşleştiyse çalışır). Apple Bas-Konuş
// (PushToTalk) katmanı hangel'de sunucuya bağlı olduğu için bu sürüme alınmadı; `basKonusSesi` onu ekleyecek uygulamalar içindir.

extension TelsizMotoru {
    /// Ek taşımayı bağlar (bir kez); motor çalışıyorsa hemen başlatır. Ana iş parçacığında çağrılmalı.
    func ekTasimaBagla(_ t: TelsizEkTasima) {
        guard ek == nil else { return }
        t.yukAlindi = { [weak self] id, veri in self?.al(veri, kimden: .ek(id)) }
        t.yeniBaglanti = { [weak self] id in DispatchQueue.main.async { self?.ekYeniBaglanti(id) } }
        t.baglantilarDegisti = { [weak self] adlar in
            DispatchQueue.main.async {
                guard let self else { return }
                self.ekBaglilar = adlar
                self.bagliGuncelle()
            }
        }
        ek = t
        if tamCalisiyor { t.baslat() }
    }

    /// Motor yakındaki telefonlarla bağlantı arıyor mu (sayfa ya da yerel ekran başlattı).
    /// Telsiz ekranı/sayfası motoru başlattı mı (TAM kip). Açılıştaki arayüzsüz Bluetooth kipi sayılmaz → uygulama ekran tutmayı
    /// eskisi gibi bırakabilir.
    var calisiyorMu: Bool { tamCalisiyor }

    /// Ek taşımada yeni bağlanan telefona son 72 saatin mesajları (en çok 30) ve süren duyurular.
    private func ekYeniBaglanti(_ id: String) {
        guard let ek else { return }
        for v in agGecmisi() { ek.gonderKime(id, v) } // önce varlık + yardım
        let simdi = Int64(Date().timeIntervalSince1970 * 1000)
        let son = tumu.values.filter { simdi - $0.olusturulduMs < Self.omurMs && $0.atlama < Self.maksAtlama }
            .sorted { $0.olusturulduMs > $1.olusturulduMs }.prefix(30)
        for m in son { if let v = Self.kablo(m) { ek.gonderKime(id, v) } }
        for d in duyurular.values where simdi - d.t < Self.duyuruOmurMs && d.atlama < Self.maksAtlama {
            if let v = try? JSONEncoder().encode(d) { ek.gonderKime(id, v) }
        }
    }

    /// Bas-Konuş'la (kilit ekranı / sistem düğmesi) kaydedilen sesi verilen kanalda yerel ağa verir ve mesajı döndürür.
    /// Uygulama arka planda uyandırıldığında motorun kanalı/adı yüklenmemiş olabilir → kanal açıkça verilir, ad kayıttan.
    func basKonusSesi(_ ses: Data, sureMs: Int, kanal k: String) -> TelsizMesaj? {
        // 2026-11-09: maskeli ad + kişi kodu + (≤2 dk taze) konum; arka planda uyandırılmışken konum beklenmez.
        var ic = TelsizIcerik(ad: "", ses: ses.base64EncodedString())
        gidenIcerik(&ic, konum: TelsizKonum.shared.taze())
        guard !ses.isEmpty, !k.isEmpty, let veri = Self.sifrele(ic, kanal: k) else { return nil }
        let simdi = Int64(Date().timeIntervalSince1970 * 1000)
        let id = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        let m = TelsizMesaj(id: id, kanal: k, olusturulduMs: simdi, atlama: 0, sureMs: max(0, min(sureMs, Int(Self.maksSureSn * 1000))),
                            mime: "audio/mp4", veri: veri, alindiMs: simdi, kendim: true, yuklendi: false)
        tumu[id] = m
        diskeYaz(m)
        yayinla()
        gonder(m)
        return m
    }

    /// Gönderenin görünen adı (Bas-Konuş yüklemesinde çevrimdışı meta için).
    func gonderenAdi(_ m: TelsizMesaj) -> String { Self.coz(m)?.ad ?? "" }
}

// MARK: - AĞ v3 (2026-11-09): varlık, davet, yardım çağrısı — kurallar src/protocol/mesh.ts (TEK BAŞVURU KAYNAĞI)
//
// Tasarım isteği (09.11): "Bluetooth ağına kaç kişinin bağlı olduğu mikrofonun hemen üstünde … dokununca bağlı olanların LİSTESİ; birini
// seçip KANAL belirleyip (örn. 92) TELSİZ DAVETİ gönder → karşıya BİLDİRİM → kabul ederse o özel kanalda konuşurlar." + yardım
// çağrısı (enkaz/yaralı/su-gıda/barınma/ilaç/diğer, kişi sayısı, kısa not, konum otomatik) ağa yayılır, internet gelince sunucuya.
// Kablo: düz JSON {v:3, tur, id, t, atlama, kisi, ad(maskeli), enlem?, boylam?, konumMs?, …}. Eski istemciler (v1/v2, Android) yok sayar.

/// v3 ağ iletisi. Tür dışı alanlar boş kalır (JSONEncoder nil alanları yazmaz).
struct TelsizAgKablo: Codable {
    var v: Int
    var tur: String
    var id: String
    var t: Int64
    var atlama: Int
    var kisi: String
    var ad: String
    var enlem: Double? = nil
    var boylam: Double? = nil
    var konumMs: Int64? = nil
    var cihaz: String? = nil
    var hedef: String? = nil
    var kanal: Int? = nil
    var davetId: String? = nil
    var kabul: Bool? = nil
    var ihtiyac: String? = nil
    var kisiSayisi: Int? = nil
    var not: String? = nil
    var yardimId: String? = nil
    /// 2026-11-09: varlıkta "hemen yanıtla" — yeni bağlantıda karşı taraf kendi varlığını HEMEN bu bağlantıya yollar (istek/yanıt).
    /// Yalnız doğrudan komşuya anlamlıdır; aktarılırken silinir. Eski 2.0.7 derlemeleri alanı yok sayar.
    var yanitIste: Bool? = nil
}

struct TelsizAgCihaz {
    let kisi: String
    let ad: String
    let enlem: Double?
    let boylam: Double?
    let sonGorulmeMs: Int64
    let atlama: Int
    let tur: String
}

/// Cihazda saklanan yardım çağrısı (24 sa; Application Support/walkie-talkie/yardim/<id>.json, tam koruma).
struct TelsizYardimKaydi: Codable {
    struct Giden: Codable { let kisi: String; let ad: String; let t: Int64 }
    let id: String
    let ihtiyac: String
    let kisiSayisi: Int
    let not: String
    let ad: String
    let kisi: String
    let enlem: Double?
    let boylam: Double?
    let konumMs: Int64?
    let t: Int64
    let atlama: Int
    let kendim: Bool
    var gidenler: [Giden]
    var yuklendi: Bool
    /// Bu cihaz "Yardıma gidiyorum" dedi mi.
    var gidiyorum: Bool

    func kablo() -> TelsizAgKablo {
        var k = TelsizAgKablo(v: TelsizAg.surum, tur: "yardim", id: id, t: t, atlama: atlama, kisi: kisi, ad: ad)
        k.enlem = enlem; k.boylam = boylam; k.konumMs = konumMs
        k.ihtiyac = ihtiyac; k.kisiSayisi = kisiSayisi; k.not = not
        return k
    }
}

enum TelsizAg {
    static let surum = 3
    static let turler: Set<String> = ["varlik", "davet", "davetYaniti", "yardim", "yardimaGidiyorum"]
    static let yardimTurleri = ["enkaz", "yarali", "su-gida", "barinma", "ilac", "diger"]
    static let cihazTurleri: Set<String> = ["iphone", "ipad", "mac", "android", "diger"]
    static let varlikZamanAsimiMs: Int64 = 180_000
    static let adMaks = 60
    static let notMaks = 140

    /// Saklanan atlama bundan küçükse aktarılır (TS AG_MAKS_ATLAMA).
    static func maksAtlama(_ tur: String) -> Int {
        switch tur {
        case "varlik": return 3
        case "yardim", "yardimaGidiyorum": return 16
        default: return 12
        }
    }

    /// TS AG_OMUR_MS.
    static func omurMs(_ tur: String) -> Int64 {
        switch tur {
        case "varlik": return 180_000
        case "davet", "davetYaniti": return 900_000
        default: return 86_400_000
        }
    }

    static var cihazTuru: String {
        if ProcessInfo.processInfo.isiOSAppOnMac || ProcessInfo.processInfo.isMacCatalystApp { return "mac" }
        switch UIDevice.current.userInterfaceIdiom {
        case .pad: return "ipad"
        case .phone: return "iphone"
        case .mac: return "mac"
        default: return "diger"
        }
    }

    static func kimlikGecerli(_ id: String) -> Bool {
        (8...64).contains(id.count) && id.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }
    }

    static func yeniKimlik() -> String {
        UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
    }

    /// Ad maskesi — TS adMaskele ile AYNI: NFC, denetim karakterleri boşluk, ilk 60 grafem; her kelime: ilk harf + kalan sayısı kadar "*".
    /// "İlayda Hande KÖSEOĞLU" → "İ***** H**** K*******". Maskeli ad yeniden maskelenince değişmez.
    static func maskele(_ ad: String) -> String {
        var s = ""
        for ch in ad.precomposedStringWithCanonicalMapping {
            s.append(ch.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 0x7f }) ? " " : ch)
        }
        return String(s.prefix(adMaks)).split(whereSeparator: { $0.isWhitespace })
            .map { k in String(k.first!) + String(repeating: "*", count: k.count - 1) }
            .joined(separator: " ")
    }

    /// TS yardimNotTemizle: satır sonu/sekme boşluk, denetim karakteri atılır, kırpılır, 140 kod noktası.
    static func notTemizle(_ n: String) -> String {
        var v = String.UnicodeScalarView()
        for c in n.unicodeScalars {
            if c == "\r" || c == "\n" || c == "\t" { v.append(" ") } else if c.value >= 32 { v.append(c) }
        }
        let t = String(v).trimmingCharacters(in: .whitespaces)
        var k = String.UnicodeScalarView()
        k.append(contentsOf: t.unicodeScalars.prefix(notMaks))
        return String(k)
    }

    /// TS agKabloDogrula: geçerli değilse nil; geçerliyse yalnız türün alanlarını taşıyan temiz kopya (ad maskeli, not temiz).
    static func dogrula(_ k: TelsizAgKablo, simdi: Int64) -> TelsizAgKablo? {
        guard k.v == surum, turler.contains(k.tur), kimlikGecerli(k.id), TelsizMotoru.kisiGecerli(k.kisi),
              simdi - k.t < omurMs(k.tur), k.t <= simdi + 300_000, k.atlama >= 0, k.atlama <= maksAtlama(k.tur) else { return nil }
        var y = TelsizAgKablo(v: surum, tur: k.tur, id: k.id, t: k.t, atlama: k.atlama, kisi: k.kisi, ad: maskele(k.ad))
        if let a = k.enlem, let b = k.boylam, a.isFinite, b.isFinite, abs(a) <= 90, abs(b) <= 180 {
            y.enlem = a; y.boylam = b
            if let km = k.konumMs, km > 0 { y.konumMs = km }
        }
        switch k.tur {
        case "varlik":
            y.cihaz = k.cihaz.flatMap { cihazTurleri.contains($0) ? $0 : nil } ?? "diger"
            if k.yanitIste == true { y.yanitIste = true }
        case "davet", "davetYaniti":
            guard let h = k.hedef, TelsizMotoru.kisiGecerli(h), let kn = k.kanal, (1...99).contains(kn) else { return nil }
            y.hedef = h; y.kanal = kn
            if k.tur == "davetYaniti" {
                guard let d = k.davetId, kimlikGecerli(d), let kb = k.kabul else { return nil }
                y.davetId = d; y.kabul = kb
            }
        case "yardim":
            guard let i = k.ihtiyac, yardimTurleri.contains(i) else { return nil }
            y.ihtiyac = i
            y.kisiSayisi = max(1, min(99, k.kisiSayisi ?? 1))
            y.not = notTemizle(k.not ?? "")
        case "yardimaGidiyorum":
            guard let d = k.yardimId, kimlikGecerli(d) else { return nil }
            y.yardimId = d
        default:
            return nil
        }
        return y
    }
}

/// Bildirim metinleri (12 dil; cihaz dili, yoksa Türkçe). Sıra: davetBaslik, davetGovde, kabulGovde, yardimBaslik, yardimGovde,
/// gidiyorGovde, enkaz, yarali, su-gida, barinma, ilac, diger, bilinmeyen.
enum TelsizAgMetin {
    private static let tablo: [String: [String]] = [
        "tr": ["Telsiz daveti", "{ad} seni Kanal {k} üzerinden konuşmaya çağırıyor. Yanıtlamak için dokun.", "{ad} davetini kabul etti · Kanal {k}", "Yakında yardım çağrısı", "{tur} · {n} kişi", "{ad} yardımına geliyor", "Enkaz altında", "Yaralı / ilk yardım", "Su / gıda", "Barınma", "İlaç", "Diğer", "Bilinmeyen"],
        "en": ["Radio invitation", "{ad} invites you to talk on Channel {k}. Tap to respond.", "{ad} accepted your invitation · Channel {k}", "Help call nearby", "{tur} · {n} people", "{ad} is coming to help you", "Trapped under debris", "Injured / first aid", "Water / food", "Shelter", "Medicine", "Other", "Unknown"],
        "de": ["Funkeinladung", "{ad} lädt dich ein, auf Kanal {k} zu sprechen. Zum Antworten tippen.", "{ad} hat deine Einladung angenommen · Kanal {k}", "Hilferuf in der Nähe", "{tur} · {n} Personen", "{ad} kommt dir zu Hilfe", "Unter Trümmern", "Verletzt / Erste Hilfe", "Wasser / Essen", "Unterkunft", "Medikamente", "Sonstiges", "Unbekannt"],
        "fr": ["Invitation radio", "{ad} t'invite à parler sur le canal {k}. Touche pour répondre.", "{ad} a accepté ton invitation · canal {k}", "Appel à l'aide à proximité", "{tur} · {n} personnes", "{ad} vient t'aider", "Sous les décombres", "Blessé / premiers secours", "Eau / nourriture", "Abri", "Médicaments", "Autre", "Inconnu"],
        "es": ["Invitación de radio", "{ad} te invita a hablar en el canal {k}. Toca para responder.", "{ad} aceptó tu invitación · canal {k}", "Llamada de ayuda cerca", "{tur} · {n} personas", "{ad} va a ayudarte", "Bajo escombros", "Herido / primeros auxilios", "Agua / comida", "Refugio", "Medicamentos", "Otro", "Desconocido"],
        "ar": ["دعوة لاسلكي", "{ad} يدعوك للتحدث على القناة {k}. اضغط للرد.", "{ad} قبل دعوتك · القناة {k}", "نداء استغاثة قريب", "{tur} · {n} أشخاص", "{ad} قادم لمساعدتك", "تحت الأنقاض", "مصاب / إسعافات أولية", "ماء / طعام", "مأوى", "دواء", "أخرى", "مجهول"],
        "fa": ["دعوت بی‌سیم", "{ad} تو را به گفتگو در کانال {k} دعوت می‌کند. برای پاسخ ضربه بزن.", "{ad} دعوتت را پذیرفت · کانال {k}", "درخواست کمک در نزدیکی", "{tur} · {n} نفر", "{ad} برای کمک به تو می‌آید", "زیر آوار", "مجروح / کمک‌های اولیه", "آب / غذا", "سرپناه", "دارو", "دیگر", "ناشناس"],
        "ru": ["Приглашение в рацию", "{ad} приглашает тебя поговорить на канале {k}. Нажми, чтобы ответить.", "{ad} принял(а) приглашение · канал {k}", "Призыв о помощи рядом", "{tur} · {n} чел.", "{ad} идёт тебе на помощь", "Под завалами", "Ранен / первая помощь", "Вода / еда", "Укрытие", "Лекарства", "Другое", "Неизвестный"],
        "hu": ["Rádiómeghívás", "{ad} meghív, hogy beszéljetek a(z) {k}. csatornán. Koppints a válaszhoz.", "{ad} elfogadta a meghívásodat · {k}. csatorna", "Segélykérés a közelben", "{tur} · {n} fő", "{ad} jön segíteni neked", "Romok alatt", "Sérült / elsősegély", "Víz / élelem", "Szállás", "Gyógyszer", "Egyéb", "Ismeretlen"],
        "az": ["Ratsiya dəvəti", "{ad} səni {k} kanalında danışmağa dəvət edir. Cavab vermək üçün toxun.", "{ad} dəvətini qəbul etdi · Kanal {k}", "Yaxında yardım çağırışı", "{tur} · {n} nəfər", "{ad} sənə kömək üçün gəlir", "Dağıntı altında", "Yaralı / ilk yardım", "Su / qida", "Sığınacaq", "Dərman", "Digər", "Naməlum"],
        "ha": ["Gayyatar rediyo", "{ad} yana gayyatar ka ku yi magana a tasha {k}. Taɓa don amsawa.", "{ad} ya karɓi gayyatarka · tasha {k}", "Kiran taimako a kusa", "{tur} · mutum {n}", "{ad} yana zuwa ya taimake ka", "A ƙarƙashin baraguzai", "Rauni / agajin farko", "Ruwa / abinci", "Mafaka", "Magani", "Wani", "Ba a sani ba"],
        "da": ["Radioinvitation", "{ad} inviterer dig til at tale på kanal {k}. Tryk for at svare.", "{ad} accepterede din invitation · kanal {k}", "Nødkald i nærheden", "{tur} · {n} personer", "{ad} kommer for at hjælpe dig", "Under murbrokker", "Såret / førstehjælp", "Vand / mad", "Husly", "Medicin", "Andet", "Ukendt"],
    ]
    private static let anahtarlar = ["davetBaslik", "davetGovde", "kabulGovde", "yardimBaslik", "yardimGovde", "gidiyorGovde",
                                     "enkaz", "yarali", "su-gida", "barinma", "ilac", "diger", "bilinmeyen"]

    static func m(_ k: String, dil: String? = nil, _ d: [String: String] = [:]) -> String {
        let dl = dil ?? String((Locale.preferredLanguages.first ?? "tr").prefix(2))
        let satir = tablo[dl] ?? tablo["tr"]!
        guard let i = anahtarlar.firstIndex(of: k), i < satir.count else { return k }
        return d.reduce(satir[i]) { $0.replacingOccurrences(of: "{\($1.key)}", with: $1.value) }
    }

    static func ad(_ maskeli: String) -> String { maskeli.isEmpty ? m("bilinmeyen") : maskeli }
}

extension TelsizMotoru {
    fileprivate static func simdiMs() -> Int64 { Int64(Date().timeIntervalSince1970 * 1000) }

    // MARK: Ad (çevrimiçiyken web verir; çevrimdışı gönderim kayıtlı adı kullanır)

    /// 2026-11-09 kök neden ("adsız"): uygulama sayfası motoru kullanıcı adı yüklenmeden (boş adla) başlatıyordu ve ad sonradan hiç
    /// iletilmiyordu → çevrimdışı iletiler adsız gidiyordu. Web artık ad gelince bunu çağırır (telsiz-ag.ts, afet paketi indirmesi).
    func adAyarla(_ yeni: String) {
        let t = yeni.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        let kisa = String(t.prefix(TelsizAg.adMaks))
        UserDefaults.standard.set(kisa, forKey: "walkieTalkieAd")
        guard kisa != ad else { return }
        ad = kisa
        if calisiyor { sonrakiVarlikMs = 0 } // yakındakiler yeni adı hemen görsün
    }

    // MARK: Nabız (varlık, konum tazeleme, budama)

    fileprivate func agBaslat() {
        // İzin penceresi yok (konum/bildirim izni yalnız TAM kipte sorulur); izin varsa ön planda konum tazelenir.
        TelsizKonum.shared.tazele()
        sonrakiVarlikMs = 0
        nabiz?.invalidate()
        let t = Timer(timeInterval: 5, repeats: true) { [weak self] _ in self?.agNabiz() }
        t.tolerance = 1
        RunLoop.main.add(t, forMode: .common)
        nabiz = t
        // İlk varlık konum gelince gitsin (en çok ~2 sn bekle).
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in self?.agNabiz() }
    }

    fileprivate func agNabiz() {
        guard calisiyor else { return }
        let simdi = Self.simdiMs()
        sikVarlik(simdi)
        if simdi >= sonrakiVarlikMs {
            agYay(varlikUret(simdi))
            sonrakiVarlikMs = simdi + Int64.random(in: 30_000...45_000)
        }
        let onPlanda = UIApplication.shared.applicationState == .active
        if onPlanda, simdi - sonKonumTazelemeMs >= 90_000 {
            sonKonumTazelemeMs = simdi
            TelsizKonum.shared.tazele()
        }
        if !onPlanda || !tamCalisiyor, simdi - sonTaramaTazelemeMs >= 60_000 {
            sonTaramaTazelemeMs = simdi
            ble.taramayiTazele()
        }
        agGorulen = agGorulen.filter { $0.value > simdi }
        sonVarliklar = sonVarliklar.filter { simdi - $0.value.t < TelsizAg.omurMs("varlik") }
        gelenDavetler = gelenDavetler.filter { simdi - $0.value.t < TelsizAg.omurMs("davet") }
        gidenDavetler = gidenDavetler.filter { simdi - $0.value.t < TelsizAg.omurMs("davet") }
        cihazlarDegistiyse()
    }

    fileprivate func agTemel(_ tur: String, konum: CLLocation?, simdi: Int64) -> TelsizAgKablo {
        var k = TelsizAgKablo(v: TelsizAg.surum, tur: tur, id: TelsizAg.yeniKimlik(), t: simdi, atlama: 0, kisi: Self.kisiKodu(),
                              ad: TelsizAg.maskele(gonderenTamAd()))
        if let c = konum {
            k.enlem = (c.coordinate.latitude * 1e5).rounded() / 1e5
            k.boylam = (c.coordinate.longitude * 1e5).rounded() / 1e5
            k.konumMs = Int64(c.timestamp.timeIntervalSince1970 * 1000)
        }
        return k
    }

    /// Varlığımızı tek bir doğrudan bağlantıya, öncelikli (Bluetooth kuyruğunun başına) yollar. Aynı bağlantıya 3 sn'de bir en çok.
    fileprivate func varlikYanitla(_ kaynak: TelsizKaynak, _ anahtar: String, simdi: Int64, yanitIste: Bool = false) {
        if let son = varlikGonderilen[anahtar], simdi - son < 3_000 { return }
        varlikGonderilen[anahtar] = simdi
        var v = varlikUret(simdi)
        if yanitIste { v.yanitIste = true }
        agGorulen[v.id] = simdi + TelsizAg.omurMs("varlik")
        guard let veri = try? JSONEncoder().encode(v) else { return }
        switch kaynak {
        case .mpc(let p): try? oturum?.send(veri, toPeers: [p], with: .reliable)
        case .ble(let b): ble.gonderKime(b, veri, oncelikli: true)
        case .ek(let e): ek?.gonderKime(e, veri)
        }
    }

    fileprivate func kaynak(_ anahtar: String) -> TelsizKaynak? {
        if anahtar.hasPrefix("ble:") { return .ble(String(anahtar.dropFirst(4))) }
        if anahtar.hasPrefix("ek:") { return .ek(String(anahtar.dropFirst(3))) }
        if anahtar.hasPrefix("mpc:"), let p = oturum?.connectedPeers.first(where: { "mpc:" + $0.displayName == anahtar }) { return .mpc(p) }
        return nil
    }

    /// Bağlantıların ilk görülme anı (cihaz listesinde "Bağlanıyor…" ve sık varlık için). Ana iş parçacığında.
    fileprivate func baglantiYaslariniGuncelle(_ simdi: Int64) {
        let aktif = Set(aktifBaglantilar)
        for b in aktif where baglantiIlkMs[b] == nil { baglantiIlkMs[b] = simdi }
        baglantiIlkMs = baglantiIlkMs.filter { aktif.contains($0.key) }
        varlikGonderilen = varlikGonderilen.filter { aktif.contains($0.key) }
    }

    /// İlk dakikada kimliği henüz bilinmeyen doğrudan bağlantılara 5 sn'de bir yanıt istekli varlık (nabız 5 sn'dir).
    fileprivate func sikVarlik(_ simdi: Int64) {
        baglantiYaslariniGuncelle(simdi)
        for b in aktifBaglantilar where baglantiKisi[b] == nil && simdi - (baglantiIlkMs[b] ?? simdi) < 60_000 {
            if let k = kaynak(b) { varlikYanitla(k, b, simdi: simdi, yanitIste: true) }
        }
    }

    /// "Buradayım": telsiz ekranını hiç açmamış kişide (yalnız aktarıcı) ad ve konum EKLENMEZ — paylaşım bilgi satırını görmedi.
    fileprivate func varlikUret(_ simdi: Int64) -> TelsizAgKablo {
        let kullanildi = telsizKullanildi
        var k = agTemel("varlik", konum: kullanildi ? TelsizKonum.shared.taze() : nil, simdi: simdi)
        if !kullanildi { k.ad = "" }
        k.cihaz = TelsizAg.cihazTuru
        return k
    }

    /// Kendi iletimizi yayar (görülenlere ekler → geri dönünce yok sayılır).
    fileprivate func agYay(_ k: TelsizAgKablo) {
        agGorulen[k.id] = k.t + TelsizAg.omurMs(k.tur)
        agGonder(k)
    }

    fileprivate func agGonder(_ k: TelsizAgKablo, haric: TelsizKaynak? = nil) {
        guard let veri = try? JSONEncoder().encode(k) else { return }
        if let s = oturum {
            let hedef = s.connectedPeers.filter { haric != .mpc($0) }
            if !hedef.isEmpty { try? s.send(veri, toPeers: hedef, with: .reliable) }
        }
        var haricBle: String?
        if case .ble(let b) = haric { haricBle = b }
        ble.gonder(veri, haric: haricBle)
        var haricEk: String?
        if case .ek(let e) = haric { haricEk = e }
        ek?.gonder(veri, haric: haricEk)
    }

    /// Yeni bağlanana: kendi varlığımız (bağlantıyı bize eşlesin) + yardım çağrıları (24 sa, en yeni 20) + "gidiyorum"lar + bilinen varlıklar.
    fileprivate func agGecmisi() -> [Data] {
        guard calisiyor else { return [] }
        let simdi = Self.simdiMs()
        var liste: [TelsizAgKablo] = []
        var ben = varlikUret(simdi)
        ben.yanitIste = true
        agGorulen[ben.id] = simdi + TelsizAg.omurMs("varlik")
        liste.append(ben)
        liste += yardimlar.values.filter { simdi - $0.t < TelsizAg.omurMs("yardim") && $0.atlama < TelsizAg.maksAtlama("yardim") }
            .sorted { $0.t > $1.t }.prefix(20).map { $0.kablo() }
        liste += gidiyorumlar.values.filter { simdi - $0.t < TelsizAg.omurMs("yardimaGidiyorum") && $0.atlama < TelsizAg.maksAtlama("yardimaGidiyorum") }
            .sorted { $0.t > $1.t }.prefix(30)
        liste += sonVarliklar.values.filter { simdi - $0.t < TelsizAg.omurMs("varlik") && $0.atlama < TelsizAg.maksAtlama("varlik") }
            .sorted { $0.t > $1.t }.prefix(20)
        let kodlayici = JSONEncoder()
        return liste.compactMap { try? kodlayici.encode($0) }
    }

    // MARK: Alma

    fileprivate func agAl(_ ham: TelsizAgKablo, kimden: TelsizKaynak) {
        let simdi = Self.simdiMs()
        guard let k = TelsizAg.dogrula(ham, simdi: simdi) else { return } // bilinmeyen tür / bozuk → yok say, aktarma
        DispatchQueue.main.async {
            // Doğrudan komşu: varlığın ilk gönderimi (atlama 0) bu bağlantıdan geldiyse bağlantı o kişinindir (yinelense de işlenir).
            if k.tur == "varlik", k.atlama == 0 {
                let b = Self.kaynakAnahtari(kimden)
                let yeni = self.baglantiKisi[b] != k.kisi
                if yeni { self.baglantiKisi[b] = k.kisi; self.cihazlarDegistiyse() }
                // İstek/yanıt: karşı taraf istediyse ya da bağlantı bize yeni eşlendiyse kendi varlığımız HEMEN ve öncelikli bu bağlantıya.
                if (k.yanitIste == true || yeni), k.kisi != Self.kisiKodu() { self.varlikYanitla(kimden, b, simdi: simdi) }
            }
            if k.kisi == Self.kisiKodu() { return }
            if let son = self.agGorulen[k.id], son > simdi { return }
            self.agGorulen[k.id] = simdi + TelsizAg.omurMs(k.tur)
            var y = k
            y.atlama = k.atlama + 1
            y.yanitIste = nil
            var aktar = true
            let ben = Self.kisiKodu()
            switch k.tur {
            case "varlik": self.varlikIsle(y, simdi: simdi)
            case "davet": if k.hedef == ben { aktar = false; self.davetGeldi(y) }
            case "davetYaniti": if k.hedef == ben { aktar = false; self.davetYanitiGeldi(y) }
            case "yardim": self.yardimGeldi(y, simdi: simdi)
            case "yardimaGidiyorum": self.gidiyorumGeldi(y)
            default: return
            }
            // Varlık pil %20 altındaysa aktarılmaz; davet ve yardım her zaman aktarılır (küçük ve hayati).
            if aktar, y.atlama < TelsizAg.maksAtlama(k.tur), k.tur != "varlik" || self.pilYeterli() {
                self.agGonder(y, haric: kimden)
            }
            // Arka planda Bluetooth olayıyla uyandırıldıysak "buradayım" gecikmesin (zamanlayıcı askıdaydı).
            if simdi >= self.sonrakiVarlikMs { self.agNabiz() }
        }
    }

    private func varlikIsle(_ y: TelsizAgKablo, simdi: Int64) {
        var atlama = y.atlama
        if let o = agdakiler[y.kisi], simdi - o.sonGorulmeMs < 90_000 { atlama = min(o.atlama, y.atlama) }
        agdakiler[y.kisi] = TelsizAgCihaz(kisi: y.kisi, ad: y.ad, enlem: y.enlem, boylam: y.boylam, sonGorulmeMs: simdi, atlama: atlama,
                                          tur: y.cihaz ?? "diger")
        sonVarliklar[y.kisi] = y.atlama < TelsizAg.maksAtlama("varlik") ? y : nil
        cihazlarDegistiyse()
    }

    private func davetVerisi(_ d: TelsizAgKablo) -> [String: Any] {
        ["id": d.id, "gonderenKisi": d.kisi, "gonderenAd": d.ad, "kanal": d.kanal ?? 0, "t": d.t]
    }

    private func davetGeldi(_ d: TelsizAgKablo) {
        guard gelenDavetler[d.id] == nil, let kn = d.kanal else { return }
        gelenDavetler[d.id] = d
        olaylar.send(("davet", davetVerisi(d)))
        // Ön planda da görünür (uygulamanın UNUserNotificationCenterDelegate willPresent işleyicisi gösterirse); dokununca telsiz sekmesi açılır.
        agBildir(kimlik: "telsiz-davet-\(d.id)", baslik: TelsizAgMetin.m("davetBaslik"),
                 govde: TelsizAgMetin.m("davetGovde", ["ad": TelsizAgMetin.ad(d.ad), "k": String(kn)]), tur: "davet", id: d.id)
    }

    private func davetYanitiGeldi(_ y: TelsizAgKablo) {
        guard let did = y.davetId, let g = gidenDavetler[did], g.hedef == y.kisi, let kn = g.kanal else { return }
        gidenDavetler.removeValue(forKey: did)
        let kabul = y.kabul == true
        if kabul { kanalaGec(kn) }
        olaylar.send(("davetYaniti", ["id": did, "kabul": kabul, "kisi": y.kisi, "ad": y.ad, "kanal": kn]))
        if kabul {
            agBildir(kimlik: "telsiz-kabul-\(did)", baslik: TelsizAgMetin.m("davetBaslik"),
                     govde: TelsizAgMetin.m("kabulGovde", ["ad": TelsizAgMetin.ad(y.ad), "k": String(kn)]), tur: "davetYaniti", id: did)
        }
    }

    private func kanalaGec(_ n: Int) {
        ayarla(kanal: "k\(n)", kanalAdi: "", ad: nil, testPaneli: nil)
        olaylar.send(("kanalDegisti", ["kanal": "k\(n)"]))
    }

    private func yardimGeldi(_ y: TelsizAgKablo, simdi: Int64) {
        guard yardimlar[y.id] == nil, let i = y.ihtiyac else { return }
        var kayit = TelsizYardimKaydi(id: y.id, ihtiyac: i, kisiSayisi: y.kisiSayisi ?? 1, not: y.not ?? "", ad: y.ad, kisi: y.kisi,
                                      enlem: y.enlem, boylam: y.boylam, konumMs: y.konumMs, t: y.t, atlama: y.atlama, kendim: false,
                                      gidenler: [], yuklendi: false, gidiyorum: false)
        // Önce gelmiş "gidiyorum"lar (başka yoldan) eklenir.
        for g in gidiyorumlar.values where g.yardimId == y.id && !kayit.gidenler.contains(where: { $0.kisi == g.kisi }) {
            kayit.gidenler.append(.init(kisi: g.kisi, ad: g.ad, t: g.t))
        }
        yardimlar[y.id] = kayit
        yardimDiskeYaz(kayit)
        olaylar.send(("yardim", ["yardim": yardimVerisi(kayit)]))
        // Bildirim: yalnız son 1 saatin çağrısı ve en çok 15 sn'de bir (yeni bağlanınca gelen 24 saatlik geçmiş kilit ekranını doldurmasın).
        if telsizKullanildi, simdi - y.t < 3_600_000, simdi - sonYardimBildirimMs > 15_000 {
            sonYardimBildirimMs = simdi
            agBildir(kimlik: "telsiz-yardim-\(y.id)", baslik: TelsizAgMetin.m("yardimBaslik"),
                     govde: "\(TelsizAgMetin.ad(y.ad)): " + TelsizAgMetin.m("yardimGovde", ["tur": TelsizAgMetin.m(i), "n": String(kayit.kisiSayisi)]),
                     tur: "yardim", id: y.id)
        }
    }

    private func gidiyorumGeldi(_ g: TelsizAgKablo) {
        if g.atlama < TelsizAg.maksAtlama("yardimaGidiyorum") { gidiyorumlar[g.id] = g }
        guard let yid = g.yardimId, var kayit = yardimlar[yid], !kayit.gidenler.contains(where: { $0.kisi == g.kisi }) else { return }
        kayit.gidenler.append(.init(kisi: g.kisi, ad: g.ad, t: g.t))
        yardimlar[yid] = kayit
        yardimDiskeYaz(kayit)
        olaylar.send(("yardim", ["yardim": yardimVerisi(kayit)]))
        if kayit.kendim {
            agBildir(kimlik: "telsiz-gidiyor-\(g.id)", baslik: TelsizAgMetin.m("yardimBaslik"),
                     govde: TelsizAgMetin.m("gidiyorGovde", ["ad": TelsizAgMetin.ad(g.ad)]), tur: "yardim", id: yid)
        }
    }

    // MARK: Cihaz listesi

    /// Doğrudan bağlantılar ∪ varlık iletileri (TS AgDugumu.cihazlar ile aynı kural). Aynı kişi iki yoldan bağlıysa tek; kimliği
    /// bilinmeyen bağlantı (eski sürüm / uyumsuz dinleyici) ayrı "bilinmiyor" cihaz sayılır ve davet edilemez (kisi "").
    func cihazListesi() -> [String: Any] {
        let simdi = Self.simdiMs()
        baglantiYaslariniGuncelle(simdi)
        let aktif = aktifBaglantilar
        let aktifKume = Set(aktif)
        baglantiKisi = baglantiKisi.filter { aktifKume.contains($0.key) }
        agdakiler = agdakiler.filter { simdi - $0.value.sonGorulmeMs < TelsizAg.varlikZamanAsimiMs }
        let ben = Self.kisiKodu()
        var dogrudan: [String] = []
        var liste: [[String: Any]] = []
        for b in aktif {
            if let k = baglantiKisi[b] {
                if k != ben, !dogrudan.contains(k) { dogrudan.append(k) }
            } else {
                // Kimliği (varlık) henüz gelmemiş bağlantı: ilk 60 sn "bağlanıyor"; sonra da gelmezse eski sürüm / uyumsuz dinleyici.
                let ilk = baglantiIlkMs[b] ?? simdi
                liste.append(["kisi": "", "ad": "", "sonGorulmeMs": simdi, "dogrudan": true, "atlama": 1, "tur": "bilinmiyor",
                              "baglaniyor": simdi - ilk < 60_000, "baglantiMs": ilk])
            }
        }
        func satir(_ c: TelsizAgCihaz?, kisi: String, dogrudanMi: Bool) -> [String: Any] {
            var o: [String: Any] = ["kisi": kisi, "ad": c?.ad ?? "", "sonGorulmeMs": c?.sonGorulmeMs ?? simdi, "dogrudan": dogrudanMi,
                                    "atlama": dogrudanMi ? 1 : (c?.atlama ?? 1), "tur": c?.tur ?? "diger"]
            if let a = c?.enlem, let b = c?.boylam { o["enlem"] = a; o["boylam"] = b }
            return o
        }
        for k in dogrudan { liste.append(satir(agdakiler[k], kisi: k, dogrudanMi: true)) }
        for (k, c) in agdakiler where !dogrudan.contains(k) { liste.append(satir(c, kisi: k, dogrudanMi: false)) }
        liste.sort {
            let d0 = ($0["dogrudan"] as? Bool) == true, d1 = ($1["dogrudan"] as? Bool) == true
            if d0 != d1 { return d0 }
            let a0 = ($0["atlama"] as? Int) ?? 9, a1 = ($1["atlama"] as? Int) ?? 9
            if a0 != a1 { return a0 < a1 }
            return (($0["sonGorulmeMs"] as? Int64) ?? 0) > (($1["sonGorulmeMs"] as? Int64) ?? 0)
        }
        let dSayi = liste.filter { ($0["dogrudan"] as? Bool) == true }.count
        var benO: [String: Any] = ["kisi": ben, "ad": TelsizAg.maskele(gonderenTamAd()), "tur": TelsizAg.cihazTuru]
        if let c = TelsizKonum.shared.son(maksYasSn: 600) {
            benO["enlem"] = (c.coordinate.latitude * 1e5).rounded() / 1e5
            benO["boylam"] = (c.coordinate.longitude * 1e5).rounded() / 1e5
        }
        return ["cihazlar": liste, "dogrudanSayi": dSayi, "agdakiSayi": liste.count, "ben": benO]
    }

    /// Yakındaki (doğrudan bağlı) CİHAZ sayısı — tekilleştirilmiş.
    func dogrudanCihazSayisi() -> Int { (cihazListesi()["dogrudanSayi"] as? Int) ?? 0 }

    /// Liste anlamca değiştiyse (kişi, ad, atlama, doğrudanlık, ~10 m konum) web'e "cihazlar" olayı.
    fileprivate func cihazlarDegistiyse() {
        let l = cihazListesi()
        let ozet = ((l["cihazlar"] as? [[String: Any]]) ?? []).map { o -> String in
            let a = (o["enlem"] as? Double).map { String(format: "%.4f", $0) } ?? "-"
            let b = (o["boylam"] as? Double).map { String(format: "%.4f", $0) } ?? "-"
            return "\(o["kisi"] ?? "")|\(o["ad"] ?? "")|\(o["atlama"] ?? "")|\(o["dogrudan"] ?? "")|\(a),\(b)"
        }.joined(separator: ";")
        guard ozet != sonCihazOzeti else { return }
        sonCihazOzeti = ozet
        olaylar.send(("cihazlar", l))
    }

    // MARK: Davet

    /// Hedef kişi koduna özel kanal daveti (1–99). Kimliği döner; geçersizse nil.
    func davetGonder(kisi hedef: String, kanal kn: Int) -> String? {
        guard calisiyor, Self.kisiGecerli(hedef), hedef != Self.kisiKodu(), (1...99).contains(kn) else { return nil }
        var k = agTemel("davet", konum: TelsizKonum.shared.taze(), simdi: Self.simdiMs())
        k.hedef = hedef
        k.kanal = kn
        gidenDavetler[k.id] = k
        agYay(k)
        return k.id
    }

    /// Gelen davete yanıt; kabulde bu cihaz o kanala geçer ve kanal numarası döner.
    func davetYanitla(id: String, kabul: Bool) -> Int? {
        guard let d = gelenDavetler.removeValue(forKey: id), let kn = d.kanal else { return nil }
        var k = agTemel("davetYaniti", konum: TelsizKonum.shared.taze(), simdi: Self.simdiMs())
        k.hedef = d.kisi
        k.kanal = kn
        k.davetId = id
        k.kabul = kabul
        agYay(k)
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: ["telsiz-davet-\(id)"])
        if kabul { kanalaGec(kn) }
        return kabul ? kn : nil
    }

    /// Yanıt bekleyen gelen davetler (sayfa açılınca kartı göstermek için; bildirimden açılış dahil). En yeni önce.
    func davetListesi() -> [[String: Any]] {
        let simdi = Self.simdiMs()
        return gelenDavetler.values.filter { simdi - $0.t < TelsizAg.omurMs("davet") }.sorted { $0.t > $1.t }.map { davetVerisi($0) }
    }

    // MARK: Yardım

    func yardimVerisi(_ y: TelsizYardimKaydi) -> [String: Any] {
        var o: [String: Any] = ["id": y.id, "tur": y.ihtiyac, "kisiSayisi": y.kisiSayisi, "not": y.not, "ad": y.ad, "kisi": y.kisi,
                                "t": y.t, "atlama": y.atlama, "kendim": y.kendim, "gidiyorum": y.gidiyorum, "yuklendi": y.yuklendi,
                                "gidenler": y.gidenler.map { ["kisi": $0.kisi, "ad": $0.ad, "t": $0.t] as [String: Any] }]
        if let a = y.enlem, let b = y.boylam { o["enlem"] = a; o["boylam"] = b }
        if let km = y.konumMs { o["konumMs"] = km }
        return o
    }

    /// Yardım çağrısı: konum (≤2 dk taze ya da en çok 6 sn'lik istek) + maskeli ad; ağa yayılır, cihazda 24 sa saklanır, internet
    /// gelince web köprüsü sunucuya yükler. Kimlik tamamda verilir (ana iş parçacığı); tür geçersizse nil.
    func yardimGonder(tur: String, kisiSayisi: Int, not: String, tamam: @escaping (String?) -> Void) {
        guard TelsizAg.yardimTurleri.contains(tur) else { tamam(nil); return }
        baslat()
        TelsizKonum.shared.gonderimKonumu(bekleSn: 6) { [weak self] konum in
            guard let self else { tamam(nil); return }
            var k = self.agTemel("yardim", konum: konum, simdi: Self.simdiMs())
            k.ihtiyac = tur
            k.kisiSayisi = max(1, min(99, kisiSayisi))
            k.not = TelsizAg.notTemizle(not)
            let kayit = TelsizYardimKaydi(id: k.id, ihtiyac: tur, kisiSayisi: k.kisiSayisi ?? 1, not: k.not ?? "", ad: k.ad, kisi: k.kisi,
                                          enlem: k.enlem, boylam: k.boylam, konumMs: k.konumMs, t: k.t, atlama: 0, kendim: true,
                                          gidenler: [], yuklendi: false, gidiyorum: false)
            self.yardimlar[k.id] = kayit
            self.yardimDiskeYaz(kayit)
            self.agYay(k)
            self.olaylar.send(("yardim", ["yardim": self.yardimVerisi(kayit)]))
            self.objectWillChange.send() // web köprüsü (degisti) bekleyenleri yüklesin
            tamam(k.id)
        }
    }

    /// Son 24 saatin yardım çağrıları, en yeni önce.
    func yardimListesi() -> [[String: Any]] {
        let simdi = Self.simdiMs()
        return yardimlar.values.filter { simdi - $0.t < TelsizAg.omurMs("yardim") }.sorted { $0.t > $1.t }.map { yardimVerisi($0) }
    }

    /// "Yardıma gidiyorum": ağa yayılır, çağrının "gidenler" listesine eklenir. Çağrı bilinmiyorsa false.
    func yardimaGidiyorum(id: String) -> Bool {
        guard var kayit = yardimlar[id], !kayit.kendim else { return false }
        if !kayit.gidiyorum {
            var k = agTemel("yardimaGidiyorum", konum: TelsizKonum.shared.taze(), simdi: Self.simdiMs())
            k.yardimId = id
            agYay(k)
            gidiyorumlar[k.id] = k
            kayit.gidiyorum = true
            if !kayit.gidenler.contains(where: { $0.kisi == k.kisi }) { kayit.gidenler.append(.init(kisi: k.kisi, ad: k.ad, t: k.t)) }
            yardimlar[id] = kayit
            yardimDiskeYaz(kayit)
        }
        olaylar.send(("yardim", ["yardim": yardimVerisi(kayit)]))
        return true
    }

    /// Web köprüsünün sunucuya yükleyeceği yardım çağrıları (bekleyenler() başında). Kanal k0, kısa metin + `yardim` alanı.
    fileprivate func yardimBekleyenler() -> [[String: Any]] {
        let simdi = Self.simdiMs()
        return yardimlar.values.filter { !$0.yuklendi && simdi - $0.t < TelsizAg.omurMs("yardim") }.sorted { $0.t < $1.t }.prefix(10).map { y in
            // Okunur yedek metin (sunucu `yardim` alanından kendi metnini kurar; eski web sürümü bunu düz metin olarak yükler).
            let metin = ["🆘 " + TelsizAgMetin.m(y.ihtiyac, dil: "tr"), "\(y.kisiSayisi) kişi", y.not].filter { !$0.isEmpty }.joined(separator: " · ")
            var o: [String: Any] = ["id": y.id, "kanal": "k0", "ad": y.ad, "olusturulduMs": y.t, "atlama": y.atlama, "sureMs": 0,
                                    "mime": Self.metinMime, "kendim": y.kendim, "sesBase64": "", "metin": metin,
                                    "yardim": ["tur": y.ihtiyac, "kisiSayisi": y.kisiSayisi, "not": y.not] as [String: Any]]
            if let a = y.enlem, let b = y.boylam { o["enlem"] = a; o["boylam"] = b }
            return o
        }
    }

    private var yardimKlasoru: URL {
        let u = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("walkie-talkie", isDirectory: true).appendingPathComponent("yardim", isDirectory: true)
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true, attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
        return u
    }

    fileprivate func yardimDiskeYaz(_ y: TelsizYardimKaydi) {
        guard let d = try? JSONEncoder().encode(y) else { return }
        try? d.write(to: yardimKlasoru.appendingPathComponent("\(y.id).json"), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    fileprivate func yardimDiskYukle() {
        let simdi = Self.simdiMs()
        let fm = FileManager.default
        guard let dosyalar = try? fm.contentsOfDirectory(at: yardimKlasoru, includingPropertiesForKeys: nil) else { return }
        for u in dosyalar where u.pathExtension == "json" {
            guard let d = try? Data(contentsOf: u), let y = try? JSONDecoder().decode(TelsizYardimKaydi.self, from: d) else { continue }
            if simdi - y.t >= TelsizAg.omurMs("yardim") { try? fm.removeItem(at: u); continue }
            yardimlar[y.id] = y
            agGorulen[y.id] = y.t + TelsizAg.omurMs("yardim")
        }
    }

    fileprivate func yardimBuda(_ simdi: Int64) {
        for (id, y) in yardimlar where simdi - y.t >= TelsizAg.omurMs("yardim") {
            yardimlar.removeValue(forKey: id)
            try? FileManager.default.removeItem(at: yardimKlasoru.appendingPathComponent("\(id).json"))
        }
        gidiyorumlar = gidiyorumlar.filter { simdi - $0.value.t < TelsizAg.omurMs("yardimaGidiyorum") }
    }

    // MARK: Bildirim

    private func agBildir(kimlik: String, baslik: String, govde: String, tur: String, id: String) {
        let c = UNMutableNotificationContent()
        c.title = baslik
        c.body = govde
        c.sound = .default
        c.threadIdentifier = "walkie-talkie"
        c.interruptionLevel = .timeSensitive
        c.userInfo = ["telsiz": tur, "id": id]
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: kimlik, content: c, trigger: nil), withCompletionHandler: nil)
    }

    /// Telsiz ilk açıldığında (ön planda) bildirim izni henüz sorulmadıysa sorulur — davet ve yardım çağrısı bildirimle gelir.
    fileprivate func bildirimIzniGerekirse() {
        UNUserNotificationCenter.current().getNotificationSettings { s in
            guard s.authorizationStatus == .notDetermined else { return }
            DispatchQueue.main.async {
                guard UIApplication.shared.applicationState == .active else { return }
                UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
            }
        }
    }

    /// Telsiz bildirimine dokunuldu (DisasterWalkieTalkie.bildirimeDokunuldu). Sayfa "bildirimeDokunuldu" olayıyla telsiz sekmesini açar.
    static func bildirimeDokunuldu(_ bilgi: [AnyHashable: Any]) -> Bool {
        guard let tur = bilgi["telsiz"] as? String else { return false }
        let id = (bilgi["id"] as? String) ?? ""
        DispatchQueue.main.async { TelsizMotoru.shared.olaylar.send(("bildirimeDokunuldu", ["tur": tur, "id": id])) }
        return true
    }
}
