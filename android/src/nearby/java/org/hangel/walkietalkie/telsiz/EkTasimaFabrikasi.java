// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Uluslararası Sosyal Fayda Derneği (Social Business Global)
package org.hangel.walkietalkie.telsiz;

import android.Manifest;
import android.content.Context;
import android.os.Build;
import android.os.Handler;

/** `walkieTalkieNearby=true` derlemesi: Google Nearby Connections ek taşıması (TelsizYakin). Bkz. EkTasima. */
final class EkTasimaFabrikasi {
    private EkTasimaFabrikasi() { }

    static EkTasima olustur(Context ctx, Handler h, TelsizBle.Olaylar olaylar) {
        return new TelsizYakin(ctx, h, olaylar);
    }

    /** Android 13+ "yakındaki Wi-Fi cihazları" (Nearby Connections'ın Wi-Fi yükseltmesi için). */
    static String[] ekIzinler() {
        if (Build.VERSION.SDK_INT >= 33) return new String[]{Manifest.permission.NEARBY_WIFI_DEVICES};
        return new String[0];
    }
}
