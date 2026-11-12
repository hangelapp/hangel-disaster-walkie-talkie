// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Uluslararası Sosyal Fayda Derneği (Social Business Global)
package org.hangel.walkietalkie.telsiz;

import java.util.ArrayList;
import java.util.HashMap;
import java.util.Iterator;
import java.util.List;
import java.util.Map;

/**
 * Bluetooth LE çerçeveleme — src/protocol/frame.ts (cercevele / cerceveCoz / Birlestirici) ile aynı kurallar.
 * [0] sürüm(1) · [1..4] mesaj sırası (uint32 BE) · [5..6] parça (uint16 BE) · [7..8] parça sayısı (uint16 BE) · [9..] dilim.
 */
public final class TelsizCerceve {
    private TelsizCerceve() {}

    public static final int SURUM = 1;
    public static final int BASLIK = 9;
    public static final int MAKS_YUK = 262_144;
    public static final long ZAMAN_ASIMI_MS = 60_000;
    public static final int MAKS_YARIM = 4;

    public static List<byte[]> cercevele(byte[] yuk, long sira, int parcaBoyutu) {
        if (yuk.length == 0 || yuk.length > MAKS_YUK) throw new IllegalArgumentException("yuk-boyutu");
        int dilim = parcaBoyutu - BASLIK;
        if (dilim < 1) throw new IllegalArgumentException("parca-boyutu");
        int sayi = (yuk.length + dilim - 1) / dilim;
        if (sayi > 0xffff) throw new IllegalArgumentException("parca-sayisi");
        List<byte[]> cikti = new ArrayList<>(sayi);
        for (int i = 0; i < sayi; i++) {
            int bas = i * dilim;
            int uzun = Math.min(dilim, yuk.length - bas);
            byte[] c = new byte[BASLIK + uzun];
            c[0] = (byte) SURUM;
            c[1] = (byte) (sira >>> 24);
            c[2] = (byte) (sira >>> 16);
            c[3] = (byte) (sira >>> 8);
            c[4] = (byte) sira;
            c[5] = (byte) (i >>> 8);
            c[6] = (byte) i;
            c[7] = (byte) (sayi >>> 8);
            c[8] = (byte) sayi;
            System.arraycopy(yuk, bas, c, BASLIK, uzun);
            cikti.add(c);
        }
        return cikti;
    }

    /** Bağlantı başına bir tane. İş parçacığı güvenli değildir (motorun tek iş parçacığında kullanılır). */
    public static final class Birlestirici {
        private static final class Yarim {
            byte[][] parcalar;
            int gelen;
            int bayt;
            long ilkMs;
        }

        private final Map<Long, Yarim> yarim = new HashMap<>();

        public byte[] ekle(byte[] c, long simdi) {
            if (c == null || c.length <= BASLIK || (c[0] & 0xff) != SURUM) return null;
            long sira = ((long) (c[1] & 0xff) << 24) | ((c[2] & 0xff) << 16) | ((c[3] & 0xff) << 8) | (c[4] & 0xff);
            int parca = ((c[5] & 0xff) << 8) | (c[6] & 0xff);
            int sayi = ((c[7] & 0xff) << 8) | (c[8] & 0xff);
            if (sayi < 1 || parca >= sayi) return null;
            Iterator<Map.Entry<Long, Yarim>> it = yarim.entrySet().iterator();
            while (it.hasNext()) if (simdi - it.next().getValue().ilkMs > ZAMAN_ASIMI_MS) it.remove();
            Yarim y = yarim.get(sira);
            if (y == null) {
                if (yarim.size() >= MAKS_YARIM) {
                    Long enEski = null;
                    long ms = Long.MAX_VALUE;
                    for (Map.Entry<Long, Yarim> e : yarim.entrySet()) if (e.getValue().ilkMs < ms) { ms = e.getValue().ilkMs; enEski = e.getKey(); }
                    if (enEski != null) yarim.remove(enEski);
                }
                y = new Yarim();
                y.parcalar = new byte[sayi][];
                y.ilkMs = simdi;
                yarim.put(sira, y);
            }
            if (y.parcalar.length != sayi) { yarim.remove(sira); return null; }
            if (y.parcalar[parca] != null) return null;
            byte[] d = new byte[c.length - BASLIK];
            System.arraycopy(c, BASLIK, d, 0, d.length);
            y.parcalar[parca] = d;
            y.gelen++;
            y.bayt += d.length;
            if (y.bayt > MAKS_YUK) { yarim.remove(sira); return null; }
            if (y.gelen < sayi) return null;
            yarim.remove(sira);
            byte[] tum = new byte[y.bayt];
            int o = 0;
            for (byte[] p : y.parcalar) { System.arraycopy(p, 0, tum, o, p.length); o += p.length; }
            return tum;
        }

        public int bekleyen() { return yarim.size(); }
    }
}
