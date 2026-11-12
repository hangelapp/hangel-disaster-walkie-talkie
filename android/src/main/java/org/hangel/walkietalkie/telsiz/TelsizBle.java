// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Uluslararası Sosyal Fayda Derneği (Social Business Global)
package org.hangel.walkietalkie.telsiz;

import android.annotation.SuppressLint;
import android.bluetooth.BluetoothAdapter;
import android.bluetooth.BluetoothDevice;
import android.bluetooth.BluetoothGatt;
import android.bluetooth.BluetoothGattCallback;
import android.bluetooth.BluetoothGattCharacteristic;
import android.bluetooth.BluetoothGattDescriptor;
import android.bluetooth.BluetoothGattServer;
import android.bluetooth.BluetoothGattServerCallback;
import android.bluetooth.BluetoothGattService;
import android.bluetooth.BluetoothManager;
import android.bluetooth.BluetoothProfile;
import android.bluetooth.BluetoothStatusCodes;
import android.bluetooth.le.AdvertiseCallback;
import android.bluetooth.le.AdvertiseData;
import android.bluetooth.le.AdvertiseSettings;
import android.bluetooth.le.BluetoothLeAdvertiser;
import android.bluetooth.le.BluetoothLeScanner;
import android.bluetooth.le.ScanCallback;
import android.bluetooth.le.ScanFilter;
import android.bluetooth.le.ScanRecord;
import android.bluetooth.le.ScanResult;
import android.bluetooth.le.ScanSettings;
import android.content.BroadcastReceiver;
import android.content.Context;
import android.content.Intent;
import android.content.IntentFilter;
import android.os.Build;
import android.os.Handler;
import android.os.ParcelUuid;
import android.os.SystemClock;
import android.util.Log;

import androidx.core.content.ContextCompat;

import java.security.SecureRandom;
import java.util.ArrayDeque;
import java.util.ArrayList;
import java.util.Collections;
import java.util.HashMap;
import java.util.List;
import java.util.Map;
import java.util.UUID;

/**
 * Afet Telsizi — Bluetooth LE taşıması (iPhone ↔ Android, Android ↔ Android). Biçim: src/protocol/frame.ts.
 *
 * Her Android hem ÇEVRE BİRİMİ (reklam + GATT sunucusu) hem MERKEZDİR (tarar, bağlanır).
 *  - iPhone yalnız çevre birimidir (iPhone↔iPhone MultipeerConnectivity'yle konuşur) → Android, reklamında "A" işareti
 *    olmayan (iPhone) her telsiz yayınına bağlanır.
 *  - Android↔Android: tarama yanıtındaki 4 baytlık düğüm numarası küçük olan bağlanır → çift bağlantı olmaz. Reklam
 *    yapamayan telefon (eski donanım) sıraya bakmadan bağlanır.
 * Bağlantı başına: merkez → çevre birimi RX'e yanıtsız yazar; çevre birimi → merkez TX'ten bildirir. Aynı anda bağlantı
 * başına tek çerçeve yolda (geri çağrı gelince sıradaki). Bütün durum motorun tek iş parçacığında (Handler) değişir.
 */
@SuppressLint("MissingPermission") // İzinler TelsizActivity'de istenir; her çağrı SecurityException'a karşı korunur.
final class TelsizBle {
    private static final String ETIKET = "WalkieTalkieBle";

    static final UUID SERVIS = UUID.fromString("7A1E0001-4A6E-4C2B-9F3D-68616E67656C");
    static final UUID RX = UUID.fromString("7A1E0002-4A6E-4C2B-9F3D-68616E67656C");
    static final UUID TX = UUID.fromString("7A1E0003-4A6E-4C2B-9F3D-68616E67656C");
    static final UUID CCCD = UUID.fromString("00002902-0000-1000-8000-00805f9b34fb");
    static final int MAKS_MERKEZ_BAGLANTI = 6;
    private static final int MAKS_KUYRUK_BAYT = 3 * 1024 * 1024;
    private static final long YENIDEN_DENEME_MS = 10_000;
    private static final long CERCEVE_BEKCI_MS = 3_000;
    /** Bağlanıp MTU/hizmet keşfi/abonelikte takılan merkez bağlantısı bu süre sonra bırakılır (iOS baglanmaZamanAsimiSn karşılığı). */
    private static final long BAGLANMA_ZAMAN_ASIMI_MS = 30_000;

    interface Olaylar {
        void yukAlindi(String baglanti, byte[] yuk);
        void yeniBaglanti(String baglanti);
        void baglantilarDegisti(List<String> adlar);
    }

    private static final class Baglanti {
        final String id;
        final BluetoothDevice cihaz;
        final boolean merkezBiz;
        BluetoothGatt gatt;
        BluetoothGattCharacteristic rx;
        int mtu = 23;
        boolean hazir;
        boolean yolda;
        long yoldaMs;
        int kuyrukBayt;
        long sira = new SecureRandom().nextInt() & 0xffffffffL;
        final ArrayDeque<byte[]> kuyruk = new ArrayDeque<>();
        final TelsizCerceve.Birlestirici birlestirici = new TelsizCerceve.Birlestirici();
        String tur = "?";

        Baglanti(String id, BluetoothDevice cihaz, boolean merkezBiz) {
            this.id = id;
            this.cihaz = cihaz;
            this.merkezBiz = merkezBiz;
        }
    }

    private final Context ctx;
    private final Handler h;
    private final Olaylar olaylar;
    private final int dugum = new SecureRandom().nextInt() & 0x7fffffff;
    private final Map<String, Baglanti> baglantilar = new HashMap<>();
    private final Map<String, Long> sonDeneme = new HashMap<>();

    private BluetoothManager bm;
    private BluetoothAdapter adaptor;
    private BluetoothGattServer sunucu;
    private BluetoothGattCharacteristic txOzellik;
    private BluetoothLeAdvertiser yayinci;
    private BluetoothLeScanner tarayici;
    private volatile boolean calisiyor;
    private boolean reklamVar;
    /** Motor telsizi istedi (Bluetooth kapalıyken de): Bluetooth açılınca kendiliğinden kurulur. */
    private boolean istendi;

    TelsizBle(Context ctx, Handler h, Olaylar olaylar) {
        this.ctx = ctx.getApplicationContext();
        this.h = h;
        this.olaylar = olaylar;
        // Bluetooth kapanıp açılınca (uçak modu dahil) GATT sunucusu, reklam ve tarama ölür; calisiyor true kalıp telsiz
        // uygulama yeniden açılana dek sessiz kalıyordu. Kapanınca bırak, açılınca istenmişse yeniden kur.
        try {
            ContextCompat.registerReceiver(this.ctx, durumAlici, new IntentFilter(BluetoothAdapter.ACTION_STATE_CHANGED), ContextCompat.RECEIVER_EXPORTED); // korumalı sistem yayını (yalnız sistem gönderebilir); NOT_EXPORTED API<33’te Bluetooth sürecinin yayınını eleyebilir
        } catch (Exception e) {
            Log.w(ETIKET, "Bluetooth durum alıcısı kaydedilemedi", e);
        }
    }

    private final BroadcastReceiver durumAlici = new BroadcastReceiver() {
        @Override public void onReceive(Context c, Intent i) {
            final int s = i.getIntExtra(BluetoothAdapter.EXTRA_STATE, BluetoothAdapter.ERROR);
            h.post(() -> {
                if (s == BluetoothAdapter.STATE_TURNING_OFF || s == BluetoothAdapter.STATE_OFF) {
                    if (calisiyor) kapat();
                } else if (s == BluetoothAdapter.STATE_ON && istendi && !calisiyor) {
                    if (baslat()) bildir();
                }
            });
        }
    };

    boolean bluetoothAcik() {
        try {
            BluetoothManager m = (BluetoothManager) ctx.getSystemService(Context.BLUETOOTH_SERVICE);
            BluetoothAdapter a = m == null ? null : m.getAdapter();
            return a != null && a.isEnabled();
        } catch (SecurityException e) {
            return false;
        }
    }

    boolean calisiyorMu() {
        return calisiyor;
    }

    /** Motor iş parçacığında çağrılır. Bluetooth kapalı / izin yoksa false. */
    boolean baslat() {
        istendi = true;
        if (calisiyor) return true;
        try {
            bm = (BluetoothManager) ctx.getSystemService(Context.BLUETOOTH_SERVICE);
            adaptor = bm == null ? null : bm.getAdapter();
            if (adaptor == null || !adaptor.isEnabled()) return false;
            calisiyor = true;
            sunucuyuKur();
            tarayici = adaptor.getBluetoothLeScanner();
            if (tarayici != null) {
                List<ScanFilter> suzgec = Collections.singletonList(new ScanFilter.Builder().setServiceUuid(new ParcelUuid(SERVIS)).build());
                ScanSettings ayar = new ScanSettings.Builder().setScanMode(ScanSettings.SCAN_MODE_LOW_LATENCY).build();
                tarayici.startScan(suzgec, ayar, taramaGeriCagri);
            }
            return true;
        } catch (SecurityException e) {
            Log.w(ETIKET, "izin yok", e);
            durdur();
            return false;
        }
    }

    void durdur() {
        istendi = false;
        kapat();
    }

    /** Her şeyi bırakır; istendi değişmez (Bluetooth yeniden açılınca kurulur). */
    private void kapat() {
        calisiyor = false;
        try {
            if (tarayici != null) tarayici.stopScan(taramaGeriCagri);
        } catch (Exception ignored) { }
        try {
            if (yayinci != null) yayinci.stopAdvertising(reklamGeriCagri);
        } catch (Exception ignored) { }
        for (Baglanti b : new ArrayList<>(baglantilar.values())) {
            try {
                if (b.gatt != null) { b.gatt.disconnect(); b.gatt.close(); }
            } catch (Exception ignored) { }
        }
        baglantilar.clear();
        try {
            if (sunucu != null) sunucu.close();
        } catch (Exception ignored) { }
        sunucu = null;
        tarayici = null;
        yayinci = null;
        reklamVar = false;
        bildir();
    }

    // MARK: Gönderme

    void gonder(byte[] yuk, String haric) {
        for (Baglanti b : baglantilar.values()) {
            if (b.hazir && !b.id.equals(haric)) kuyrugaEkle(b, yuk);
        }
    }

    void gonderKime(String id, byte[] yuk) {
        Baglanti b = baglantilar.get(id);
        if (b != null && b.hazir) kuyrugaEkle(b, yuk);
    }

    int hazirSayisi() {
        int n = 0;
        for (Baglanti b : baglantilar.values()) if (b.hazir) n++;
        return n;
    }

    private void kuyrugaEkle(Baglanti b, byte[] yuk) {
        if (yuk.length > TelsizCerceve.MAKS_YUK) return;
        if (b.kuyrukBayt + yuk.length > MAKS_KUYRUK_BAYT) return; // yavaş bağlantı: yeni mesajı bu kola atla (dedup diğer kollardan getirir)
        int parca = Math.max(TelsizCerceve.BASLIK + 1, Math.min(512, b.mtu - 3));
        List<byte[]> cerceveler = TelsizCerceve.cercevele(yuk, b.sira, parca);
        b.sira = (b.sira + 1) & 0xffffffffL;
        for (byte[] c : cerceveler) {
            b.kuyruk.add(c);
            b.kuyrukBayt += c.length;
        }
        pompala(b);
    }

    private void pompala(Baglanti b) {
        // Kapanmış (haritadan çıkmış) bağlantı: bekleyen yeniden deneme/bekçi görevleri burada biter. Yoksa kapalı GATT'a yazma
        // her seferinde false döner ve 30 ms'de bir sonsuz yeniden deneme döngüsü (pil + kuyruk belleği) sürerdi.
        if (!calisiyor || !b.hazir || baglantilar.get(b.id) != b) return;
        if (b.yolda && SystemClock.elapsedRealtime() - b.yoldaMs < CERCEVE_BEKCI_MS) return;
        byte[] c = b.kuyruk.poll();
        if (c == null) { b.yolda = false; return; }
        b.kuyrukBayt -= c.length;
        boolean tamam;
        try {
            tamam = b.merkezBiz ? yaz(b, c) : bildirimGonder(b, c);
        } catch (SecurityException e) {
            tamam = false;
        }
        if (!tamam) {
            // Yığın meşgul: çerçeveyi başa koy, kısa süre sonra yeniden dene.
            b.kuyruk.addFirst(c);
            b.kuyrukBayt += c.length;
            b.yolda = false;
            h.postDelayed(() -> pompala(b), 30);
            return;
        }
        b.yolda = true;
        b.yoldaMs = SystemClock.elapsedRealtime();
        final long damga = b.yoldaMs;
        // Bazı cihazlar geri çağrıyı hiç vermez: bekçi sıradakini zorlar.
        h.postDelayed(() -> { if (b.yolda && b.yoldaMs == damga) { b.yolda = false; pompala(b); } }, CERCEVE_BEKCI_MS);
    }

    @SuppressWarnings("deprecation")
    private boolean yaz(Baglanti b, byte[] c) {
        if (b.gatt == null || b.rx == null) return false;
        if (Build.VERSION.SDK_INT >= 33) {
            return b.gatt.writeCharacteristic(b.rx, c, BluetoothGattCharacteristic.WRITE_TYPE_NO_RESPONSE) == BluetoothStatusCodes.SUCCESS;
        }
        b.rx.setWriteType(BluetoothGattCharacteristic.WRITE_TYPE_NO_RESPONSE);
        b.rx.setValue(c);
        return b.gatt.writeCharacteristic(b.rx);
    }

    @SuppressWarnings("deprecation")
    private boolean bildirimGonder(Baglanti b, byte[] c) {
        if (sunucu == null || txOzellik == null) return false;
        if (Build.VERSION.SDK_INT >= 33) {
            return sunucu.notifyCharacteristicChanged(b.cihaz, txOzellik, false, c) == BluetoothStatusCodes.SUCCESS;
        }
        txOzellik.setValue(c);
        return sunucu.notifyCharacteristicChanged(b.cihaz, txOzellik, false);
    }

    private void cerceveAlindi(Baglanti b, byte[] c) {
        byte[] yuk = b.birlestirici.ekle(c, SystemClock.elapsedRealtime());
        if (yuk != null) olaylar.yukAlindi(b.id, yuk);
    }

    private void bildir() {
        List<String> adlar = new ArrayList<>();
        for (Baglanti b : baglantilar.values()) if (b.hazir) adlar.add(b.tur + "·" + b.id.substring(Math.max(0, b.id.length() - 5)));
        olaylar.baglantilarDegisti(adlar);
    }

    // MARK: Çevre birimi (GATT sunucusu + reklam)

    private void sunucuyuKur() {
        sunucu = bm.openGattServer(ctx, sunucuGeriCagri);
        if (sunucu == null) return;
        BluetoothGattService s = new BluetoothGattService(SERVIS, BluetoothGattService.SERVICE_TYPE_PRIMARY);
        BluetoothGattCharacteristic rx = new BluetoothGattCharacteristic(RX,
                BluetoothGattCharacteristic.PROPERTY_WRITE | BluetoothGattCharacteristic.PROPERTY_WRITE_NO_RESPONSE,
                BluetoothGattCharacteristic.PERMISSION_WRITE);
        txOzellik = new BluetoothGattCharacteristic(TX, BluetoothGattCharacteristic.PROPERTY_NOTIFY, BluetoothGattCharacteristic.PERMISSION_READ);
        BluetoothGattDescriptor cccd = new BluetoothGattDescriptor(CCCD, BluetoothGattDescriptor.PERMISSION_READ | BluetoothGattDescriptor.PERMISSION_WRITE);
        txOzellik.addDescriptor(cccd);
        s.addCharacteristic(rx);
        s.addCharacteristic(txOzellik);
        sunucu.addService(s); // reklam onServiceAdded'da başlar
    }

    private void reklamiBaslat() {
        if (adaptor == null || !adaptor.isMultipleAdvertisementSupported()) { reklamVar = false; return; }
        yayinci = adaptor.getBluetoothLeAdvertiser();
        if (yayinci == null) { reklamVar = false; return; }
        AdvertiseSettings ayar = new AdvertiseSettings.Builder()
                .setAdvertiseMode(AdvertiseSettings.ADVERTISE_MODE_LOW_LATENCY)
                .setTxPowerLevel(AdvertiseSettings.ADVERTISE_TX_POWER_HIGH)
                .setConnectable(true)
                .setTimeout(0)
                .build();
        AdvertiseData veri = new AdvertiseData.Builder().setIncludeDeviceName(false).addServiceUuid(new ParcelUuid(SERVIS)).build();
        byte[] isaret = new byte[]{'A', (byte) (dugum >>> 24), (byte) (dugum >>> 16), (byte) (dugum >>> 8), (byte) dugum};
        AdvertiseData yanit = new AdvertiseData.Builder().setIncludeDeviceName(false).addServiceData(new ParcelUuid(SERVIS), isaret).build();
        yayinci.startAdvertising(ayar, veri, yanit, reklamGeriCagri);
    }

    private final AdvertiseCallback reklamGeriCagri = new AdvertiseCallback() {
        @Override public void onStartSuccess(AdvertiseSettings settingsInEffect) { h.post(() -> reklamVar = true); }
        @Override public void onStartFailure(int errorCode) {
            Log.w(ETIKET, "reklam başlamadı: " + errorCode);
            h.post(() -> reklamVar = false);
        }
    };

    private Baglanti sunucuBaglantisi(BluetoothDevice d) {
        String id = "s:" + d.getAddress();
        Baglanti b = baglantilar.get(id);
        if (b == null) {
            b = new Baglanti(id, d, false);
            baglantilar.put(id, b);
        }
        return b;
    }

    private final BluetoothGattServerCallback sunucuGeriCagri = new BluetoothGattServerCallback() {
        @Override public void onServiceAdded(int status, BluetoothGattService service) {
            h.post(() -> {
                if (!calisiyor) return;
                try { reklamiBaslat(); } catch (SecurityException e) { reklamVar = false; }
            });
        }

        @Override public void onConnectionStateChange(BluetoothDevice device, int status, int newState) {
            h.post(() -> {
                String id = "s:" + device.getAddress();
                if (newState == BluetoothProfile.STATE_CONNECTED) {
                    sunucuBaglantisi(device);
                } else if (newState == BluetoothProfile.STATE_DISCONNECTED) {
                    baglantilar.remove(id);
                    bildir();
                }
            });
        }

        @Override public void onMtuChanged(BluetoothDevice device, int mtu) {
            h.post(() -> sunucuBaglantisi(device).mtu = mtu);
        }

        @Override public void onCharacteristicWriteRequest(BluetoothDevice device, int requestId, BluetoothGattCharacteristic characteristic,
                                                           boolean preparedWrite, boolean responseNeeded, int offset, byte[] value) {
            boolean bizim = RX.equals(characteristic.getUuid()) && !preparedWrite && offset == 0;
            if (responseNeeded) {
                try {
                    sunucu.sendResponse(device, requestId, bizim ? BluetoothGatt.GATT_SUCCESS : BluetoothGatt.GATT_FAILURE, 0, null);
                } catch (Exception ignored) { }
            }
            if (!bizim || value == null) return;
            final byte[] kopya = value.clone();
            h.post(() -> {
                if (!calisiyor) return;
                cerceveAlindi(sunucuBaglantisi(device), kopya);
            });
        }

        @Override public void onDescriptorWriteRequest(BluetoothDevice device, int requestId, BluetoothGattDescriptor descriptor,
                                                       boolean preparedWrite, boolean responseNeeded, int offset, byte[] value) {
            boolean cccd = CCCD.equals(descriptor.getUuid()) && TX.equals(descriptor.getCharacteristic().getUuid());
            if (responseNeeded) {
                try {
                    sunucu.sendResponse(device, requestId, cccd ? BluetoothGatt.GATT_SUCCESS : BluetoothGatt.GATT_FAILURE, 0, null);
                } catch (Exception ignored) { }
            }
            if (!cccd) return;
            final boolean acik = value != null && value.length > 0 && (value[0] & 0x01) != 0;
            h.post(() -> {
                if (!calisiyor) return;
                Baglanti b = sunucuBaglantisi(device);
                boolean yeni = acik && !b.hazir;
                b.hazir = acik;
                b.tur = "M"; // karşı taraf merkez (Android)
                bildir();
                if (yeni) olaylar.yeniBaglanti(b.id);
            });
        }

        @Override public void onDescriptorReadRequest(BluetoothDevice device, int requestId, int offset, BluetoothGattDescriptor descriptor) {
            try {
                sunucu.sendResponse(device, requestId, BluetoothGatt.GATT_SUCCESS, 0, BluetoothGattDescriptor.DISABLE_NOTIFICATION_VALUE);
            } catch (Exception ignored) { }
        }

        @Override public void onNotificationSent(BluetoothDevice device, int status) {
            h.post(() -> {
                Baglanti b = baglantilar.get("s:" + device.getAddress());
                if (b == null) return;
                b.yolda = false;
                pompala(b);
            });
        }
    };

    // MARK: Merkez (tarama + istemci)

    private final ScanCallback taramaGeriCagri = new ScanCallback() {
        @Override public void onScanResult(int callbackType, ScanResult result) {
            h.post(() -> bulundu(result));
        }

        @Override public void onBatchScanResults(List<ScanResult> results) {
            h.post(() -> { for (ScanResult r : results) bulundu(r); });
        }

        @Override public void onScanFailed(int errorCode) {
            Log.w(ETIKET, "tarama başlamadı: " + errorCode);
        }
    };

    private int merkezSayisi() {
        int n = 0;
        for (Baglanti b : baglantilar.values()) if (b.merkezBiz) n++;
        return n;
    }

    private void bulundu(ScanResult r) {
        if (!calisiyor || r == null || r.getDevice() == null) return;
        BluetoothDevice d = r.getDevice();
        String id = "m:" + d.getAddress();
        if (baglantilar.containsKey(id) || merkezSayisi() >= MAKS_MERKEZ_BAGLANTI) return;
        if (baglantilar.containsKey("s:" + d.getAddress())) return; // o zaten bize bağlı
        Long son = sonDeneme.get(id);
        long simdi = SystemClock.elapsedRealtime();
        if (son != null && simdi - son < YENIDEN_DENEME_MS) return;
        ScanRecord kayit = r.getScanRecord();
        byte[] isaret = kayit == null ? null : kayit.getServiceData(new ParcelUuid(SERVIS));
        String tur = "i"; // işaret yoksa iPhone
        if (isaret != null && isaret.length >= 5 && isaret[0] == 'A') {
            tur = "a";
            int karsi = ((isaret[1] & 0xff) << 24 | (isaret[2] & 0xff) << 16 | (isaret[3] & 0xff) << 8 | (isaret[4] & 0xff)) & 0x7fffffff;
            // Android↔Android: küçük düğüm bağlanır (reklam yapamıyorsak sıraya bakmadan bağlanırız).
            if (reklamVar && dugum >= karsi) return;
        }
        sonDeneme.put(id, simdi);
        Baglanti b = new Baglanti(id, d, true);
        b.tur = tur;
        baglantilar.put(id, b);
        try {
            b.gatt = d.connectGatt(ctx, false, istemciGeriCagri(b), BluetoothDevice.TRANSPORT_LE);
        } catch (SecurityException e) {
            baglantilar.remove(id);
        }
        if (b.gatt == null) { baglantilar.remove(id); return; }
        // Bazı cihazlarda MTU / hizmet keşfi / abonelik geri çağrısı hiç gelmez: hazır olmayan bağlantı yeri (en çok 6) ve o
        // telefonu sonsuza dek tutmasın.
        h.postDelayed(() -> {
            if (baglantilar.get(id) != b || b.hazir) return;
            try { b.gatt.disconnect(); } catch (Exception ignored) { }
            merkezKapat(b);
        }, BAGLANMA_ZAMAN_ASIMI_MS);
    }

    private void merkezKapat(Baglanti b) {
        try {
            if (b.gatt != null) b.gatt.close();
        } catch (Exception ignored) { }
        // Yalnız bu bağlantıyı çıkar: geç gelen eski geri çağrı aynı adrese yeniden kurulmuş bağlantıyı silmesin (GATT sızıntısı).
        baglantilar.remove(b.id, b);
        bildir();
    }

    private BluetoothGattCallback istemciGeriCagri(final Baglanti b) {
        return new BluetoothGattCallback() {
            @Override public void onConnectionStateChange(BluetoothGatt gatt, int status, int newState) {
                h.post(() -> {
                    if (status != BluetoothGatt.GATT_SUCCESS || newState == BluetoothProfile.STATE_DISCONNECTED) {
                        merkezKapat(b);
                        return;
                    }
                    if (newState == BluetoothProfile.STATE_CONNECTED) {
                        try {
                            if (!gatt.requestMtu(517)) gatt.discoverServices();
                        } catch (SecurityException e) { merkezKapat(b); }
                    }
                });
            }

            @Override public void onMtuChanged(BluetoothGatt gatt, int mtu, int status) {
                h.post(() -> {
                    if (status == BluetoothGatt.GATT_SUCCESS) b.mtu = mtu;
                    try { gatt.discoverServices(); } catch (SecurityException e) { merkezKapat(b); }
                });
            }

            @SuppressWarnings("deprecation")
            @Override public void onServicesDiscovered(BluetoothGatt gatt, int status) {
                h.post(() -> {
                    BluetoothGattService s = gatt.getService(SERVIS);
                    BluetoothGattCharacteristic rx = s == null ? null : s.getCharacteristic(RX);
                    BluetoothGattCharacteristic tx = s == null ? null : s.getCharacteristic(TX);
                    BluetoothGattDescriptor d = tx == null ? null : tx.getDescriptor(CCCD);
                    if (status != BluetoothGatt.GATT_SUCCESS || rx == null || d == null) {
                        try { gatt.disconnect(); } catch (Exception ignored) { }
                        merkezKapat(b);
                        return;
                    }
                    b.rx = rx;
                    try {
                        gatt.setCharacteristicNotification(tx, true);
                        boolean ok;
                        if (Build.VERSION.SDK_INT >= 33) {
                            ok = gatt.writeDescriptor(d, BluetoothGattDescriptor.ENABLE_NOTIFICATION_VALUE) == BluetoothStatusCodes.SUCCESS;
                        } else {
                            d.setValue(BluetoothGattDescriptor.ENABLE_NOTIFICATION_VALUE);
                            ok = gatt.writeDescriptor(d);
                        }
                        if (!ok) { gatt.disconnect(); merkezKapat(b); }
                    } catch (SecurityException e) { merkezKapat(b); }
                });
            }

            @Override public void onDescriptorWrite(BluetoothGatt gatt, BluetoothGattDescriptor descriptor, int status) {
                h.post(() -> {
                    if (status != BluetoothGatt.GATT_SUCCESS) {
                        try { gatt.disconnect(); } catch (Exception ignored) { }
                        merkezKapat(b);
                        return;
                    }
                    if (!b.hazir) {
                        b.hazir = true;
                        bildir();
                        olaylar.yeniBaglanti(b.id);
                    }
                });
            }

            @Override public void onCharacteristicWrite(BluetoothGatt gatt, BluetoothGattCharacteristic characteristic, int status) {
                h.post(() -> { b.yolda = false; pompala(b); });
            }

            // API 33+
            @Override public void onCharacteristicChanged(BluetoothGatt gatt, BluetoothGattCharacteristic characteristic, byte[] value) {
                if (!TX.equals(characteristic.getUuid()) || value == null) return;
                final byte[] kopya = value.clone();
                h.post(() -> { if (calisiyor) cerceveAlindi(b, kopya); });
            }

            // API ≤ 32
            @SuppressWarnings("deprecation")
            @Override public void onCharacteristicChanged(BluetoothGatt gatt, BluetoothGattCharacteristic characteristic) {
                if (Build.VERSION.SDK_INT >= 33) return;
                if (!TX.equals(characteristic.getUuid())) return;
                byte[] v = characteristic.getValue();
                if (v == null) return;
                final byte[] kopya = v.clone();
                h.post(() -> { if (calisiyor) cerceveAlindi(b, kopya); });
            }
        };
    }
}
