// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Uluslararası Sosyal Fayda Derneği (Social Business Global)
package org.hangel.walkietalkie.telsiz;

/**
 * Bluetooth LE (TelsizBle) yanında isteğe bağlı ek taşıma (Android ↔ Android). Aynı kablo biçimini taşır; motor her mesajı
 * tüm taşımalara verir ve mesaj kimliğiyle tekilleştirir.
 *
 * Varsayılan derlemede ek taşıma YOKTUR (src/nonearby → boş uygulama): eklenti yalnız Android (AOSP) Bluetooth LE API'leriyle
 * çalışır. Google Play hizmetleri Nearby Connections ek taşıması (kapalı kaynak SDK) isteğe bağlıdır; açmak için uygulamanın
 * android/gradle.properties dosyasına `walkieTalkieNearby=true` yazın (README → Android). Bütün yöntemler motorun iş parçacığında
 * çağrılır.
 */
interface EkTasima {
    void baslat();

    void durdur();

    boolean calisiyorMu();

    /** Bağlı herkese gönderir; `haric` mesajın geldiği bağlantıdır (oraya geri gönderilmez). */
    void gonder(byte[] yuk, String haric);

    void gonderKime(String baglanti, byte[] yuk);
}
