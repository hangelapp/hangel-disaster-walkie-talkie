// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Uluslararası Sosyal Fayda Derneği (Social Business Global)
package org.hangel.walkietalkie.telsiz;

import android.Manifest;
import android.content.Context;
import android.content.pm.PackageManager;
import android.os.Build;
import android.os.Handler;
import android.util.Log;

import androidx.annotation.NonNull;
import androidx.core.content.ContextCompat;

import com.google.android.gms.nearby.Nearby;
import com.google.android.gms.nearby.connection.AdvertisingOptions;
import com.google.android.gms.nearby.connection.ConnectionInfo;
import com.google.android.gms.nearby.connection.ConnectionLifecycleCallback;
import com.google.android.gms.nearby.connection.ConnectionResolution;
import com.google.android.gms.nearby.connection.ConnectionsClient;
import com.google.android.gms.nearby.connection.ConnectionsStatusCodes;
import com.google.android.gms.nearby.connection.DiscoveredEndpointInfo;
import com.google.android.gms.nearby.connection.DiscoveryOptions;
import com.google.android.gms.nearby.connection.EndpointDiscoveryCallback;
import com.google.android.gms.nearby.connection.Payload;
import com.google.android.gms.nearby.connection.PayloadCallback;
import com.google.android.gms.nearby.connection.PayloadTransferUpdate;
import com.google.android.gms.nearby.connection.Strategy;

import java.security.SecureRandom;
import java.util.ArrayList;
import java.util.HashMap;
import java.util.LinkedHashSet;
import java.util.List;
import java.util.Map;
import java.util.Set;

/**
 * Afet Telsizi ek taşıması (Android ↔ Android, 2026-11-07) — Google Nearby Connections (play-services-nearby).
 *
 * iOS'taki ek taşımanın (TelsizWifiAware.swift, iPhone ↔ iPhone Wi-Fi Aware) Android karşılığı: Bluetooth LE (TelsizBle)
 * yanında çalışır, aynı kablo biçimini (JSON v=1 mesaj / v=2 duyuru) taşır. Nearby Connections bağlantıyı Bluetooth ile kurar,
 * uygun olunca Wi-Fi'ye (Wi-Fi Direct / erişim noktası / yerel ağ) yükseltir → sesli mesajlar BLE'ye göre çok daha hızlı gider.
 * iPhone ↔ Android yine BLE ile konuşur; mesaj kimliğiyle tekilleştirme motorda olduğu için iki yol birlikte güvenle çalışır.
 *
 * Strateji P2P_CLUSTER (çoktan çoğa; telsiz ağı). Herkes hem yayın yapar hem arar; iki telefon aynı anda birbirine istek atmasın
 * diye uç adındaki rastgele jeton büyük olan bağlanır, küçük olan 10 sn içinde bağlantı gelmezse kendisi dener. Gelen bağlantılar
 * kendiliğinden kabul edilir: içerik zaten kanal anahtarıyla şifreli (TelsizSifre) ve motor her yükü doğrular (boyut, kimlik,
 * ömür, aktarım sayısı). Belge: https://developers.google.com/nearby/connections/android/get-started
 *
 * Aynı uygulamada Nearby yalnız bir yayın yapabilir: uygulamanın başka bir Nearby özelliği varsa `fotoPaylasimi` bayrağı true
 * yapılınca bu taşıma kendini bırakır (birakildi()). İzin yoksa (Android 12+ Bluetooth,
 * Android 13+ yakındaki Wi-Fi cihazları) sessizce çalışmaz; BLE yolu etkilenmez.
 *
 * Bütün yöntemler motorun iş parçacığında (h) çağrılır; Nearby geri çağrıları da h'ye aktarılır.
 */
final class TelsizYakin implements EkTasima {
    private static final String ETIKET = "WalkieTalkieNearby";
    static final String SERVIS = "com.hangel.telsiz";
    private static final Strategy STRATEJI = Strategy.P2P_CLUSTER;
    private static final String AD_ONEKI = "hgt1-";
    private static final long BEKLEME_MS = 10_000;

    /** "Yakındakilere gönder" Nearby'yi kullanıyor: bu taşıma başlamaz (iki yayın aynı anda olamaz). */
    static volatile boolean fotoPaylasimi;

    private final Context ctx;
    private final Handler h;
    private final TelsizBle.Olaylar olaylar;
    private final String jeton;
    private ConnectionsClient istemci;
    private volatile boolean calisiyor;
    private final Set<String> bagli = new LinkedHashSet<>();
    private final Set<String> bekleyen = new LinkedHashSet<>();
    private final Map<String, String> bulunan = new HashMap<>();

    TelsizYakin(Context ctx, Handler h, TelsizBle.Olaylar olaylar) {
        this.ctx = ctx;
        this.h = h;
        this.olaylar = olaylar;
        SecureRandom r = new SecureRandom();
        StringBuilder s = new StringBuilder();
        for (int i = 0; i < 8; i++) s.append(Integer.toHexString(r.nextInt(16)));
        this.jeton = s.toString();
    }

    @Override public boolean calisiyorMu() {
        return calisiyor;
    }

    /** Bağlantı kimlikleri motorda BLE kimlikleriyle karışmasın diye önekli. */
    static String kimlik(String ucId) {
        return "nc:" + ucId;
    }

    private static String ucId(String kimlik) {
        return kimlik != null && kimlik.startsWith("nc:") ? kimlik.substring(3) : null;
    }

    /** Nearby'nin istediği çalışma anı izinleri (uygulamanın başka Nearby özellikleriyle aynı): 12+ Bluetooth, 13+ yakındaki Wi-Fi cihazları. */
    static String[] gerekliIzinler() {
        if (Build.VERSION.SDK_INT >= 33) {
            return new String[]{Manifest.permission.BLUETOOTH_SCAN, Manifest.permission.BLUETOOTH_ADVERTISE,
                    Manifest.permission.BLUETOOTH_CONNECT, Manifest.permission.NEARBY_WIFI_DEVICES};
        }
        if (Build.VERSION.SDK_INT >= 31) {
            return new String[]{Manifest.permission.BLUETOOTH_SCAN, Manifest.permission.BLUETOOTH_ADVERTISE,
                    Manifest.permission.BLUETOOTH_CONNECT, Manifest.permission.ACCESS_FINE_LOCATION};
        }
        return new String[]{Manifest.permission.ACCESS_FINE_LOCATION};
    }

    private boolean izinliMi() {
        for (String p : gerekliIzinler()) {
            if (ContextCompat.checkSelfPermission(ctx, p) != PackageManager.PERMISSION_GRANTED) return false;
        }
        return true;
    }

    @Override public void baslat() {
        if (calisiyor || fotoPaylasimi || !izinliMi()) return;
        try {
            if (istemci == null) istemci = Nearby.getConnectionsClient(ctx);
        } catch (Throwable e) {
            Log.i(ETIKET, "Nearby yok: " + e);
            return;
        }
        calisiyor = true;
        String ad = AD_ONEKI + jeton;
        istemci.startAdvertising(ad, SERVIS, baglantiGeriCagrisi, new AdvertisingOptions.Builder().setStrategy(STRATEJI).build())
                .addOnFailureListener(e -> Log.i(ETIKET, "yayın başlamadı: " + e.getMessage()));
        istemci.startDiscovery(SERVIS, aramaGeriCagrisi, new DiscoveryOptions.Builder().setStrategy(STRATEJI).build())
                .addOnFailureListener(e -> Log.i(ETIKET, "arama başlamadı: " + e.getMessage()));
    }

    @Override public void durdur() {
        if (!calisiyor) return;
        calisiyor = false;
        if (istemci != null && !fotoPaylasimi) {
            try {
                istemci.stopAdvertising();
                istemci.stopDiscovery();
                istemci.stopAllEndpoints();
            } catch (Throwable ignored) { }
        }
        temizle();
    }

    /** "Yakındakilere gönder" açıldı: Nearby'yi o ekran zaten baştan kuruyor (stopAllEndpoints) → yalnız durum temizlenir. */
    void birakildi() {
        calisiyor = false;
        temizle();
    }

    private void temizle() {
        bagli.clear();
        bekleyen.clear();
        bulunan.clear();
        bildir();
    }

    @Override public void gonder(byte[] yuk, String haric) {
        if (!calisiyor || fotoPaylasimi || istemci == null || bagli.isEmpty() || yuk.length > TelsizCerceve.MAKS_YUK) return;
        String haricUc = ucId(haric);
        List<String> hedef = new ArrayList<>();
        for (String u : bagli) if (!u.equals(haricUc)) hedef.add(u);
        if (hedef.isEmpty()) return;
        istemci.sendPayload(hedef, Payload.fromBytes(yuk));
    }

    @Override public void gonderKime(String kimlik, byte[] yuk) {
        String u = ucId(kimlik);
        if (!calisiyor || fotoPaylasimi || istemci == null || u == null || !bagli.contains(u) || yuk.length > TelsizCerceve.MAKS_YUK) return;
        istemci.sendPayload(u, Payload.fromBytes(yuk));
    }

    private void bildir() {
        List<String> adlar = new ArrayList<>();
        for (String u : bagli) adlar.add("nc·" + u);
        olaylar.baglantilarDegisti(adlar);
    }

    private void baglan(String u) {
        if (!calisiyor || fotoPaylasimi || istemci == null || bagli.contains(u) || bekleyen.contains(u)) return;
        bekleyen.add(u);
        istemci.requestConnection(AD_ONEKI + jeton, u, baglantiGeriCagrisi)
                .addOnFailureListener(e -> h.post(() -> bekleyen.remove(u)));
    }

    private final EndpointDiscoveryCallback aramaGeriCagrisi = new EndpointDiscoveryCallback() {
        @Override
        public void onEndpointFound(@NonNull String u, @NonNull DiscoveredEndpointInfo bilgi) {
            final String ad = bilgi.getEndpointName();
            h.post(() -> {
                if (!calisiyor || !SERVIS.equals(bilgi.getServiceId()) || ad == null || !ad.startsWith(AD_ONEKI)) return;
                String onunki = ad.substring(AD_ONEKI.length());
                bulunan.put(u, onunki);
                if (jeton.compareTo(onunki) > 0) {
                    baglan(u);
                } else {
                    // Karşı taraf bağlanacak; 10 sn içinde gelmezse (o telefon aramıyor olabilir) biz deneriz.
                    h.postDelayed(() -> { if (bulunan.containsKey(u)) baglan(u); }, BEKLEME_MS);
                }
            });
        }

        @Override
        public void onEndpointLost(@NonNull String u) {
            h.post(() -> bulunan.remove(u));
        }
    };

    private final ConnectionLifecycleCallback baglantiGeriCagrisi = new ConnectionLifecycleCallback() {
        @Override
        public void onConnectionInitiated(@NonNull String u, @NonNull ConnectionInfo bilgi) {
            String ad = bilgi.getEndpointName();
            if (!calisiyor || istemci == null || ad == null || !ad.startsWith(AD_ONEKI)) {
                if (istemci != null) istemci.rejectConnection(u);
                return;
            }
            istemci.acceptConnection(u, yukGeriCagrisi);
        }

        @Override
        public void onConnectionResult(@NonNull String u, @NonNull ConnectionResolution sonuc) {
            final boolean tamam = sonuc.getStatus().getStatusCode() == ConnectionsStatusCodes.STATUS_OK;
            h.post(() -> {
                bekleyen.remove(u);
                if (!tamam || !calisiyor) return;
                if (bagli.add(u)) {
                    bildir();
                    olaylar.yeniBaglanti(kimlik(u));
                }
            });
        }

        @Override
        public void onDisconnected(@NonNull String u) {
            h.post(() -> {
                bekleyen.remove(u);
                if (bagli.remove(u)) bildir();
            });
        }
    };

    private final PayloadCallback yukGeriCagrisi = new PayloadCallback() {
        @Override
        public void onPayloadReceived(@NonNull String u, @NonNull Payload yuk) {
            if (yuk.getType() != Payload.Type.BYTES) return;
            final byte[] b = yuk.asBytes();
            if (b == null || b.length == 0 || b.length > TelsizCerceve.MAKS_YUK) return;
            h.post(() -> {
                if (calisiyor && bagli.contains(u)) olaylar.yukAlindi(kimlik(u), b);
            });
        }

        @Override
        public void onPayloadTransferUpdate(@NonNull String u, @NonNull PayloadTransferUpdate guncelleme) { }
    };
}
