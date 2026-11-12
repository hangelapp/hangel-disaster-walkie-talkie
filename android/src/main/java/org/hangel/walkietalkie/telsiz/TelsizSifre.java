// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Uluslararası Sosyal Fayda Derneği (Social Business Global)
package org.hangel.walkietalkie.telsiz;

import android.os.Build;

import java.nio.charset.StandardCharsets;
import java.security.SecureRandom;
import java.util.Arrays;

import javax.crypto.Cipher;
import javax.crypto.Mac;
import javax.crypto.spec.IvParameterSpec;
import javax.crypto.spec.SecretKeySpec;

/**
 * Afet Telsizi içerik şifresi — iOS CryptoKit ile birebir aynı (src/protocol/frame.ts başlık yorumu):
 * anahtar = HKDF-SHA256(ikm="hangel-afet-telsiz-v1", salt=kanal, info="kanal-anahtari", 32);
 * kutu = nonce(12) ‖ ChaCha20-Poly1305 şifreli ‖ etiket(16) ("combined").
 * ChaCha20-Poly1305 Android 9 (API 28) ile geldi; altında telsiz kullanılamaz (TelsizMotoru.destekleniyor()).
 */
public final class TelsizSifre {
    private TelsizSifre() {}

    private static final byte[] IKM = "hangel-afet-telsiz-v1".getBytes(StandardCharsets.UTF_8);
    private static final byte[] INFO = "kanal-anahtari".getBytes(StandardCharsets.UTF_8);
    private static final SecureRandom RASTGELE = new SecureRandom();

    public static boolean destekleniyor() {
        return Build.VERSION.SDK_INT >= 28;
    }

    /** RFC 5869 HKDF-SHA256 (tek blok yeter: 32 bayt). */
    public static byte[] anahtar(String kanal) throws Exception {
        Mac mac = Mac.getInstance("HmacSHA256");
        byte[] tuz = kanal.getBytes(StandardCharsets.UTF_8);
        mac.init(new SecretKeySpec(tuz.length == 0 ? new byte[32] : tuz, "HmacSHA256"));
        byte[] prk = mac.doFinal(IKM);
        mac.init(new SecretKeySpec(prk, "HmacSHA256"));
        mac.update(INFO);
        mac.update((byte) 1);
        return Arrays.copyOf(mac.doFinal(), 32);
    }

    public static byte[] sifrele(byte[] acik, String kanal) throws Exception {
        byte[] nonce = new byte[12];
        RASTGELE.nextBytes(nonce);
        return sifrele(acik, kanal, nonce);
    }

    static byte[] sifrele(byte[] acik, String kanal, byte[] nonce) throws Exception {
        Cipher c = Cipher.getInstance("ChaCha20-Poly1305");
        c.init(Cipher.ENCRYPT_MODE, new SecretKeySpec(anahtar(kanal), "ChaCha20"), new IvParameterSpec(nonce));
        byte[] ct = c.doFinal(acik); // şifreli ‖ etiket
        byte[] kutu = new byte[12 + ct.length];
        System.arraycopy(nonce, 0, kutu, 0, 12);
        System.arraycopy(ct, 0, kutu, 12, ct.length);
        return kutu;
    }

    /** Açılamazsa (yanlış kanal, değiştirilmiş veri) null. */
    public static byte[] ac(byte[] kutu, String kanal) {
        if (kutu == null || kutu.length < 12 + 16) return null;
        try {
            Cipher c = Cipher.getInstance("ChaCha20-Poly1305");
            c.init(Cipher.DECRYPT_MODE, new SecretKeySpec(anahtar(kanal), "ChaCha20"), new IvParameterSpec(Arrays.copyOfRange(kutu, 0, 12)));
            return c.doFinal(kutu, 12, kutu.length - 12);
        } catch (Exception e) {
            return null;
        }
    }
}
