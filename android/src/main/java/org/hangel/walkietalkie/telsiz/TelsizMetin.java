// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Uluslararası Sosyal Fayda Derneği (Social Business Global)
package org.hangel.walkietalkie.telsiz;

import java.util.Locale;

/**
 * Afet Telsizi Android ekranı metinleri — 11 dil (cihaz dili, yoksa Türkçe). iOS TelsizMetin (DisasterWalkieTalkiePlugin.swift)
 * ile aynı ifadeler; yalnız Android'e özgü olanlar (Bluetooth aç, izin, ana ekran) eklidir. İnternetsiz açıldığı için web
 * çevirilerine bağlı değildir. "{app}" yer tutucusu uygulamanın görünen adıyla değiştirilir.
 */
final class TelsizMetin {
    final String baslik, kapat, internetsiz, cevrimici, bagliTelefon, basKonus, kaydediliyor, mesajYok, sen, aktarim,
            ekranAcik, testPaneli, teslim, mikrofonIzni, gonderildi, metinIpucu, gonder, konumEkle, konumYok, konum,
            bluetoothKapali, bluetoothAc, bluetoothIzni, anaEkranaEkle, desteklenmiyor;

    /** Uygulamanın görünen adı (metinlerdeki "{app}" yerine). Motor ilk oluşturulurken Context'ten okunur (TelsizMotoru). */
    static volatile String uygulamaAdi = "app";

    private TelsizMetin(String... s) {
        for (int i = 0; i < s.length; i++) s[i] = s[i].replace("{app}", uygulamaAdi);
        baslik = s[0]; kapat = s[1]; internetsiz = s[2]; cevrimici = s[3]; bagliTelefon = s[4]; basKonus = s[5];
        kaydediliyor = s[6]; mesajYok = s[7]; sen = s[8]; aktarim = s[9]; ekranAcik = s[10]; testPaneli = s[11];
        teslim = s[12]; mikrofonIzni = s[13]; gonderildi = s[14]; metinIpucu = s[15]; gonder = s[16]; konumEkle = s[17];
        konumYok = s[18]; konum = s[19]; bluetoothKapali = s[20]; bluetoothAc = s[21]; bluetoothIzni = s[22];
        anaEkranaEkle = s[23]; desteklenmiyor = s[24];
    }

    static TelsizMetin simdiki() {
        String dil = Locale.getDefault().getLanguage();
        switch (dil) {
            case "en": return new TelsizMetin("Disaster Radio", "Close", "Offline", "Online", "phones connected", "Hold to talk", "Recording… release to send",
                    "No messages yet. Keep Bluetooth on; nearby phones with {app} (Android and iPhone) will appear here.", "You", "hops",
                    "Keep this screen open: the radio only works while it is open.", "Test panel", "delivery", "Microphone permission is needed (Settings › Apps › {app}).", "Sent to nearby phones",
                    "Write a short message…", "Send", "Add my location", "Couldn't get location; sent without it.", "Location",
                    "Bluetooth is off. Turn it on for offline radio.", "Turn on Bluetooth", "Nearby devices (Bluetooth) permission is needed to find nearby phones.",
                    "Add to home screen (to open offline)", "Offline radio isn't available on this phone (requires Android 9 or later).");
            case "ru": return new TelsizMetin("Рация при ЧС", "Закрыть", "Без интернета", "Онлайн", "телефонов рядом", "Удерживай и говори", "Запись… отпусти, чтобы отправить",
                    "Сообщений пока нет. Держи Bluetooth включённым — телефоны {app} рядом (Android и iPhone) появятся здесь.", "Ты", "перед.",
                    "Не закрывай этот экран: рация работает, только пока он открыт.", "Тестовая панель", "доставка", "Нужен доступ к микрофону (Настройки › Приложения › {app}).", "Отправлено телефонам рядом",
                    "Напиши короткое сообщение…", "Отправить", "Добавить моё местоположение", "Не удалось определить местоположение; отправлено без него.", "Местоположение",
                    "Bluetooth выключен. Включи его для рации без интернета.", "Включить Bluetooth", "Нужно разрешение «Устройства поблизости» (Bluetooth), чтобы находить телефоны рядом.",
                    "На главный экран (чтобы открыть без интернета)", "Рация без интернета недоступна на этом телефоне (нужен Android 9 или новее).");
            case "ar": return new TelsizMetin("لاسلكي الكوارث", "إغلاق", "دون إنترنت", "متصل", "هواتف متصلة", "اضغط مطولًا وتحدث", "جارٍ التسجيل… اترك للإرسال",
                    "لا رسائل بعد. أبقِ البلوتوث مفعّلًا، وستظهر هنا هواتف {app} القريبة (أندرويد وآيفون).", "أنت", "قفزات",
                    "أبقِ هذه الشاشة مفتوحة: يعمل اللاسلكي ما دامت مفتوحة فقط.", "لوحة الاختبار", "التسليم", "يلزم إذن الميكروفون (الإعدادات › التطبيقات › {app}).", "أُرسلت إلى الهواتف القريبة",
                    "اكتب رسالة قصيرة…", "إرسال", "أضف موقعي", "تعذّر تحديد الموقع؛ أُرسلت دونه.", "الموقع",
                    "البلوتوث مغلق. شغّله لاستخدام اللاسلكي دون إنترنت.", "تشغيل البلوتوث", "يلزم إذن الأجهزة القريبة (البلوتوث) للعثور على الهواتف القريبة.",
                    "أضف إلى الشاشة الرئيسية (للفتح دون إنترنت)", "اللاسلكي دون إنترنت غير متاح على هذا الهاتف (يتطلب أندرويد 9 أو أحدث).");
            case "fa": return new TelsizMetin("بی‌سیم بحران", "بستن", "آفلاین", "آنلاین", "گوشی متصل", "نگه دار و صحبت کن", "در حال ضبط… رها کن تا ارسال شود",
                    "هنوز پیامی نیست. بلوتوث روشن بماند؛ گوشی‌های نزدیک دارای {app} (اندروید و آیفون) اینجا دیده می‌شوند.", "تو", "انتقال",
                    "این صفحه را باز نگه دار: بی‌سیم فقط وقتی باز است کار می‌کند.", "پنل آزمایش", "تحویل", "اجازهٔ میکروفون لازم است (تنظیمات › برنامه‌ها › {app}).", "به گوشی‌های نزدیک ارسال شد",
                    "یک پیام کوتاه بنویس…", "ارسال", "موقعیتم را اضافه کن", "موقعیت پیدا نشد؛ بدون آن ارسال شد.", "موقعیت",
                    "بلوتوث خاموش است. برای بی‌سیم آفلاین روشنش کن.", "روشن کردن بلوتوث", "برای پیدا کردن گوشی‌های نزدیک، اجازهٔ دستگاه‌های نزدیک (بلوتوث) لازم است.",
                    "افزودن به صفحهٔ اصلی (برای باز کردن بدون اینترنت)", "بی‌سیم آفلاین روی این گوشی کار نمی‌کند (اندروید ۹ یا بالاتر لازم است).");
            case "es": return new TelsizMetin("Radio de emergencias", "Cerrar", "Sin conexión", "En línea", "teléfonos conectados", "Mantén pulsado para hablar", "Grabando… suelta para enviar",
                    "Aún no hay mensajes. Deja el Bluetooth activado; los teléfonos cercanos con {app} (Android y iPhone) aparecerán aquí.", "Tú", "saltos",
                    "Mantén esta pantalla abierta: la radio solo funciona mientras está abierta.", "Panel de prueba", "entrega", "Se necesita permiso de micrófono (Ajustes › Aplicaciones › {app}).", "Enviado a teléfonos cercanos",
                    "Escribe un mensaje corto…", "Enviar", "Añadir mi ubicación", "No se pudo obtener la ubicación; se envió sin ella.", "Ubicación",
                    "El Bluetooth está desactivado. Actívalo para la radio sin conexión.", "Activar Bluetooth", "Se necesita el permiso de dispositivos cercanos (Bluetooth) para encontrar teléfonos cercanos.",
                    "Añadir a la pantalla de inicio (para abrir sin conexión)", "La radio sin conexión no está disponible en este teléfono (requiere Android 9 o posterior).");
            case "ha": return new TelsizMetin("Rediyon Bala'i", "Rufe", "Babu intanet", "A kan layi", "wayoyi a haɗe", "Riƙe ka yi magana", "Ana ɗauka… saki don aikawa",
                    "Babu saƙo tukuna. Bar Bluetooth a kunne; wayoyin {app} na kusa (Android da iPhone) za su bayyana nan.", "Kai", "miƙa",
                    "Bar wannan allon a buɗe: rediyon yana aiki ne kawai idan a buɗe yake.", "Allon gwaji", "isarwa", "Ana buƙatar izinin makirofo (Saituna › Manhajoji › {app}).", "An aika ga wayoyin kusa",
                    "Rubuta gajeren saƙo…", "Aika", "Ƙara wurin da nake", "Ba a samu wuri ba; an aika ba tare da shi ba.", "Wuri",
                    "Bluetooth a kashe yake. Kunna shi don rediyo babu intanet.", "Kunna Bluetooth", "Ana buƙatar izinin na'urori na kusa (Bluetooth) don nemo wayoyin kusa.",
                    "Ƙara a allon gida (don buɗewa babu intanet)", "Rediyo babu intanet ba ya aiki a wannan waya (sai Android 9 ko sama).");
            case "de": return new TelsizMetin("Katastrophenfunk", "Schließen", "Offline", "Online", "Handys verbunden", "Gedrückt halten und sprechen", "Aufnahme… zum Senden loslassen",
                    "Noch keine Nachrichten. Bluetooth eingeschaltet lassen – {app}-Handys in der Nähe (Android und iPhone) erscheinen hier.", "Du", "Weiterl.",
                    "Diesen Bildschirm offen lassen: Der Funk arbeitet nur, solange er geöffnet ist.", "Testpanel", "Zustellung", "Mikrofonzugriff nötig (Einstellungen › Apps › {app}).", "An Handys in der Nähe gesendet",
                    "Kurze Nachricht schreiben…", "Senden", "Meinen Standort anhängen", "Standort nicht verfügbar; ohne Standort gesendet.", "Standort",
                    "Bluetooth ist aus. Für Offline-Funk einschalten.", "Bluetooth einschalten", "Die Berechtigung „Geräte in der Nähe“ (Bluetooth) wird benötigt, um Handys in der Nähe zu finden.",
                    "Zum Startbildschirm (offline öffnen)", "Offline-Funk ist auf diesem Handy nicht verfügbar (Android 9 oder neuer nötig).");
            case "hu": return new TelsizMetin("Katasztrófarádió", "Bezárás", "Offline", "Online", "telefon csatlakozva", "Tartsd lenyomva és beszélj", "Felvétel… engedd el a küldéshez",
                    "Még nincs üzenet. Hagyd bekapcsolva a Bluetooth-t; a közeli {app}es telefonok (Android és iPhone) itt jelennek meg.", "Te", "továbbítás",
                    "Hagyd nyitva ezt a képernyőt: a rádió csak addig működik, amíg nyitva van.", "Tesztpanel", "kézbesítés", "Mikrofon-engedély kell (Beállítások › Alkalmazások › {app}).", "Elküldve a közeli telefonoknak",
                    "Írj egy rövid üzenetet…", "Küldés", "Helyzetem hozzáadása", "Nem sikerült helyzetet kérni; nélküle küldtük el.", "Helyzet",
                    "A Bluetooth ki van kapcsolva. Kapcsold be az offline rádióhoz.", "Bluetooth bekapcsolása", "A közeli telefonok megtalálásához „Közeli eszközök” (Bluetooth) engedély kell.",
                    "Kezdőképernyőre (offline megnyitáshoz)", "Ezen a telefonon nem működik az offline rádió (Android 9 vagy újabb kell).");
            case "fr": return new TelsizMetin("Radio de crise", "Fermer", "Hors ligne", "En ligne", "téléphones connectés", "Maintiens pour parler", "Enregistrement… relâche pour envoyer",
                    "Aucun message. Garde le Bluetooth activé ; les téléphones {app} proches (Android et iPhone) apparaîtront ici.", "Toi", "relais",
                    "Garde cet écran ouvert : la radio ne fonctionne que tant qu'il est ouvert.", "Panneau de test", "livraison", "Autorisation du micro nécessaire (Paramètres › Applications › {app}).", "Envoyé aux téléphones proches",
                    "Écris un court message…", "Envoyer", "Ajouter ma position", "Position indisponible ; envoyé sans elle.", "Position",
                    "Le Bluetooth est désactivé. Active-le pour la radio hors ligne.", "Activer le Bluetooth", "L'autorisation Appareils à proximité (Bluetooth) est nécessaire pour trouver les téléphones proches.",
                    "Ajouter à l'écran d'accueil (ouvrir hors ligne)", "La radio hors ligne n'est pas disponible sur ce téléphone (Android 9 ou plus requis).");
            case "az": return new TelsizMetin("Fəlakət Ratsiyası", "Bağla", "İnternetsiz", "Onlayn", "telefon qoşulub", "Basılı saxla və danış", "Yazılır… göndərmək üçün burax",
                    "Hələ mesaj yoxdur. Bluetooth açıq qalsın; yaxındakı {app}-li telefonlar (Android və iPhone) burada görünəcək.", "Sən", "ötürmə",
                    "Bu ekranı açıq saxla: ratsiya yalnız ekran açıq olanda işləyir.", "Test paneli", "çatdırılma", "Mikrofon icazəsi lazımdır (Ayarlar › Tətbiqlər › {app}).", "Yaxındakı telefonlara göndərildi",
                    "Qısa mesaj yaz…", "Göndər", "Məkanımı əlavə et", "Məkan alınmadı; mesaj məkansız göndərildi.", "Məkan",
                    "Bluetooth bağlıdır. İnternetsiz ratsiya üçün Bluetooth-u aç.", "Bluetooth-u aç", "Yaxındakı telefonları tapmaq üçün Yaxındakı cihazlar (Bluetooth) icazəsi lazımdır.",
                    "Ana ekrana əlavə et (internetsiz açmaq üçün)", "Bu telefonda internetsiz ratsiya işləmir (Android 9 və ya yuxarı lazımdır).");
            case "da": return new TelsizMetin("Katastroferadio", "Luk", "Offline", "Online", "telefoner forbundet", "Hold nede for at tale", "Optager… slip for at sende",
                    "Ingen beskeder endnu. Lad Bluetooth være tændt; telefoner i nærheden med {app} (Android og iPhone) vises her.", "Dig", "hop",
                    "Hold denne skærm åben: radioen virker kun, mens den er åben.", "Testpanel", "levering", "Der kræves tilladelse til mikrofonen (Indstillinger › Apps › {app}).", "Sendt til telefoner i nærheden",
                    "Skriv en kort besked…", "Send", "Tilføj min placering", "Placeringen kunne ikke hentes; beskeden blev sendt uden.", "Sted",
                    "Bluetooth er slået fra. Slå det til for at bruge offlineradioen.", "Slå Bluetooth til", "Der kræves tilladelse til enheder i nærheden (Bluetooth) for at finde telefoner i nærheden.",
                    "Føj til startskærmen (for at åbne offline)", "Offlineradioen er ikke tilgængelig på denne telefon (kræver Android 9 eller nyere).");
            default: return new TelsizMetin("Afet Telsizi", "Kapat", "İnternetsiz", "Çevrimiçi", "telefon bağlı", "Basılı tut ve konuş", "Kaydediliyor… göndermek için bırak",
                    "Henüz mesaj yok. Bluetooth açık kalsın; yakındaki {app}'li telefonlar (Android ve iPhone) burada görünür.", "Sen", "aktarım",
                    "Bu ekran açık kalsın: telsiz yalnız bu ekran açıkken çalışır.", "Test paneli", "teslim", "Mikrofon izni gerekli (Ayarlar › Uygulamalar › {app}).", "Yakındaki telefonlara gönderildi",
                    "Kısa mesaj yaz…", "Gönder", "Konumumu ekle", "Konum alınamadı; mesaj konumsuz gönderildi.", "Konum",
                    "Bluetooth kapalı. İnternetsiz telsiz için Bluetooth'u aç.", "Bluetooth'u aç", "Yakındaki telefonları bulmak için Yakındaki cihazlar (Bluetooth) izni gerekli.",
                    "Ana ekrana ekle (internetsiz açmak için)", "Bu telefonda internetsiz telsiz çalışmaz (Android 9 ve üstü gerekir).");
        }
    }
}
