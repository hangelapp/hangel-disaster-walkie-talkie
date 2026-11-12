// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Uluslararası Sosyal Fayda Derneği (Social Business Global)
package org.hangel.walkietalkie;

import android.Manifest;
import android.content.Intent;
import android.content.pm.PackageManager;
import android.os.Build;
import android.view.WindowManager;

import androidx.core.app.ActivityCompat;
import androidx.core.content.ContextCompat;

import com.getcapacitor.JSArray;
import com.getcapacitor.JSObject;
import com.getcapacitor.Plugin;
import com.getcapacitor.PluginCall;
import com.getcapacitor.PluginMethod;
import com.getcapacitor.annotation.CapacitorPlugin;
import org.hangel.walkietalkie.telsiz.TelsizActivity;
import org.hangel.walkietalkie.telsiz.TelsizMotoru;

import org.json.JSONArray;

import java.util.ArrayList;
import java.util.List;

/**
 * JS ↔ Afet Telsizi (Android) köprüsü — iOS DisasterWalkieTalkiePlugin.swift ile aynı yöntem adları (sözleşme: docs/native-bridge.md;
 * İngilizce sarmalayıcı: src/index.ts). Yöntemler: durum · motor · kanalSec · izinIste · kayitBaslat · kayitBitir · metinGonder ·
 * durumGonder · liste · cal · disaridan · birak · ac · bekleyenler · yuklendi · duyuruYay; her değişiklikte "degisti" olayı.
 * AĞ v3 yöntemleri (cihazlar, davet, yardım çağrısı) Android'de HENÜZ YOK — README "Limitations".
 */
@CapacitorPlugin(name = "DisasterWalkieTalkie")
public class DisasterWalkieTalkiePlugin extends Plugin {
    private static final int IZIN_KODU = 7301;
    private final TelsizMotoru.Dinleyici dinleyici = () -> notifyListeners("degisti", new JSObject());

    @Override
    public void load() {
        if (TelsizMotoru.destekleniyor(getContext())) TelsizMotoru.al(getContext()).dinle(dinleyici);
    }

    private String[] bluetoothIzinleri() {
        if (Build.VERSION.SDK_INT >= 31) {
            return new String[]{Manifest.permission.BLUETOOTH_SCAN, Manifest.permission.BLUETOOTH_ADVERTISE, Manifest.permission.BLUETOOTH_CONNECT};
        }
        return new String[]{Manifest.permission.ACCESS_FINE_LOCATION};
    }

    private boolean izinliMi(String p) {
        return ContextCompat.checkSelfPermission(getContext(), p) == PackageManager.PERMISSION_GRANTED;
    }

    private boolean bluetoothIzniVar() {
        for (String p : bluetoothIzinleri()) if (!izinliMi(p)) return false;
        return true;
    }

    private JSObject durumNesnesi() {
        JSObject r = new JSObject();
        boolean destek = TelsizMotoru.destekleniyor(getContext());
        r.put("kullanilabilir", destek);
        r.put("surum", 2);
        if (!destek) return r;
        TelsizMotoru m = TelsizMotoru.al(getContext());
        r.put("calisiyor", m.calisiyor());
        r.put("bagli", m.baglilar().size());
        r.put("internetVar", m.internetVar());
        r.put("kayitta", m.kayittaMi());
        r.put("calanId", m.calan());
        r.put("bluetoothIzni", bluetoothIzniVar() ? "var" : "bilinmiyor");
        r.put("mikrofonIzni", izinliMi(Manifest.permission.RECORD_AUDIO) ? "var" : "bilinmiyor");
        r.put("bluetoothAcik", m.bluetoothAcik());
        r.put("kanal", m.kanal());
        int[] ozet = m.durumOzeti();
        JSObject d = new JSObject();
        d.put("guvende", ozet[0]);
        d.put("toplanma", ozet[1]);
        d.put("yardim", ozet[2]);
        r.put("durumOzet", d);
        return r;
    }

    @PluginMethod
    public void durum(PluginCall call) {
        call.resolve(durumNesnesi());
    }

    @PluginMethod
    public void motor(PluginCall call) {
        if (!TelsizMotoru.destekleniyor(getContext())) {
            call.resolve(durumNesnesi());
            return;
        }
        TelsizMotoru m = TelsizMotoru.al(getContext());
        m.otomatikCal = false;
        m.ayarla(call.getString("kanal"), call.getString("kanalAdi"), call.getString("ad"), call.getBoolean("testPaneli"));
        getActivity().runOnUiThread(() -> getActivity().getWindow().addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON));
        if (bluetoothIzniVar()) m.baslat(() -> call.resolve(durumNesnesi()));
        else call.resolve(durumNesnesi());
    }

    @PluginMethod
    public void kanalSec(PluginCall call) {
        if (TelsizMotoru.destekleniyor(getContext())) {
            TelsizMotoru.al(getContext()).ayarla(call.getString("kanal"), call.getString("kanalAdi"), null, null);
        }
        call.resolve();
    }

    /** Bluetooth (ve mikrofon) izinlerini sorar; sonuç sayfanın durum() yoklamasıyla görülür, izin gelince motor başlar. */
    @PluginMethod
    public void izinIste(PluginCall call) {
        List<String> eksik = new ArrayList<>();
        for (String p : bluetoothIzinleri()) if (!izinliMi(p)) eksik.add(p);
        if (!izinliMi(Manifest.permission.RECORD_AUDIO)) eksik.add(Manifest.permission.RECORD_AUDIO);
        // İsteğe bağlı Nearby derlemesinde Android 13+ "yakındaki Wi-Fi cihazları" da sorulur (bkz. telsiz/EkTasima). Verilmezse yalnız BLE çalışır.
        for (String p : TelsizMotoru.ekIzinler()) if (!izinliMi(p)) eksik.add(p);
        if (!eksik.isEmpty()) ActivityCompat.requestPermissions(getActivity(), eksik.toArray(new String[0]), IZIN_KODU);
        else if (TelsizMotoru.destekleniyor(getContext())) TelsizMotoru.al(getContext()).baslat(null);
        call.resolve(durumNesnesi());
    }

    @PluginMethod
    public void kayitBaslat(PluginCall call) {
        if (!izinliMi(Manifest.permission.RECORD_AUDIO)) {
            ActivityCompat.requestPermissions(getActivity(), new String[]{Manifest.permission.RECORD_AUDIO}, IZIN_KODU);
            call.resolve(durumNesnesi());
            return;
        }
        if (TelsizMotoru.destekleniyor(getContext())) {
            getActivity().runOnUiThread(() -> {
                TelsizMotoru.al(getContext()).kayitBaslat();
                call.resolve(durumNesnesi());
            });
        } else {
            call.resolve(durumNesnesi());
        }
    }

    @PluginMethod
    public void kayitBitir(PluginCall call) {
        if (TelsizMotoru.destekleniyor(getContext())) {
            getActivity().runOnUiThread(() -> {
                TelsizMotoru.al(getContext()).kayitBitir();
                call.resolve();
            });
        } else {
            call.resolve();
        }
    }

    @PluginMethod
    public void metinGonder(PluginCall call) {
        if (TelsizMotoru.destekleniyor(getContext())) {
            Double a = call.getDouble("enlem");
            Double b = call.getDouble("boylam");
            TelsizMotoru.al(getContext()).metinGonder(call.getString("metin", ""), a, b);
        }
        call.resolve();
    }

    /** 2026-11-08 (Yakın ağ): "Güvendeyim" / "Toplanma alanındayım" / "Yardım lazım" durumu — yalnız web özellik anahtarı açıkken çağrılır. */
    @PluginMethod
    public void durumGonder(PluginCall call) {
        if (TelsizMotoru.destekleniyor(getContext())) {
            TelsizMotoru.al(getContext()).durumGonder(call.getString("durum", ""), call.getString("metin", ""), call.getDouble("enlem"), call.getDouble("boylam"));
        }
        call.resolve();
    }

    @PluginMethod
    public void liste(PluginCall call) {
        JSObject r = new JSObject();
        try {
            r.put("mesajlar", TelsizMotoru.destekleniyor(getContext()) ? new JSArray(TelsizMotoru.al(getContext()).webListe().toString()) : new JSArray());
        } catch (Exception e) {
            r.put("mesajlar", new JSArray());
        }
        call.resolve(r);
    }

    @PluginMethod
    public void cal(PluginCall call) {
        if (TelsizMotoru.destekleniyor(getContext())) TelsizMotoru.al(getContext()).calKimlik(call.getString("id", ""));
        call.resolve();
    }

    @PluginMethod
    public void disaridan(PluginCall call) {
        JSArray a = call.getArray("mesajlar");
        if (a != null && TelsizMotoru.destekleniyor(getContext())) {
            try {
                TelsizMotoru.al(getContext()).disaridanEkle(new JSONArray(a.toString()));
            } catch (Exception ignored) { }
        }
        call.resolve();
    }

    @PluginMethod
    public void birak(PluginCall call) {
        if (TelsizMotoru.destekleniyor(getContext())) TelsizMotoru.al(getContext()).otomatikCal = true;
        getActivity().runOnUiThread(() -> getActivity().getWindow().clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON));
        call.resolve();
    }

    // MARK: Eski yöntemler (önceki web sürümleriyle uyum)

    @PluginMethod
    public void ac(PluginCall call) {
        if (!TelsizMotoru.destekleniyor(getContext())) {
            call.reject("desteklenmiyor");
            return;
        }
        TelsizMotoru.al(getContext()).ayarla(call.getString("kanal"), call.getString("kanalAdi"), call.getString("ad"), call.getBoolean("testPaneli"));
        Intent i = new Intent(getContext(), TelsizActivity.class);
        getActivity().runOnUiThread(() -> {
            getActivity().startActivity(i);
            call.resolve();
        });
    }

    @PluginMethod
    public void bekleyenler(PluginCall call) {
        if (!TelsizMotoru.destekleniyor(getContext())) {
            JSObject r = new JSObject();
            r.put("mesajlar", new JSArray());
            call.resolve(r);
            return;
        }
        TelsizMotoru.al(getContext()).bekleyenler(dizi -> {
            JSObject r = new JSObject();
            try {
                r.put("mesajlar", new JSArray(dizi.toString()));
            } catch (Exception e) {
                r.put("mesajlar", new JSArray());
            }
            call.resolve(r);
        });
    }

    @PluginMethod
    public void yuklendi(PluginCall call) {
        List<String> idler = new ArrayList<>();
        JSArray a = call.getArray("idler");
        if (a != null) {
            for (int i = 0; i < a.length(); i++) {
                String s = a.optString(i, null);
                if (s != null) idler.add(s);
            }
        }
        if (TelsizMotoru.destekleniyor(getContext())) TelsizMotoru.al(getContext()).yuklendi(idler);
        call.resolve();
    }

    @PluginMethod
    public void duyuruYay(PluginCall call) {
        if (TelsizMotoru.destekleniyor(getContext())) {
            TelsizMotoru.al(getContext()).duyuruYay(call.getString("etkinlikId", ""), call.getString("baslik", ""), call.getString("metin", ""));
        }
        call.resolve();
    }
}
