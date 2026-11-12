// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Uluslararası Sosyal Fayda Derneği (Social Business Global)
package org.hangel.walkietalkie.telsiz;

import android.Manifest;
import android.app.NotificationChannel;
import android.app.NotificationManager;
import android.app.PendingIntent;
import android.content.Context;
import android.content.Intent;
import android.content.SharedPreferences;
import android.content.pm.PackageManager;
import android.media.MediaPlayer;
import android.media.MediaRecorder;
import android.net.ConnectivityManager;
import android.net.Network;
import android.net.NetworkCapabilities;
import android.os.BatteryManager;
import android.os.Build;
import android.os.Handler;
import android.os.HandlerThread;
import android.os.Looper;
import android.os.SystemClock;
import android.os.VibrationEffect;
import android.os.Vibrator;
import android.util.Base64;
import android.util.Log;

import androidx.core.app.NotificationCompat;
import androidx.core.content.ContextCompat;

import org.json.JSONArray;
import org.json.JSONObject;

import java.io.File;
import java.io.FileInputStream;
import java.io.FileOutputStream;
import java.nio.charset.StandardCharsets;
import java.util.ArrayList;
import java.util.Collections;
import java.util.HashMap;
import java.util.List;
import java.util.Map;
import java.util.UUID;
import java.util.concurrent.CopyOnWriteArrayList;
import java.util.regex.Pattern;

/**
 * Afet Telsizi motoru (Android, 2026-11-05) — iOS TelsizMotoru (DisasterWalkieTalkiePlugin.swift) ile aynı kurallar:
 * tekilleştirme (mesaj kimliği), en çok 12 aktarım, pil %20 altında aktarmaz, 72 saat ömür, kanal anahtarıyla şifreli içerik.
 * Taşıma Bluetooth LE (TelsizBle; iPhone + Android) ve 2026-11-07'den beri Android ↔ Android için ek olarak Nearby Connections
 * (TelsizYakin; BLE ile kurar, Wi-Fi'ye yükseltir — iOS'taki Wi-Fi Aware ek taşımasının karşılığı; açık kaynak sürümde İSTEĞE
 * BAĞLI, bkz. EkTasima). Mesajlar: 30 sn'ye kadar sesli bas-konuş ya da kısa metin (+ isteğe bağlı konum).
 * İnternet gelince web (uygulama sayfası) bekleyenler() ile kuyruğu alır, uygulamanın kendi sunucusu'e yükler, yuklendi() ile işaretler.
 * Durum yalnız motorun iş parçacığında (h) değişir; ekran dinleyici ile ana iş parçacığında yenilenir.
 */
public final class TelsizMotoru implements TelsizBle.Olaylar {
    private static final String ETIKET = "WalkieTalkie";
    public static final int MAKS_ATLAMA = 12;
    public static final long OMUR_MS = 72L * 3600 * 1000;
    public static final long DUYURU_OMUR_MS = 3L * 3600 * 1000;
    public static final int MAKS_SURE_MS = 30_000;
    public static final String METIN_MIME = "text/plain";
    public static final int MAKS_METIN = 280;
    static final int GECMIS_MAKS = 30;
    static final int GECMIS_SES = 3;
    private static final Pattern KIMLIK = Pattern.compile("^[A-Za-z0-9_-]{8,64}$");
    private static final String TERCIH = "disaster_walkie_talkie";

    public interface Dinleyici {
        void degisti();
    }

    /** Saklanan mesaj (iOS TelsizMesaj ile aynı alanlar). */
    public static final class Mesaj {
        public String id, kanal, mime, veri;
        public long t, alindiMs;
        public int atlama, sure;
        public boolean kendim, yuklendi;

        JSONObject kablo() throws Exception {
            return new JSONObject().put("v", 1).put("id", id).put("kanal", kanal).put("t", t).put("atlama", atlama)
                    .put("sure", sure).put("mime", mime).put("veri", veri);
        }

        JSONObject disk() throws Exception {
            return kablo().put("alindiMs", alindiMs).put("kendim", kendim).put("yuklendi", yuklendi);
        }

        static Mesaj diskten(JSONObject o) {
            Mesaj m = new Mesaj();
            m.id = o.optString("id");
            m.kanal = o.optString("kanal");
            m.t = o.optLong("t");
            m.atlama = o.optInt("atlama");
            m.sure = o.optInt("sure");
            m.mime = o.optString("mime");
            m.veri = o.optString("veri");
            m.alindiMs = o.optLong("alindiMs");
            m.kendim = o.optBoolean("kendim");
            m.yuklendi = o.optBoolean("yuklendi");
            return m;
        }
    }

    /** Çözülmüş içerik. */
    public static final class Icerik {
        public String ad = "", metin;
        public byte[] ses;
        public Double enlem, boylam;
        /** 2026-11-08 (Yakın ağ): "guvende" | "toplanma" | "yardim" ve cihaza özgü rastgele kişi kodu (sayım için); yoksa null. */
        public String durum, kisi;
    }

    // ─── Yakın ağ durum mesajları (2026-11-08) — src/protocol/frame.ts DURUMLAR / DURUM_OMRU_MS / kisiGecerli ile aynı ───
    public static final long DURUM_OMRU_MS = 12L * 3600 * 1000;
    private static final Pattern KISI = Pattern.compile("^[a-z0-9]{8,16}$");

    private static boolean durumGecerli(String d) {
        return "guvende".equals(d) || "toplanma".equals(d) || "yardim".equals(d);
    }

    /** {guvende, toplanma, yardim}: geçerli kanalda son 12 saatte her kişi kodunun SON durumu. yayinla() her değişimde yeniler. */
    private volatile int[] durumOzet = new int[] { 0, 0, 0 };

    public int[] durumOzeti() { return durumOzet; }

    private String kisiKodu() {
        SharedPreferences p = ctx.getSharedPreferences(TERCIH, Context.MODE_PRIVATE);
        String k = p.getString("kisi", null);
        if (k != null && KISI.matcher(k).matches()) return k;
        k = UUID.randomUUID().toString().replace("-", "").toLowerCase(java.util.Locale.ROOT).substring(0, 12);
        p.edit().putString("kisi", k).apply();
        return k;
    }

    private static TelsizMotoru tek;

    public static synchronized TelsizMotoru al(Context ctx) {
        if (tek == null) tek = new TelsizMotoru(ctx.getApplicationContext());
        return tek;
    }

    private final Context ctx;
    private final Handler h;
    private final Handler ana = new Handler(Looper.getMainLooper());
    private final TelsizBle ble;
    /** İsteğe bağlı ek taşıma (varsayılan derlemede boş; bkz. EkTasima). */
    private final EkTasima yakin;
    private final Map<String, Mesaj> tumu = new HashMap<>();
    private final Map<String, JSONObject> duyurular = new HashMap<>();
    private final List<Dinleyici> dinleyiciler = new CopyOnWriteArrayList<>();

    private volatile List<Mesaj> kanalListesi = new ArrayList<>();
    private volatile List<String> baglilar = new ArrayList<>();
    private volatile List<String> bleBaglilar = new ArrayList<>();
    private volatile List<String> yakinBaglilar = new ArrayList<>();
    private volatile boolean kayitta;
    private volatile String calanId;
    private volatile String bilgi;

    private String kanal = "test", kanalAdi = "", ad = "";
    /** 2026-11-05 (tek ekran): web sayfası çalmayı kendisi yönetir → yerel otomatik çalma kapalı (birak() ile geri açılır). */
    public volatile boolean otomatikCal = true;
    private boolean testPaneli;

    private MediaRecorder kayitci;
    private File kayitDosyasi;
    private long kayitBaslangic;
    private MediaPlayer calici;
    private final List<Mesaj> calKuyrugu = new ArrayList<>();

    private TelsizMotoru(Context ctx) {
        this.ctx = ctx;
        HandlerThread t = new HandlerThread("walkie-talkie");
        t.start();
        h = new Handler(t.getLooper());
        ble = new TelsizBle(ctx, h, this);
        try {
            TelsizMetin.uygulamaAdi = ctx.getApplicationInfo().loadLabel(ctx.getPackageManager()).toString();
        } catch (Exception ignored) { }
        yakin = EkTasimaFabrikasi.olustur(ctx, h, new TelsizBle.Olaylar() {
            @Override public void yukAlindi(String baglanti, byte[] yuk) { TelsizMotoru.this.yukAlindi(baglanti, yuk); }
            @Override public void yeniBaglanti(String baglanti) { yakinYeniBaglanti(baglanti); }
            @Override public void baglantilarDegisti(List<String> adlar) {
                yakinBaglilar = adlar;
                baglilariBirlestir();
            }
        });
        h.post(() -> {
            tercihleriOku();
            diskYukle();
            yayinla();
        });
    }

    /** Ek taşımanın istediği ek izinler (varsayılan derlemede yok; Nearby derlemesinde Android 13+ NEARBY_WIFI_DEVICES). */
    public static String[] ekIzinler() {
        return EkTasimaFabrikasi.ekIzinler();
    }

    public static boolean destekleniyor(Context ctx) {
        return TelsizSifre.destekleniyor() && ctx.getPackageManager().hasSystemFeature(PackageManager.FEATURE_BLUETOOTH_LE);
    }

    // MARK: Ayarlar

    private void tercihleriOku() {
        SharedPreferences p = ctx.getSharedPreferences(TERCIH, Context.MODE_PRIVATE);
        kanal = p.getString("kanal", "test");
        kanalAdi = p.getString("kanalAdi", "");
        ad = p.getString("ad", "");
        testPaneli = p.getBoolean("testPaneli", false);
    }

    public void ayarla(String k, String kAdi, String a, Boolean sa) {
        h.post(() -> {
            SharedPreferences.Editor e = ctx.getSharedPreferences(TERCIH, Context.MODE_PRIVATE).edit();
            if (k != null && !k.isEmpty() && k.length() <= 64) e.putString("kanal", k);
            if (kAdi != null) e.putString("kanalAdi", kAdi);
            if (a != null && !a.isEmpty()) e.putString("ad", a);
            if (sa != null) e.putBoolean("testPaneli", sa);
            e.apply();
            tercihleriOku();
            yayinla();
        });
    }

    public String kanalGorunen() {
        return kanalAdi.isEmpty() ? kanal : kanalAdi;
    }

    public boolean testPaneliMi() {
        return testPaneli;
    }

    // MARK: Dinleyiciler / durum

    public void dinle(Dinleyici d) { dinleyiciler.add(d); }
    public void birak(Dinleyici d) { dinleyiciler.remove(d); }
    public List<Mesaj> mesajlar() { return kanalListesi; }
    public List<String> baglilar() { return baglilar; }
    public boolean kayittaMi() { return kayitta; }
    public String calan() { return calanId; }
    public String bilgi() { return bilgi; }
    public boolean bluetoothAcik() { return ble.bluetoothAcik(); }

    public boolean internetVar() {
        try {
            ConnectivityManager cm = (ConnectivityManager) ctx.getSystemService(Context.CONNECTIVITY_SERVICE);
            Network n = cm == null ? null : cm.getActiveNetwork();
            NetworkCapabilities c = n == null ? null : cm.getNetworkCapabilities(n);
            return c != null && c.hasCapability(NetworkCapabilities.NET_CAPABILITY_VALIDATED);
        } catch (Exception e) {
            return false;
        }
    }

    private void degisti() {
        ana.post(() -> { for (Dinleyici d : dinleyiciler) d.degisti(); });
    }

    private void yayinla() {
        List<Mesaj> l = new ArrayList<>();
        for (Mesaj m : tumu.values()) if (kanal.equals(m.kanal)) l.add(m);
        Collections.sort(l, (a, b) -> Long.compare(b.t, a.t));
        durumOzetiniYenile(l);
        kanalListesi = l.size() > 50 ? new ArrayList<>(l.subList(0, 50)) : l;
        degisti();
    }

    /** Geçerli kanalın (tüm) metin mesajlarından durum özeti: her kişi kodunun SON durumu sayılır. */
    private void durumOzetiniYenile(List<Mesaj> kanalMesajlari) {
        long simdi = System.currentTimeMillis();
        Map<String, Object[]> son = new HashMap<>();
        for (Mesaj m : kanalMesajlari) {
            if (!METIN_MIME.equals(m.mime) || simdi - m.t >= DURUM_OMRU_MS) continue;
            Icerik i = coz(m);
            if (i == null || i.durum == null || i.kisi == null) continue;
            Object[] o = son.get(i.kisi);
            if (o != null && (Long) o[0] >= m.t) continue;
            son.put(i.kisi, new Object[] { m.t, i.durum });
        }
        int[] ozet = new int[3];
        for (Object[] v : son.values()) {
            String d = (String) v[1];
            if ("guvende".equals(d)) ozet[0]++; else if ("toplanma".equals(d)) ozet[1]++; else ozet[2]++;
        }
        durumOzet = ozet;
    }

    public void bilgiVer(String s) {
        bilgi = s;
        degisti();
    }

    // MARK: Bağlantı

    /** Bluetooth kapalı ya da izin yoksa false (ekran uyarı gösterir). */
    public void baslat(Runnable sonuc) {
        h.post(() -> {
            boolean ok = ble.baslat();
            yakin.baslat();
            if (sonuc != null) ana.post(sonuc);
            if (!ok) degisti();
        });
    }

    public void durdur() {
        h.post(() -> {
            ble.durdur();
            yakin.durdur();
        });
    }

    public boolean calisiyor() {
        return ble.calisiyorMu() || yakin.calisiyorMu();
    }

    @Override public void baglantilarDegisti(List<String> adlar) {
        bleBaglilar = adlar;
        baglilariBirlestir();
    }

    private void baglilariBirlestir() {
        List<String> l = new ArrayList<>(bleBaglilar);
        l.addAll(yakinBaglilar);
        baglilar = l;
        degisti();
    }

    /** Mesajı bütün yollara verir (BLE + Nearby); haric = mesajın geldiği bağlantı (oraya geri gönderilmez). */
    private void herYere(byte[] yuk, String haric) {
        ble.gonder(yuk, haric);
        yakin.gonder(yuk, haric);
    }

    /**
     * Nearby ile yeni bağlanan Android: yol hızlıdır → (iOS ek taşıması gibi) son 72 saatin en çok 30 mesajı, sesler dahil,
     * ve süren duyurular.
     */
    private void yakinYeniBaglanti(String baglanti) {
        long simdi = System.currentTimeMillis();
        List<Mesaj> uygun = new ArrayList<>();
        for (Mesaj m : tumu.values()) if (simdi - m.t < OMUR_MS && m.atlama < MAKS_ATLAMA) uygun.add(m);
        Collections.sort(uygun, (a, b) -> Long.compare(b.t, a.t));
        int n = 0;
        for (Mesaj m : uygun) {
            try {
                yakin.gonderKime(baglanti, m.kablo().toString().getBytes(StandardCharsets.UTF_8));
            } catch (Exception ignored) { }
            if (++n >= GECMIS_MAKS) break;
        }
        for (JSONObject d : duyurular.values()) {
            if (simdi - d.optLong("t") < DUYURU_OMUR_MS && d.optInt("atlama") < MAKS_ATLAMA) {
                yakin.gonderKime(baglanti, d.toString().getBytes(StandardCharsets.UTF_8));
            }
        }
    }

    @Override public void yeniBaglanti(String baglanti) {
        // Bluetooth yavaştır: metinlerin hepsi + en yeni 3 ses (src/protocol/frame.ts bleGecmisi).
        long simdi = System.currentTimeMillis();
        List<Mesaj> uygun = new ArrayList<>();
        for (Mesaj m : tumu.values()) if (simdi - m.t < OMUR_MS && m.atlama < MAKS_ATLAMA) uygun.add(m);
        Collections.sort(uygun, (a, b) -> Long.compare(b.t, a.t));
        int ses = 0, n = 0;
        for (Mesaj m : uygun) {
            boolean metin = METIN_MIME.equals(m.mime);
            if (!metin) {
                if (ses >= GECMIS_SES) continue;
                ses++;
            }
            try {
                ble.gonderKime(baglanti, m.kablo().toString().getBytes(StandardCharsets.UTF_8));
            } catch (Exception ignored) { }
            if (++n >= GECMIS_MAKS) break;
        }
        for (JSONObject d : duyurular.values()) {
            if (simdi - d.optLong("t") < DUYURU_OMUR_MS && d.optInt("atlama") < MAKS_ATLAMA) {
                ble.gonderKime(baglanti, d.toString().getBytes(StandardCharsets.UTF_8));
            }
        }
    }

    @Override public void yukAlindi(String baglanti, byte[] yuk) {
        JSONObject o;
        try {
            o = new JSONObject(new String(yuk, StandardCharsets.UTF_8));
        } catch (Exception e) {
            return;
        }
        int v = o.optInt("v", 0);
        if (v == 2 && "duyuru".equals(o.optString("tur"))) {
            duyuruAl(o, baglanti);
            return;
        }
        if (v != 1) return;
        String id = o.optString("id", "");
        long simdi = System.currentTimeMillis();
        long t = o.optLong("t", 0);
        int atlama = o.optInt("atlama", -1);
        if (!KIMLIK.matcher(id).matches() || simdi - t >= OMUR_MS || t > simdi + 5 * 60_000 || atlama < 0 || atlama > MAKS_ATLAMA) return;
        if (tumu.containsKey(id)) return;
        String k = o.optString("kanal", "");
        if (k.isEmpty() || k.length() > 64) return;
        // src/protocol/frame.ts kabloDogrula ve Swift TelsizKablo: mime ve veri metin olmalı (eksikse ağa yayılmaz).
        if (!(o.opt("mime") instanceof String) || !(o.opt("veri") instanceof String)) return;
        Mesaj m = new Mesaj();
        m.id = id;
        m.kanal = k;
        m.t = t;
        m.atlama = atlama + 1;
        m.sure = Math.max(0, Math.min(MAKS_SURE_MS, o.optInt("sure", 0)));
        m.mime = o.optString("mime", "");
        m.veri = o.optString("veri", "");
        m.alindiMs = simdi;
        tumu.put(id, m);
        diskeYaz(m);
        yayinla();
        if (m.atlama < MAKS_ATLAMA && pilYeterli()) {
            try {
                herYere(m.kablo().toString().getBytes(StandardCharsets.UTF_8), baglanti);
            } catch (Exception ignored) { }
        }
        if (kanal.equals(m.kanal)) {
            if (METIN_MIME.equals(m.mime)) {
                titret(60);
            } else if (otomatikCal) {
                ana.post(() -> { calKuyrugu.add(m); siradakiniCal(); });
            }
        }
    }

    private boolean pilYeterli() {
        try {
            BatteryManager b = (BatteryManager) ctx.getSystemService(Context.BATTERY_SERVICE);
            int y = b == null ? -1 : b.getIntProperty(BatteryManager.BATTERY_PROPERTY_CAPACITY);
            return y <= 0 || y >= 20;
        } catch (Exception e) {
            return true;
        }
    }

    // MARK: Şifre

    private static String sifrele(String ad, byte[] ses, String metin, Double enlem, Double boylam, String kanal) throws Exception {
        return sifrele(ad, ses, metin, enlem, boylam, kanal, null, null);
    }

    private static String sifrele(String ad, byte[] ses, String metin, Double enlem, Double boylam, String kanal, String durum, String kisi) throws Exception {
        JSONObject ic = new JSONObject().put("ad", ad).put("ses", ses == null ? "" : Base64.encodeToString(ses, Base64.NO_WRAP));
        if (metin != null) ic.put("metin", metin);
        if (enlem != null && boylam != null) ic.put("enlem", enlem).put("boylam", boylam);
        if (durum != null && kisi != null) ic.put("durum", durum).put("kisi", kisi);
        byte[] kutu = TelsizSifre.sifrele(ic.toString().getBytes(StandardCharsets.UTF_8), kanal);
        return Base64.encodeToString(kutu, Base64.NO_WRAP);
    }

    public static Icerik coz(Mesaj m) {
        try {
            byte[] acik = TelsizSifre.ac(Base64.decode(m.veri, Base64.DEFAULT), m.kanal);
            if (acik == null) return null;
            JSONObject o = new JSONObject(new String(acik, StandardCharsets.UTF_8));
            Icerik i = new Icerik();
            i.ad = o.optString("ad", "");
            String s = o.optString("ses", "");
            i.ses = s.isEmpty() ? null : Base64.decode(s, Base64.DEFAULT);
            if (o.has("metin")) i.metin = o.optString("metin", null);
            if (o.has("enlem") && o.has("boylam")) {
                double a = o.optDouble("enlem"), b = o.optDouble("boylam");
                if (!Double.isNaN(a) && !Double.isNaN(b) && Math.abs(a) <= 90 && Math.abs(b) <= 180) { i.enlem = a; i.boylam = b; }
            }
            String d = o.optString("durum", ""), k = o.optString("kisi", "");
            if (durumGecerli(d) && KISI.matcher(k).matches()) { i.durum = d; i.kisi = k; }
            return i;
        } catch (Exception e) {
            return null;
        }
    }

    // MARK: Gönderme

    private static String yeniKimlik() {
        return UUID.randomUUID().toString().replace("-", "").toLowerCase(java.util.Locale.ROOT);
    }

    private void kendiMesajim(String mime, int sure, String veri) {
        long simdi = System.currentTimeMillis();
        Mesaj m = new Mesaj();
        m.id = yeniKimlik();
        m.kanal = kanal;
        m.t = simdi;
        m.atlama = 0;
        m.sure = sure;
        m.mime = mime;
        m.veri = veri;
        m.alindiMs = simdi;
        m.kendim = true;
        tumu.put(m.id, m);
        diskeYaz(m);
        yayinla();
        try {
            herYere(m.kablo().toString().getBytes(StandardCharsets.UTF_8), null);
        } catch (Exception ignored) { }
        bilgiVer(TelsizMetin.simdiki().gonderildi);
    }

    /** Metin (+ isteğe bağlı konum) gönderir. Konum ~1 m'ye yuvarlanır; yalnız kullanıcı "Konumumu ekle" derse eklenir. */
    public void metinGonder(String metin, Double enlem, Double boylam) {
        String t = metinTemizle(metin);
        if (t == null) return;
        h.post(() -> {
            try {
                Double a = enlem == null ? null : Math.round(enlem * 1e5) / 1e5;
                Double b = boylam == null ? null : Math.round(boylam * 1e5) / 1e5;
                kendiMesajim(METIN_MIME, 0, sifrele(ad, null, t, a, b, kanal));
            } catch (Exception e) {
                Log.w(ETIKET, "metin gönderilemedi", e);
            }
        });
    }

    /** 2026-11-08 (Yakın ağ): "Güvendeyim" / "Toplanma alanındayım" / "Yardım lazım". `metin` web'in kullanıcı dilinde verdiği okunur
     *  cümledir (eski derlemeler bunu düz metin gösterir). Konum yalnız verilirse eklenir (kullanıcı "Konumumu ekle" demiştir). */
    public void durumGonder(String durum, String metin, Double enlem, Double boylam) {
        String t = metinTemizle(metin);
        if (t == null || !durumGecerli(durum)) return;
        h.post(() -> {
            try {
                Double a = enlem == null ? null : Math.round(enlem * 1e5) / 1e5;
                Double b = boylam == null ? null : Math.round(boylam * 1e5) / 1e5;
                kendiMesajim(METIN_MIME, 0, sifrele(ad, null, t, a, b, kanal, durum, kisiKodu()));
            } catch (Exception e) {
                Log.w(ETIKET, "durum gönderilemedi", e);
            }
        });
    }

    static String metinTemizle(String m) {
        if (m == null) return null;
        StringBuilder s = new StringBuilder();
        m.codePoints().filter(c -> c == '\n' || c >= 32).forEach(s::appendCodePoint);
        // JS trim() ile aynı kırpma (String.trim yalnız ≤ U+0020'yi atar; U+00A0, U+3000, U+FEFF, U+2028… kalıyordu).
        String ham = s.toString();
        int bas = 0, son = ham.length();
        while (bas < son && bosluk(ham.codePointAt(bas))) bas += Character.charCount(ham.codePointAt(bas));
        while (son > bas && bosluk(ham.codePointBefore(son))) son -= Character.charCount(ham.codePointBefore(son));
        String t = ham.substring(bas, son);
        if (t.isEmpty()) return null;
        int n = t.codePointCount(0, t.length());
        return n <= MAKS_METIN ? t : t.substring(0, t.offsetByCodePoints(0, MAKS_METIN));
    }

    /** JS WhiteSpace + LineTerminator (denetim karakterleri metinTemizle'de zaten atılır): Zs, U+FEFF, \n, U+2028, U+2029. */
    private static boolean bosluk(int c) {
        return c == '\n' || c == 0xFEFF || c == 0x2028 || c == 0x2029 || Character.getType(c) == Character.SPACE_SEPARATOR;
    }

    /** En çok n kod noktası; vekil çifti (emoji) ortadan bölünmez (bölünürse UTF-8'de "?" olur). */
    private static String kes(String s, int n) {
        return s.codePointCount(0, s.length()) <= n ? s : s.substring(0, s.offsetByCodePoints(0, n));
    }

    // MARK: Kayıt / çalma (ana iş parçacığı)

    @SuppressWarnings("deprecation")
    public void kayitBaslat() {
        if (kayitta) return;
        if (ContextCompat.checkSelfPermission(ctx, Manifest.permission.RECORD_AUDIO) != PackageManager.PERMISSION_GRANTED) {
            bilgiVer(TelsizMetin.simdiki().mikrofonIzni);
            return;
        }
        if (calici != null) { calici.stop(); calici.release(); calici = null; calanId = null; }
        MediaRecorder r = null;
        try {
            kayitDosyasi = new File(ctx.getCacheDir(), "telsiz-" + yeniKimlik() + ".m4a");
            r = Build.VERSION.SDK_INT >= 31 ? new MediaRecorder(ctx) : new MediaRecorder();
            r.setAudioSource(MediaRecorder.AudioSource.MIC);
            r.setOutputFormat(MediaRecorder.OutputFormat.MPEG_4);
            r.setAudioEncoder(MediaRecorder.AudioEncoder.AAC);
            r.setAudioChannels(1);
            r.setAudioSamplingRate(16_000);
            r.setAudioEncodingBitRate(24_000);
            r.setMaxDuration(MAKS_SURE_MS);
            r.setOutputFile(kayitDosyasi.getAbsolutePath());
            r.setOnInfoListener((mr, what, extra) -> {
                if (what == MediaRecorder.MEDIA_RECORDER_INFO_MAX_DURATION_REACHED) kayitBitir();
            });
            r.prepare();
            r.start();
            kayitci = r;
            kayitBaslangic = SystemClock.elapsedRealtime();
            kayitta = true;
            titret(40);
            degisti();
        } catch (Exception e) {
            Log.w(ETIKET, "kayıt başlamadı", e);
            // prepare/start atarsa kaydedici (mikrofon) ve boş dosya bırakılmasın.
            if (r != null) { try { r.release(); } catch (Exception ignored) { } }
            if (kayitDosyasi != null) kayitDosyasi.delete();
            kayitta = false;
            kayitci = null;
        }
    }

    public void kayitBitir() {
        if (!kayitta || kayitci == null) return;
        long sure = SystemClock.elapsedRealtime() - kayitBaslangic;
        MediaRecorder r = kayitci;
        kayitci = null;
        kayitta = false;
        boolean ok = true;
        try {
            r.stop();
        } catch (Exception e) {
            ok = false; // çok kısa basış
        }
        r.release();
        titret(20);
        degisti();
        final File f = kayitDosyasi;
        if (!ok || sure < 500 || f == null) {
            if (f != null) f.delete();
            return;
        }
        final int sureMs = (int) Math.min(sure, MAKS_SURE_MS);
        h.post(() -> {
            try {
                byte[] ses = oku(f);
                if (ses.length > 0) kendiMesajim("audio/mp4", sureMs, sifrele(ad, ses, null, null, null, kanal));
            } catch (Exception e) {
                Log.w(ETIKET, "ses gönderilemedi", e);
            } finally {
                f.delete();
            }
        });
    }

    public void cal(Mesaj m) {
        ana.post(() -> {
            calKuyrugu.remove(m);
            if (calici != null) { calici.stop(); calici.release(); calici = null; }
            calKuyrugu.add(0, m);
            siradakiniCal();
        });
    }

    private void siradakiniCal() {
        if (calici != null || kayitta || calKuyrugu.isEmpty()) return;
        Mesaj m = calKuyrugu.remove(0);
        Icerik i = coz(m);
        if (i == null || i.ses == null) { siradakiniCal(); return; }
        MediaPlayer p = null;
        try {
            File f = new File(ctx.getCacheDir(), "telsiz-cal.m4a");
            try (FileOutputStream o = new FileOutputStream(f)) { o.write(i.ses); }
            p = new MediaPlayer();
            p.setDataSource(f.getAbsolutePath());
            p.setOnCompletionListener(x -> { x.release(); calici = null; calanId = null; degisti(); siradakiniCal(); });
            p.setOnErrorListener((x, a, b) -> { x.release(); calici = null; calanId = null; degisti(); siradakiniCal(); return true; });
            p.prepare();
            p.start();
            calici = p;
            calanId = m.id;
            degisti();
        } catch (Exception e) {
            // Bozuk/çalınamayan ses: prepare atarsa oynatıcı (yerel kaynak) serbest kalsın.
            if (p != null) { try { p.release(); } catch (Exception ignored) { } }
            calici = null;
            calanId = null;
            siradakiniCal();
        }
    }

    @SuppressWarnings("deprecation")
    private void titret(long ms) {
        try {
            Vibrator v = (Vibrator) ctx.getSystemService(Context.VIBRATOR_SERVICE);
            if (v == null) return;
            if (Build.VERSION.SDK_INT >= 26) v.vibrate(VibrationEffect.createOneShot(ms, VibrationEffect.DEFAULT_AMPLITUDE));
            else v.vibrate(ms);
        } catch (Exception ignored) { }
    }

    // MARK: Kuyruk (web yükler)

    public void bekleyenler(java.util.function.Consumer<JSONArray> sonuc) {
        h.post(() -> {
            JSONArray c = new JSONArray();
            List<Mesaj> l = new ArrayList<>(tumu.values());
            Collections.sort(l, (a, b) -> Long.compare(a.t, b.t));
            for (Mesaj m : l) {
                if (m.yuklendi) continue;
                Icerik i = coz(m);
                if (i == null) continue;
                try {
                    JSONObject o = new JSONObject().put("id", m.id).put("kanal", m.kanal).put("ad", i.ad).put("olusturulduMs", m.t)
                            .put("atlama", m.atlama).put("sureMs", m.sure).put("mime", m.mime).put("kendim", m.kendim)
                            .put("sesBase64", i.ses == null ? "" : Base64.encodeToString(i.ses, Base64.NO_WRAP));
                    if (i.metin != null) o.put("metin", i.metin);
                    if (i.enlem != null) o.put("enlem", i.enlem).put("boylam", i.boylam);
                    c.put(o);
                } catch (Exception ignored) { }
                if (c.length() >= 20) break;
            }
            ana.post(() -> sonuc.accept(c));
        });
    }

    public void yuklendi(List<String> idler) {
        h.post(() -> {
            for (String id : idler) {
                Mesaj m = tumu.get(id);
                if (m == null) continue;
                m.yuklendi = true;
                diskeYaz(m);
            }
        });
    }

    // MARK: Etkinlik duyurusu (iOS DuyuruKablo v=2 ile aynı)

    public void duyuruYay(String etkinlikId, String baslik, String metin) {
        String temiz = metin == null ? "" : metin.trim();
        if (temiz.isEmpty()) return;
        final String m = kes(temiz, 140);
        final String b = baslik == null ? "" : kes(baslik, 80);
        h.post(() -> {
            if (!ble.calisiyorMu()) ble.baslat();
            yakin.baslat();
            try {
                JSONObject d = new JSONObject().put("v", 2).put("tur", "duyuru").put("id", UUID.randomUUID().toString().toUpperCase(java.util.Locale.ROOT))
                        .put("t", System.currentTimeMillis()).put("atlama", 0).put("etkinlikId", etkinlikId == null ? "" : etkinlikId)
                        .put("baslik", b).put("metin", m);
                duyurular.put(d.getString("id"), d);
                herYere(d.toString().getBytes(StandardCharsets.UTF_8), null);
            } catch (Exception ignored) { }
        });
    }

    private void duyuruAl(JSONObject d, String kimden) {
        long simdi = System.currentTimeMillis();
        String id = d.optString("id", "");
        int atlama = d.optInt("atlama", -1);
        if (id.isEmpty() || id.length() > 64 || simdi - d.optLong("t") >= DUYURU_OMUR_MS || atlama < 0 || atlama > MAKS_ATLAMA) return;
        if (duyurular.containsKey(id)) return;
        try {
            d.put("atlama", atlama + 1);
        } catch (Exception e) {
            return;
        }
        duyurular.put(id, d);
        if (atlama + 1 < MAKS_ATLAMA && pilYeterli()) herYere(d.toString().getBytes(StandardCharsets.UTF_8), kimden);
        duyuruBildirimi(d);
    }

    private void duyuruBildirimi(JSONObject d) {
        try {
            if (Build.VERSION.SDK_INT >= 33 && ContextCompat.checkSelfPermission(ctx, Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED) return;
            NotificationManager nm = (NotificationManager) ctx.getSystemService(Context.NOTIFICATION_SERVICE);
            if (nm == null) return;
            String kanalId = "walkie-talkie-duyuru";
            if (Build.VERSION.SDK_INT >= 26 && nm.getNotificationChannel(kanalId) == null) {
                nm.createNotificationChannel(new NotificationChannel(kanalId, TelsizMetin.simdiki().baslik, NotificationManager.IMPORTANCE_HIGH));
            }
            String etkinlik = d.optString("etkinlikId", "").replaceAll("[^A-Za-z0-9_-]", "");
            // Bildirime dokununca uygulamanın açılış ekranı açılır; etkinlik kimliği ek veri olarak verilir (yönlendirme uygulamanındır).
            Intent ac = ctx.getPackageManager().getLaunchIntentForPackage(ctx.getPackageName());
            if (ac == null) return;
            ac.putExtra("walkieTalkieDuyuruEtkinlik", etkinlik);
            PendingIntent pi = PendingIntent.getActivity(ctx, d.optString("id").hashCode(), ac, PendingIntent.FLAG_IMMUTABLE | PendingIntent.FLAG_UPDATE_CURRENT);
            String baslik = d.optString("baslik", "");
            NotificationCompat.Builder b = new NotificationCompat.Builder(ctx, kanalId)
                    .setSmallIcon(ctx.getApplicationInfo().icon)
                    .setContentTitle(baslik.isEmpty() ? TelsizMetin.uygulamaAdi : "📣 " + baslik)
                    .setContentText(d.optString("metin", ""))
                    .setStyle(new NotificationCompat.BigTextStyle().bigText(d.optString("metin", "")))
                    .setAutoCancel(true)
                    .setContentIntent(pi);
            nm.notify(("duyuru-" + d.optString("id")).hashCode(), b.build());
        } catch (Exception ignored) { }
    }

    // MARK: Web köprüsü (2026-11-05, tek ekran — src/index.ts yerelMotor; iOS ile aynı yöntemler)

    public String kanal() { return kanal; }

    /** Geçerli kanalın mesajları (ses içeriği yok; çalmak için calKimlik). */
    public JSONArray webListe() {
        JSONArray c = new JSONArray();
        for (Mesaj m : kanalListesi) {
            try {
                JSONObject o = new JSONObject().put("id", m.id).put("kanal", m.kanal).put("olusturulduMs", m.t).put("atlama", m.atlama)
                        .put("sureMs", m.sure).put("mime", m.mime).put("kendim", m.kendim).put("yuklendi", m.yuklendi);
                Icerik i = coz(m);
                o.put("ad", i == null ? "" : i.ad);
                if (i != null && i.metin != null) o.put("metin", i.metin);
                if (i != null && i.enlem != null) o.put("enlem", i.enlem).put("boylam", i.boylam);
                if (i != null && i.durum != null) o.put("durum", i.durum);
                c.put(o);
            } catch (Exception ignored) { }
        }
        return c;
    }

    public void calKimlik(String id) {
        h.post(() -> {
            Mesaj m = tumu.get(id);
            if (m != null) cal(m);
        });
    }

    /** Sunucudaki mesajları yerel ağa verir (internetli telefon köprü). "c_" öneki atılır; yerelde "yüklendi" işaretlenir. */
    public void disaridanEkle(JSONArray dizi) {
        h.post(() -> {
            long simdi = System.currentTimeMillis();
            boolean eklendi = false;
            for (int k = 0; k < Math.min(30, dizi.length()); k++) {
                JSONObject o = dizi.optJSONObject(k);
                if (o == null) continue;
                String id = o.optString("id", "");
                if (id.startsWith("c_")) id = id.substring(2);
                if (!KIMLIK.matcher(id).matches() || tumu.containsKey(id)) continue;
                String kn = o.optString("kanal", "");
                long t = o.optLong("olusturulduMs", 0);
                if (kn.isEmpty() || kn.length() > 64 || simdi - t >= OMUR_MS || t > simdi + 5 * 60_000) continue;
                String mime = o.optString("mime", "");
                String adi = o.optString("ad", "");
                adi = kes(adi, 60);
                Double a = o.has("enlem") ? o.optDouble("enlem") : null;
                Double b = o.has("boylam") ? o.optDouble("boylam") : null;
                if (a == null || b == null || a.isNaN() || b.isNaN() || Math.abs(a) > 90 || Math.abs(b) > 180) { a = null; b = null; }
                try {
                    String veri;
                    if (METIN_MIME.equals(mime)) {
                        String mt = metinTemizle(o.optString("metin", ""));
                        if (mt == null) continue;
                        veri = sifrele(adi, null, mt, a, b, kn);
                    } else {
                        String b64 = o.optString("sesBase64", "");
                        int v = b64.indexOf(',');
                        if (v >= 0) b64 = b64.substring(v + 1);
                        if (!mime.startsWith("audio/") || b64.isEmpty() || b64.length() > 2_100_000) continue;
                        veri = sifrele(adi, Base64.decode(b64, Base64.DEFAULT), null, a, b, kn);
                    }
                    Mesaj m = new Mesaj();
                    m.id = id;
                    m.kanal = kn;
                    m.t = t;
                    m.atlama = 1;
                    m.sure = Math.max(0, Math.min(MAKS_SURE_MS, o.optInt("sureMs", 0)));
                    m.mime = mime;
                    m.veri = veri;
                    m.alindiMs = simdi;
                    m.kendim = false;
                    m.yuklendi = true;
                    tumu.put(id, m);
                    diskeYaz(m);
                    if (pilYeterli()) herYere(m.kablo().toString().getBytes(StandardCharsets.UTF_8), null);
                    eklendi = true;
                } catch (Exception ignored) { }
            }
            if (eklendi) yayinla();
        });
    }

    // MARK: Disk

    private File klasor() {
        File k = new File(ctx.getFilesDir(), "walkie-talkie");
        if (!k.exists()) k.mkdirs();
        return k;
    }

    private void diskeYaz(Mesaj m) {
        try (FileOutputStream o = new FileOutputStream(new File(klasor(), m.id + ".json"))) {
            o.write(m.disk().toString().getBytes(StandardCharsets.UTF_8));
        } catch (Exception ignored) { }
    }

    private void diskYukle() {
        long simdi = System.currentTimeMillis();
        File[] dosyalar = klasor().listFiles();
        if (dosyalar == null) return;
        for (File f : dosyalar) {
            if (!f.getName().endsWith(".json")) continue;
            try {
                Mesaj m = Mesaj.diskten(new JSONObject(new String(oku(f), StandardCharsets.UTF_8)));
                if (simdi - m.t > OMUR_MS || !KIMLIK.matcher(m.id).matches()) { f.delete(); continue; }
                tumu.put(m.id, m);
            } catch (Exception e) {
                f.delete();
            }
        }
    }

    private static byte[] oku(File f) throws Exception {
        try (FileInputStream i = new FileInputStream(f)) {
            byte[] b = new byte[(int) f.length()];
            int o = 0, n;
            while (o < b.length && (n = i.read(b, o, b.length - o)) > 0) o += n;
            return b;
        }
    }
}
