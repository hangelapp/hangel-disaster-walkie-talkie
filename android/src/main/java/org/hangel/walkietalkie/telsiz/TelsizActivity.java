// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Uluslararası Sosyal Fayda Derneği (Social Business Global)
package org.hangel.walkietalkie.telsiz;

import android.Manifest;
import android.annotation.SuppressLint;
import android.bluetooth.BluetoothAdapter;
import android.content.Intent;
import android.content.pm.PackageManager;
import android.graphics.Color;
import android.graphics.Typeface;
import android.graphics.drawable.GradientDrawable;
import android.location.Location;
import android.location.LocationManager;
import android.net.Uri;
import android.os.Build;
import android.os.Bundle;
import android.os.CancellationSignal;
import android.os.Handler;
import android.os.Looper;
import android.text.InputFilter;
import android.text.InputType;
import android.text.format.DateUtils;
import android.util.TypedValue;
import android.view.Gravity;
import android.view.MotionEvent;
import android.view.View;
import android.view.ViewGroup;
import android.view.WindowManager;
import android.view.inputmethod.EditorInfo;
import android.widget.BaseAdapter;
import android.widget.Button;
import android.widget.CheckBox;
import android.widget.EditText;
import android.widget.LinearLayout;
import android.widget.ListView;
import android.widget.TextView;

import androidx.annotation.NonNull;
import androidx.appcompat.app.AppCompatActivity;
import androidx.core.app.ActivityCompat;
import androidx.core.content.ContextCompat;
import androidx.core.content.pm.ShortcutInfoCompat;
import androidx.core.content.pm.ShortcutManagerCompat;
import androidx.core.graphics.drawable.IconCompat;


import java.util.ArrayList;
import java.util.List;
import java.util.Locale;
import java.util.function.Consumer;

/**
 * Afet Telsizi — Android yerel yedek ekranı (internetsiz açılır). Açılış: eklentinin `ac` yöntemi (JS openNativeScreen) ve
 * kullanıcının bu ekrandan eklediği ana ekran kısayolu.
 * İzinler yalnız bu ekran açılınca istenir: Bluetooth (Yakındaki cihazlar; Android 11 ve altında konum), mikrofon ilk
 * bas-konuşta, konum yalnız "Konumumu ekle" işaretlenince. Ekran açıkken kilitlenmez.
 */
public class TelsizActivity extends AppCompatActivity implements TelsizMotoru.Dinleyici {
    private static final int IZIN_BLUETOOTH = 7101;
    private static final int IZIN_MIKROFON = 7102;
    private static final int IZIN_KONUM = 7103;
    private static final int BLUETOOTH_AC = 7104;
    private static final int NAR = Color.rgb(243, 71, 35);

    private TelsizMotoru motor;
    private TelsizMetin m;
    private TextView durumInternet, durumBagli, bilgi, uyari, testPaneli;
    private Button bluetoothAcDugme;
    private View mikrofon;
    private EditText metinKutusu;
    private CheckBox konumKutusu;
    private Adaptor adaptor;
    private boolean basili;
    private final Handler ana = new Handler(Looper.getMainLooper());

    private int dp(float v) {
        return Math.round(TypedValue.applyDimension(TypedValue.COMPLEX_UNIT_DIP, v, getResources().getDisplayMetrics()));
    }

    private boolean koyu() {
        return (getResources().getConfiguration().uiMode & android.content.res.Configuration.UI_MODE_NIGHT_MASK)
                == android.content.res.Configuration.UI_MODE_NIGHT_YES;
    }

    @Override
    protected void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);
        ekran();
    }

    /**
     * Yerel yedek ekran. Not: hangel uygulamasında 2026-11-05'ten beri arayüz web sayfasındadır; bu ekran o tarihten beri üretimde
     * kullanılmadı. Açık kaynak sürümde JS openNativeScreen() (eklenti `ac`) ile açılan basit bir yedek olarak duruyor.
     */
    private void ekran() {
        m = TelsizMetin.simdiki();
        motor = TelsizMotoru.al(this);
        getWindow().addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON);
        setContentView(arayuz());
        if (!TelsizMotoru.destekleniyor(this)) {
            uyari.setText(m.desteklenmiyor);
            uyari.setVisibility(View.VISIBLE);
            mikrofon.setEnabled(false);
            return;
        }
        bluetoothIzinleriniIste();
    }

    @Override
    protected void onResume() {
        super.onResume();
        if (motor == null) return;
        motor.dinle(this);
        degisti();
        if (TelsizMotoru.destekleniyor(this) && bluetoothIzniVar()) motor.baslat(this::degisti);
    }

    @Override
    protected void onPause() {
        super.onPause();
        if (motor == null) return;
        motor.birak(this);
        if (basili) { basili = false; motor.kayitBitir(); }
    }

    @Override
    protected void onDestroy() {
        super.onDestroy();
        // Telsiz yalnız ekran açıkken çalışır (iOS ile aynı): radyoyu bırak.
        // Yönlendirmede motor hiç alınmaz (null) ve sayfa motoru kullanır → durdurulmaz.
        if (isFinishing() && motor != null) motor.durdur();
    }

    // MARK: İzinler

    private String[] bluetoothIzinleri() {
        if (Build.VERSION.SDK_INT >= 31) {
            return new String[]{Manifest.permission.BLUETOOTH_SCAN, Manifest.permission.BLUETOOTH_ADVERTISE, Manifest.permission.BLUETOOTH_CONNECT};
        }
        return new String[]{Manifest.permission.ACCESS_FINE_LOCATION};
    }

    private boolean bluetoothIzniVar() {
        for (String p : bluetoothIzinleri()) {
            if (ContextCompat.checkSelfPermission(this, p) != PackageManager.PERMISSION_GRANTED) return false;
        }
        return true;
    }

    private void bluetoothIzinleriniIste() {
        if (bluetoothIzniVar()) return;
        String[] izinler = bluetoothIzinleri();
        // İsteğe bağlı Nearby derlemesinde Android 13+ "yakındaki Wi-Fi cihazları" da aynı pencerede sorulur (bkz. EkTasima).
        String[] ek = TelsizMotoru.ekIzinler();
        if (ek.length > 0) {
            int n = izinler.length;
            izinler = java.util.Arrays.copyOf(izinler, n + ek.length);
            System.arraycopy(ek, 0, izinler, n, ek.length);
        }
        ActivityCompat.requestPermissions(this, izinler, IZIN_BLUETOOTH);
    }

    @Override
    public void onRequestPermissionsResult(int requestCode, @NonNull String[] permissions, @NonNull int[] grantResults) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults);
        if (requestCode == IZIN_BLUETOOTH) {
            if (bluetoothIzniVar()) motor.baslat(this::degisti);
            degisti();
        } else if (requestCode == IZIN_MIKROFON) {
            degisti();
        } else if (requestCode == IZIN_KONUM) {
            if (!konumIzniVar()) konumKutusu.setChecked(false);
        }
    }

    @Override
    protected void onActivityResult(int requestCode, int resultCode, Intent data) {
        super.onActivityResult(requestCode, resultCode, data);
        if (requestCode == BLUETOOTH_AC && bluetoothIzniVar()) motor.baslat(this::degisti);
    }

    private boolean konumIzniVar() {
        return ContextCompat.checkSelfPermission(this, Manifest.permission.ACCESS_FINE_LOCATION) == PackageManager.PERMISSION_GRANTED
                || ContextCompat.checkSelfPermission(this, Manifest.permission.ACCESS_COARSE_LOCATION) == PackageManager.PERMISSION_GRANTED;
    }

    // MARK: Arayüz

    private TextView yazi(float sp, boolean kalin, int renk) {
        TextView t = new TextView(this);
        t.setTextSize(TypedValue.COMPLEX_UNIT_SP, sp);
        if (kalin) t.setTypeface(Typeface.DEFAULT, Typeface.BOLD);
        t.setTextColor(renk);
        return t;
    }

    private GradientDrawable kapsul(int renk, float yaricap) {
        GradientDrawable g = new GradientDrawable();
        g.setColor(renk);
        g.setCornerRadius(dp(yaricap));
        return g;
    }

    @SuppressLint("ClickableViewAccessibility")
    private View arayuz() {
        int on = koyu() ? Color.WHITE : Color.rgb(23, 23, 23);
        int ikincil = koyu() ? Color.rgb(170, 170, 170) : Color.rgb(100, 100, 100);
        int zemin = koyu() ? Color.rgb(18, 18, 18) : Color.rgb(245, 245, 247);
        int kart = koyu() ? Color.rgb(38, 38, 38) : Color.WHITE;

        LinearLayout kok = new LinearLayout(this);
        kok.setOrientation(LinearLayout.VERTICAL);
        kok.setBackgroundColor(zemin);
        kok.setPadding(dp(16), dp(16), dp(16), dp(12));
        kok.setFitsSystemWindows(true);

        // Başlık
        LinearLayout ust = new LinearLayout(this);
        ust.setGravity(Gravity.CENTER_VERTICAL);
        LinearLayout basliklar = new LinearLayout(this);
        basliklar.setOrientation(LinearLayout.VERTICAL);
        TextView baslik = yazi(24, true, on);
        baslik.setText(m.baslik);
        if (Build.VERSION.SDK_INT >= 28) baslik.setAccessibilityHeading(true);
        TextView kanal = yazi(14, false, ikincil);
        kanal.setText(motor.kanalGorunen());
        basliklar.addView(baslik);
        basliklar.addView(kanal);
        ust.addView(basliklar, new LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1));
        Button kapat = new Button(this);
        kapat.setText(m.kapat);
        kapat.setAllCaps(false);
        kapat.setOnClickListener(v -> finish());
        ust.addView(kapat);
        kok.addView(ust);

        // Durum kapsülleri
        LinearLayout durum = new LinearLayout(this);
        durum.setPadding(0, dp(10), 0, dp(4));
        durumInternet = yazi(13, true, on);
        durumInternet.setPadding(dp(10), dp(6), dp(10), dp(6));
        durumInternet.setBackground(kapsul(koyu() ? Color.rgb(50, 50, 50) : Color.rgb(230, 230, 232), 999));
        durumBagli = yazi(13, true, on);
        durumBagli.setPadding(dp(10), dp(6), dp(10), dp(6));
        LinearLayout.LayoutParams lp = new LinearLayout.LayoutParams(ViewGroup.LayoutParams.WRAP_CONTENT, ViewGroup.LayoutParams.WRAP_CONTENT);
        lp.setMarginStart(dp(8));
        durum.addView(durumInternet);
        durum.addView(durumBagli, lp);
        kok.addView(durum);

        // Bluetooth / destek uyarısı
        uyari = yazi(14, false, Color.rgb(180, 83, 9));
        uyari.setVisibility(View.GONE);
        uyari.setPadding(0, dp(6), 0, dp(2));
        kok.addView(uyari);
        bluetoothAcDugme = new Button(this);
        bluetoothAcDugme.setAllCaps(false);
        bluetoothAcDugme.setText(m.bluetoothAc);
        bluetoothAcDugme.setVisibility(View.GONE);
        bluetoothAcDugme.setOnClickListener(v -> bluetoothuAc());
        kok.addView(bluetoothAcDugme);

        // Bas-konuş
        LinearLayout orta = new LinearLayout(this);
        orta.setOrientation(LinearLayout.VERTICAL);
        orta.setGravity(Gravity.CENTER_HORIZONTAL);
        orta.setPadding(0, dp(8), 0, dp(4));
        TextView mik = new TextView(this);
        mik.setText("🎙");
        mik.setTextSize(TypedValue.COMPLEX_UNIT_SP, 52);
        mik.setGravity(Gravity.CENTER);
        GradientDrawable daire = new GradientDrawable();
        daire.setShape(GradientDrawable.OVAL);
        daire.setColor(NAR);
        mik.setBackground(daire);
        mik.setContentDescription(m.basKonus);
        mik.setFocusable(true);
        mik.setClickable(true);
        mik.setOnTouchListener((v, e) -> {
            switch (e.getActionMasked()) {
                case MotionEvent.ACTION_DOWN:
                    if (ContextCompat.checkSelfPermission(this, Manifest.permission.RECORD_AUDIO) != PackageManager.PERMISSION_GRANTED) {
                        ActivityCompat.requestPermissions(this, new String[]{Manifest.permission.RECORD_AUDIO}, IZIN_MIKROFON);
                        return true;
                    }
                    basili = true;
                    v.setScaleX(1.06f);
                    v.setScaleY(1.06f);
                    motor.kayitBaslat();
                    return true;
                case MotionEvent.ACTION_UP:
                case MotionEvent.ACTION_CANCEL:
                    v.setScaleX(1f);
                    v.setScaleY(1f);
                    if (basili) { basili = false; motor.kayitBitir(); }
                    return true;
                default:
                    return true;
            }
        });
        // Ekran okuyucu: çift dokunuş kaydı başlatır, ikinci çift dokunuş gönderir.
        mik.setOnClickListener(v -> {
            if (motor.kayittaMi()) motor.kayitBitir(); else if (!basili) motor.kayitBaslat();
        });
        mikrofon = mik;
        orta.addView(mik, new LinearLayout.LayoutParams(dp(150), dp(150)));
        bilgi = yazi(16, true, on);
        bilgi.setGravity(Gravity.CENTER);
        bilgi.setPadding(0, dp(10), 0, 0);
        bilgi.setAccessibilityLiveRegion(View.ACCESSIBILITY_LIVE_REGION_POLITE);
        orta.addView(bilgi);
        kok.addView(orta);

        // Metin + konum
        LinearLayout satir = new LinearLayout(this);
        satir.setGravity(Gravity.CENTER_VERTICAL);
        satir.setPadding(0, dp(10), 0, 0);
        metinKutusu = new EditText(this);
        metinKutusu.setHint(m.metinIpucu);
        metinKutusu.setFilters(new InputFilter[]{new InputFilter.LengthFilter(TelsizMotoru.MAKS_METIN)});
        // Tek satır girişi gibi "Gönder" tuşu, ama uzun metin 3 satıra kadar sarılır.
        metinKutusu.setInputType(InputType.TYPE_CLASS_TEXT | InputType.TYPE_TEXT_FLAG_CAP_SENTENCES);
        metinKutusu.setImeOptions(EditorInfo.IME_ACTION_SEND);
        metinKutusu.setHorizontallyScrolling(false);
        metinKutusu.setMaxLines(3);
        metinKutusu.setTextColor(on);
        metinKutusu.setHintTextColor(ikincil);
        metinKutusu.setOnEditorActionListener((v, id, e) -> { if (id == EditorInfo.IME_ACTION_SEND) { metniGonder(); return true; } return false; });
        satir.addView(metinKutusu, new LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1));
        Button gonder = new Button(this);
        gonder.setAllCaps(false);
        gonder.setText(m.gonder);
        gonder.setOnClickListener(v -> metniGonder());
        satir.addView(gonder);
        kok.addView(satir);
        konumKutusu = new CheckBox(this);
        konumKutusu.setText(m.konumEkle);
        konumKutusu.setTextColor(on);
        konumKutusu.setOnCheckedChangeListener((b, secili) -> {
            if (secili && !konumIzniVar()) {
                ActivityCompat.requestPermissions(this, new String[]{Manifest.permission.ACCESS_FINE_LOCATION, Manifest.permission.ACCESS_COARSE_LOCATION}, IZIN_KONUM);
            }
        });
        kok.addView(konumKutusu);

        // Mesajlar
        ListView liste = new ListView(this);
        liste.setDivider(null);
        liste.setDividerHeight(dp(6));
        adaptor = new Adaptor(on, ikincil, kart);
        liste.setAdapter(adaptor);
        TextView bos = yazi(13, false, ikincil);
        bos.setText(m.mesajYok);
        bos.setGravity(Gravity.CENTER);
        bos.setPadding(dp(8), dp(16), dp(8), dp(16));
        ((ViewGroup) kok).addView(bos, new LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT));
        liste.setEmptyView(bos);
        kok.addView(liste, new LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, 0, 1));

        // Test paneli (start({debugPanel: true}))
        testPaneli = yazi(11, false, ikincil);
        testPaneli.setTypeface(Typeface.MONOSPACE);
        testPaneli.setVisibility(motor.testPaneliMi() ? View.VISIBLE : View.GONE);
        kok.addView(testPaneli);

        // Ana ekran kısayolu (internetsiz açmak için) + not
        if (ShortcutManagerCompat.isRequestPinShortcutSupported(this)) {
            Button kisayol = new Button(this);
            kisayol.setAllCaps(false);
            kisayol.setText(m.anaEkranaEkle);
            kisayol.setOnClickListener(v -> anaEkranaEkle());
            kok.addView(kisayol);
        }
        TextView not = yazi(11, false, ikincil);
        not.setText(m.ekranAcik);
        not.setGravity(Gravity.CENTER);
        kok.addView(not);
        return kok;
    }

    private void anaEkranaEkle() {
        Intent i = new Intent(Intent.ACTION_VIEW).setClass(this, TelsizActivity.class);
        ShortcutInfoCompat k = new ShortcutInfoCompat.Builder(this, "afet-telsizi")
                .setShortLabel(m.baslik)
                .setLongLabel(m.baslik)
                .setIcon(IconCompat.createWithResource(this, getApplicationInfo().icon))
                .setIntent(i)
                .build();
        ShortcutManagerCompat.requestPinShortcut(this, k, null);
    }

    @SuppressWarnings("deprecation")
    @SuppressLint("MissingPermission") // bluetoothIzniVar() hemen üstte denetlenir
    private void bluetoothuAc() {
        if (!bluetoothIzniVar()) { bluetoothIzinleriniIste(); return; }
        try {
            startActivityForResult(new Intent(BluetoothAdapter.ACTION_REQUEST_ENABLE), BLUETOOTH_AC);
        } catch (Exception ignored) { }
    }

    private void metniGonder() {
        String t = metinKutusu.getText() == null ? "" : metinKutusu.getText().toString();
        if (TelsizMotoru.metinTemizle(t) == null) return;
        metinKutusu.setText("");
        if (konumKutusu.isChecked() && konumIzniVar()) {
            konumAl(k -> {
                if (k == null) motor.bilgiVer(m.konumYok);
                motor.metinGonder(t, k == null ? null : k.getLatitude(), k == null ? null : k.getLongitude());
            });
        } else {
            motor.metinGonder(t, null, null);
        }
    }

    /** Tek seferlik konum (GPS internetsiz çalışır). 15 sn içinde gelmezse son bilinen; o da yoksa null. */
    @SuppressLint("MissingPermission")
    private void konumAl(Consumer<Location> sonuc) {
        LocationManager lm = (LocationManager) getSystemService(LOCATION_SERVICE);
        if (lm == null) { sonuc.accept(null); return; }
        final boolean[] bitti = {false};
        Consumer<Location> bir = k -> {
            if (bitti[0]) return;
            bitti[0] = true;
            Location son = k;
            if (son == null) {
                try {
                    for (String p : new String[]{LocationManager.GPS_PROVIDER, LocationManager.NETWORK_PROVIDER, LocationManager.PASSIVE_PROVIDER}) {
                        Location x = lm.getLastKnownLocation(p);
                        if (x != null && (son == null || x.getTime() > son.getTime())) son = x;
                    }
                } catch (Exception ignored) { }
            }
            sonuc.accept(son);
        };
        ana.postDelayed(() -> bir.accept(null), 15_000);
        try {
            if (Build.VERSION.SDK_INT >= 30) {
                String saglayici = lm.isProviderEnabled(LocationManager.GPS_PROVIDER) ? LocationManager.GPS_PROVIDER : LocationManager.NETWORK_PROVIDER;
                lm.getCurrentLocation(saglayici, new CancellationSignal(), getMainExecutor(), k -> ana.post(() -> bir.accept(k)));
            } else {
                bir.accept(null);
            }
        } catch (Exception e) {
            bir.accept(null);
        }
    }

    // MARK: Yenile

    @Override
    public void degisti() {
        if (durumInternet == null) return;
        boolean internet = motor.internetVar();
        durumInternet.setText((internet ? "📶 " : "✈︎ ") + (internet ? m.cevrimici : m.internetsiz));
        int n = motor.baglilar().size();
        durumBagli.setText("📡 " + n + " " + m.bagliTelefon);
        durumBagli.setBackground(kapsul(n > 0 ? Color.argb(46, 34, 197, 94) : (koyu() ? Color.rgb(50, 50, 50) : Color.rgb(230, 230, 232)), 999));
        if (TelsizMotoru.destekleniyor(this)) {
            boolean btKapali = !motor.bluetoothAcik();
            boolean izinYok = !bluetoothIzniVar();
            uyari.setVisibility(btKapali || izinYok ? View.VISIBLE : View.GONE);
            uyari.setText(izinYok ? m.bluetoothIzni : m.bluetoothKapali);
            bluetoothAcDugme.setVisibility(btKapali || izinYok ? View.VISIBLE : View.GONE);
        }
        String b = motor.bilgi();
        bilgi.setText(motor.kayittaMi() ? m.kaydediliyor : (b != null ? b : m.basKonus));
        mikrofon.setContentDescription(motor.kayittaMi() ? m.kaydediliyor : m.basKonus);
        if (testPaneli.getVisibility() == View.VISIBLE) {
            StringBuilder s = new StringBuilder("peer: ").append(android.text.TextUtils.join(", ", motor.baglilar()));
            for (TelsizMotoru.Mesaj x : motor.mesajlar()) {
                if (x.kendim) continue;
                s.append("\nson: ").append(x.atlama).append(' ').append(m.aktarim).append(" · ").append(m.teslim).append(' ')
                        .append(String.format(Locale.US, "%.1f", Math.max(0, x.alindiMs - x.t) / 1000.0)).append(" s");
                break;
            }
            testPaneli.setText(s.toString());
        }
        adaptor.yenile(motor.mesajlar());
    }

    // MARK: Liste

    private final class Adaptor extends BaseAdapter {
        private final int on, ikincil, kart;
        private List<TelsizMotoru.Mesaj> l = new ArrayList<>();

        Adaptor(int on, int ikincil, int kart) {
            this.on = on;
            this.ikincil = ikincil;
            this.kart = kart;
        }

        void yenile(List<TelsizMotoru.Mesaj> yeni) {
            l = new ArrayList<>(yeni);
            notifyDataSetChanged();
        }

        @Override public int getCount() { return l.size(); }
        @Override public Object getItem(int i) { return l.get(i); }
        @Override public long getItemId(int i) { return l.get(i).id.hashCode(); }

        @Override
        public View getView(int i, View eski, ViewGroup ust) {
            TelsizMotoru.Mesaj x = l.get(i);
            TelsizMotoru.Icerik ic = TelsizMotoru.coz(x);
            boolean metin = TelsizMotoru.METIN_MIME.equals(x.mime);
            LinearLayout s = new LinearLayout(TelsizActivity.this);
            s.setGravity(Gravity.CENTER_VERTICAL);
            s.setPadding(dp(12), dp(10), dp(12), dp(10));
            boolean calan = x.id.equals(motor.calan());
            s.setBackground(kapsul(calan ? Color.argb(30, 220, 38, 38) : kart, 16));
            TextView simge = yazi(22, false, NAR);
            simge.setText(metin ? "✉" : (calan ? "🔊" : "▶"));
            simge.setPadding(0, 0, dp(12), 0);
            simge.setImportantForAccessibility(View.IMPORTANT_FOR_ACCESSIBILITY_NO);
            s.addView(simge);
            LinearLayout sag = new LinearLayout(TelsizActivity.this);
            sag.setOrientation(LinearLayout.VERTICAL);
            TextView ad = yazi(15, true, on);
            String gorunen = x.kendim ? m.sen : (ic == null || ic.ad.isEmpty() ? TelsizMetin.uygulamaAdi : ic.ad);
            ad.setText(gorunen);
            sag.addView(ad);
            if (metin && ic != null && ic.metin != null) {
                TextView govde = yazi(15, false, on);
                govde.setText(ic.metin);
                govde.setTextIsSelectable(true);
                sag.addView(govde);
            }
            if (ic != null && ic.enlem != null) {
                TextView konum = yazi(13, true, NAR);
                String k = String.format(Locale.US, "%.5f, %.5f", ic.enlem, ic.boylam);
                konum.setText("📍 " + m.konum + ": " + k);
                konum.setOnClickListener(v -> {
                    try {
                        startActivity(new Intent(Intent.ACTION_VIEW, Uri.parse("geo:" + k + "?q=" + k)));
                    } catch (Exception ignored) { }
                });
                sag.addView(konum);
            }
            TextView alt = yazi(12, false, ikincil);
            String zaman = DateUtils.getRelativeTimeSpanString(x.t, System.currentTimeMillis(), DateUtils.MINUTE_IN_MILLIS).toString();
            String sn = metin ? "" : " · " + Math.max(1, x.sure / 1000) + " s";
            alt.setText(zaman + sn + (x.kendim ? "" : " · " + x.atlama + " " + m.aktarim));
            sag.addView(alt);
            s.addView(sag, new LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1));
            if (!metin) {
                s.setOnClickListener(v -> motor.cal(x));
                s.setContentDescription(gorunen + ", " + alt.getText());
            }
            return s;
        }
    }
}
