// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Uluslararası Sosyal Fayda Derneği (Social Business Global)
package org.hangel.walkietalkie.telsiz;

import static org.junit.Assert.assertArrayEquals;
import static org.junit.Assert.assertEquals;
import static org.junit.Assert.assertNull;
import static org.junit.Assert.assertTrue;

import org.junit.Test;

import java.nio.charset.StandardCharsets;
import java.util.ArrayList;
import java.util.Base64;
import java.util.Collections;
import java.util.List;

/**
 * ORTAK TEST VEKTÖRÜ — test/frame.test.ts ve scripts/cross-verify/vektor-dogrula.swift ile aynı değerler.
 * Bu test bilgisayardaki JDK'nın ChaCha20-Poly1305'iyle koşar; cihazda aynı algoritma (Conscrypt) kullanılır.
 */
public class TelsizSifreTest {
    private static final String ANAHTAR_HEX = "99e74e836c088e5a8f2b7356d048d8b42a36457e8a269466f4a4292a4fb305a7";
    private static final String VERI = "AAECAwQFBgcICQoL+0baBh95ID9tz+rXmIi0wSTal5y6VfpBjk4l3cGcR+bT9inDO1wgoKIR6mWXyJoJTuHTY05Rpo3PuG3iFwxlYZWpyY8rSAsD1b6mmb6YU88OA2wtgtBvwwVLklNe+YYpcU9JB035QaZb1YD55+BWCglN+Rn8fcwa";
    private static final String ACIK = "{\"ad\":\"Ayşe\",\"ses\":\"\",\"metin\":\"Enkaz altında 2 kişi var, su lazım\",\"enlem\":38.4237,\"boylam\":27.1428}";

    private static String hex(byte[] b) {
        StringBuilder s = new StringBuilder();
        for (byte x : b) s.append(String.format("%02x", x));
        return s.toString();
    }

    @Test
    public void anahtarTuretme() throws Exception {
        assertEquals(ANAHTAR_HEX, hex(TelsizSifre.anahtar("test")));
    }

    @Test
    public void ortakVektoruCozer() {
        byte[] acik = TelsizSifre.ac(Base64.getDecoder().decode(VERI), "test");
        assertEquals(ACIK, new String(acik, StandardCharsets.UTF_8));
    }

    @Test
    public void ayniNonceIleAyniBayt() throws Exception {
        byte[] nonce = new byte[12];
        for (int i = 0; i < 12; i++) nonce[i] = (byte) i;
        byte[] kutu = TelsizSifre.sifrele(ACIK.getBytes(StandardCharsets.UTF_8), "test", nonce);
        assertEquals(VERI, Base64.getEncoder().encodeToString(kutu));
    }

    @Test
    public void yanlisKanalVeyaBozukVeriAcilmaz() {
        byte[] kutu = Base64.getDecoder().decode(VERI);
        assertNull(TelsizSifre.ac(kutu, "il-izmir"));
        kutu[20] ^= 1;
        assertNull(TelsizSifre.ac(kutu, "test"));
    }

    @Test
    public void cerceveTuru() {
        byte[] yuk = new byte[1000];
        for (int i = 0; i < yuk.length; i++) yuk[i] = (byte) (i % 251);
        List<byte[]> c = TelsizCerceve.cercevele(yuk, 0xdeadbeefL, 100);
        assertEquals((1000 + 90) / 91, c.size());
        for (byte[] x : c) assertTrue(x.length <= 100);
        List<byte[]> karisik = new ArrayList<>(c);
        Collections.reverse(karisik);
        TelsizCerceve.Birlestirici b = new TelsizCerceve.Birlestirici();
        byte[] sonuc = null;
        for (byte[] x : karisik) { byte[] r = b.ekle(x, 0); if (r != null) sonuc = r; }
        assertArrayEquals(yuk, sonuc);
        assertEquals(0, b.bekleyen());
    }

    @Test
    public void tsIleAyniBaslik() {
        // TS: cercevele(new Uint8Array([1,2,3,4,5]), 1, 12) → 2 çerçeve, ilki 01 00000001 0000 0002 + 3 bayt
        List<byte[]> c = TelsizCerceve.cercevele(new byte[]{1, 2, 3, 4, 5}, 1, 12);
        assertEquals(2, c.size());
        assertArrayEquals(new byte[]{1, 0, 0, 0, 1, 0, 0, 0, 2, 1, 2, 3}, c.get(0));
        assertArrayEquals(new byte[]{1, 0, 0, 0, 1, 0, 1, 0, 2, 4, 5}, c.get(1));
        TelsizCerceve.Birlestirici b = new TelsizCerceve.Birlestirici();
        assertNull(b.ekle(c.get(0), 0));
        assertNull(b.ekle(c.get(0), 0));
        assertArrayEquals(new byte[]{1, 2, 3, 4, 5}, b.ekle(c.get(1), 0));
    }

    @Test
    public void yarimMesajZamanAsimi() {
        TelsizCerceve.Birlestirici b = new TelsizCerceve.Birlestirici();
        b.ekle(TelsizCerceve.cercevele(new byte[30], 5, 19).get(0), 0);
        assertEquals(1, b.bekleyen());
        b.ekle(TelsizCerceve.cercevele(new byte[3], 6, 19).get(0), 61_000);
        assertEquals(0, b.bekleyen());
    }
}
