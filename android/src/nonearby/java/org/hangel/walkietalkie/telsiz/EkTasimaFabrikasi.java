// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Uluslararası Sosyal Fayda Derneği (Social Business Global)
package org.hangel.walkietalkie.telsiz;

import android.content.Context;
import android.os.Handler;

/** Varsayılan derleme: ek taşıma yok (yalnız Bluetooth LE). Bkz. EkTasima. */
final class EkTasimaFabrikasi {
    private EkTasimaFabrikasi() { }

    static EkTasima olustur(Context ctx, Handler h, TelsizBle.Olaylar olaylar) {
        return new EkTasima() {
            @Override public void baslat() { }
            @Override public void durdur() { }
            @Override public boolean calisiyorMu() { return false; }
            @Override public void gonder(byte[] yuk, String haric) { }
            @Override public void gonderKime(String baglanti, byte[] yuk) { }
        };
    }

    /** Ek izin yok. */
    static String[] ekIzinler() {
        return new String[0];
    }
}
