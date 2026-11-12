// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Uluslararası Sosyal Fayda Derneği (Social Business Global)
// Afet Telsizi telefondan telefona (internetsiz) ortak kablo biçimi; kullanıcıya görünen metin yok.
/**
 * Afet Telsizi — iPhone ↔ Android İNTERNETSİZ ortak biçim (2026-11-05).
 *
 * Bu dosya biçimin TEK BAŞVURU KAYNAĞIDIR. Aynı kurallar üç yerde uygulanır:
 *   - iOS:     ios/Sources/DisasterWalkieTalkiePlugin/DisasterWalkieTalkiePlugin.swift      (MultipeerConnectivity iPhone↔iPhone + Bluetooth LE; 2.0.7'den beri
 *              iPhone↔iPhone Bluetooth LE de — MultipeerConnectivity iOS 11'den beri Bluetooth değil eşler arası Wi-Fi kullanır)
 *   - Android: android/src/main/java/org/hangel/walkietalkie/telsiz/*  (Bluetooth LE)
 *   - JS:      src/index.ts (İngilizce arayüz); internet gelince yerel kuyruğu uygulamanın kendi sunucusuna yüklemek isteğe bağlıdır
 * Testler (test/frame.test.ts) aşağıdaki sabit test vektörünü üretir; Android JUnit testi ve iOS
 * doğrulama betiği (scripts/cross-verify/vektor-dogrula.swift) aynı vektörü çözer → üç platform aynı baytı okur.
 *
 * Taşıma (çapraz platform): Bluetooth LE GATT. Her telefon hem çevre birimi (reklam + GATT sunucusu) hem merkezdir (tarar,
 * bağlanır). Bağlantı başına iki yön: merkez → çevre birimi RX özelliğine YAZAR; çevre birimi → merkez TX özelliğinden
 * BİLDİRİR. İki telefon arasında iki bağlantı oluşabilir; mesaj kimliğiyle tekilleştirme çifti zararsız kılar.
 * Kim kime bağlanır (reklam):
 *   - Android: tarama yanıtında hizmet verisi 'A' + 4 bayt düğüm; Android↔Android küçük düğüm bağlanır.
 *   - iPhone: reklam adı "h" (2.0.6 ve öncesi, YALNIZ çevre birimi) ya da "h" + 6 onaltılık jeton (2.0.7+, merkez de).
 *     Android 'A' işareti olmayan her yayına bağlanır. iPhone (2.0.7+) yalnız "h…" adlı yayınlara bağlanır: "h" → bağlanır,
 *     "h" + jeton → jetonu küçük olan bağlanır; adsız (Android) yayına bağlanmaz.
 *
 * Çerçeve (BLE yazma/bildirim başına bir çerçeve):
 *   [0]      sürüm (1)
 *   [1..4]   mesaj sırası (uint32, büyük uçlu; bağlantı + gönderen başına)
 *   [5..6]   parça sırası (uint16, büyük uçlu, 0'dan)
 *   [7..8]   parça sayısı (uint16, büyük uçlu, ≥1)
 *   [9..]    yük dilimi
 * Yük = UTF-8 JSON: TelsizKablo (v:1) ya da DuyuruKablo (v:2, tur:"duyuru") — MultipeerConnectivity ile AYNI JSON.
 *
 * İçerik şifresi: anahtar = HKDF-SHA256(ikm="hangel-afet-telsiz-v1", salt=kanal, info="kanal-anahtari", 32 bayt);
 * veri = base64(nonce(12) ‖ ChaCha20-Poly1305 şifreli ‖ etiket(16)) — CryptoKit ChaChaPoly "combined" ile aynı.
 * Şifreli içerik JSON'u: { ad, ses (base64 | ""), metin?, enlem?, boylam? }.
 * Not: anahtar kanal adından türetilir; amaç başka kanaldaki aktarıcıların içeriği okumaması ve aktarıcıların içeriği
 * fark edilmeden değiştirememesidir (AEAD). Kanal adını bilen herkes okuyabilir — gizli sohbet değil, ortak telsizdir.
 */

export const KABLO_SURUM = 1;
export const DUYURU_SURUM = 2;

/** "hangel" son 6 baytta (68 61 6e 67 65 6c). */
export const BLE_SERVIS_UUID = '7A1E0001-4A6E-4C2B-9F3D-68616E67656C';
/** Merkez → çevre birimi (yazma, yanıtsız yazma). */
export const BLE_RX_UUID = '7A1E0002-4A6E-4C2B-9F3D-68616E67656C';
/** Çevre birimi → merkez (bildirim). */
export const BLE_TX_UUID = '7A1E0003-4A6E-4C2B-9F3D-68616E67656C';

export const CERCEVE_SURUM = 1;
export const CERCEVE_BASLIK = 9;
/** Bir mesajın (JSON) en büyük boyutu: 30 sn ses ~120 KB + base64 + JSON payı. */
export const MAKS_YUK_BAYT = 262_144;
/** Yarım kalan mesaj bu süre sonra atılır. */
export const BIRLESTIRME_ZAMAN_ASIMI_MS = 60_000;
/** Bağlantı başına aynı anda en çok kaç yarım mesaj tutulur. */
export const MAKS_YARIM_MESAJ = 4;
/** Bluetooth'ta yeni bağlanana gönderilen geçmiş: metinlerin hepsi (≤30) + en yeni 3 ses (Bluetooth yavaştır). */
export const BLE_GECMIS_SES = 3;
export const GECMIS_MAKS = 30;
/** Metin mesajı üst sınırı (karakter). */
export const MAKS_METIN = 280;
export const METIN_MIME = 'text/plain';
/** Bir telefonun Bluetooth ile aynı anda merkez olarak bağlandığı en çok telefon. */
export const BLE_MAKS_BAGLANTI = 6;

export const ANAHTAR_IKM = 'hangel-afet-telsiz-v1';
export const ANAHTAR_INFO = 'kanal-anahtari';

export interface TelsizKablo {
  v: 1;
  id: string;
  kanal: string;
  t: number;
  atlama: number;
  sure: number;
  mime: string;
  veri: string;
}

export interface TelsizIcerik {
  ad: string;
  ses: string;
  metin?: string;
  enlem?: number;
  boylam?: number;
  /** 2026-11-08 (Yakın ağ): durum mesajı; eski derlemeler bu iki alanı yok sayar, `metin`i düz metin gösterir. */
  durum?: TelsizDurumu;
  kisi?: string;
}

// ─── Durum mesajları (2026-11-08, Yakın ağ): "Güvendeyim" / "Toplanma alanındayım" / "Yardım lazım" ────────────────────────────
// Şifreli içerik JSON'una iki isteğe bağlı alan eklenir: `durum` ve `kisi` (cihaza özgü rastgele kod; ad/kimlik DEĞİL). `metin` okunur
// cümledir (gönderenin dili) → eski derlemelerde mesaj düz metin olarak görünür. Sayım kuralı (Swift durumOzeti / Java durumOzetiniYenile
// ile AYNI): geçerli kanalda son DURUM_OMRU_MS içindeki metin mesajlarından her kişi kodunun SON durumu sayılır.
export const DURUMLAR = ['guvende', 'toplanma', 'yardim'] as const;
export type TelsizDurumu = (typeof DURUMLAR)[number];
export const DURUM_OMRU_MS = 12 * 3_600_000;

export function durumGecerli(d: unknown): d is TelsizDurumu {
  return typeof d === 'string' && (DURUMLAR as readonly string[]).includes(d);
}

/** 8–16 karakter, küçük harf ve rakam. */
export function kisiGecerli(k: unknown): k is string {
  return typeof k === 'string' && /^[a-z0-9]{8,16}$/.test(k);
}

export interface DurumOzeti { guvende: number; toplanma: number; yardim: number }

/** Başvuru uygulaması: yerel motorlar aynı kuralı kendi dillerinde uygular (bu işlev testlerin ve belgenin kaynağıdır). */
export function durumOzeti(
  mesajlar: { t: number; mime: string; kanal: string; durum?: unknown; kisi?: unknown }[],
  kanal: string,
  simdi: number,
): DurumOzeti {
  const son = new Map<string, { t: number; durum: TelsizDurumu }>();
  for (const m of mesajlar) {
    if (m.kanal !== kanal || m.mime !== METIN_MIME || simdi - m.t >= DURUM_OMRU_MS) continue;
    if (!durumGecerli(m.durum) || !kisiGecerli(m.kisi)) continue;
    const onceki = son.get(m.kisi);
    if (onceki && onceki.t >= m.t) continue;
    son.set(m.kisi, { t: m.t, durum: m.durum });
  }
  const ozet: DurumOzeti = { guvende: 0, toplanma: 0, yardim: 0 };
  for (const v of son.values()) ozet[v.durum] += 1;
  return ozet;
}

/** Yükü çerçevelere böler. `parcaBoyutu` = BLE yazma/bildirim üst sınırı (MTU − 3); başlık dahil. */
export function cercevele(yuk: Uint8Array, sira: number, parcaBoyutu: number): Uint8Array[] {
  if (yuk.length === 0 || yuk.length > MAKS_YUK_BAYT) throw new Error('yuk-boyutu');
  const dilim = parcaBoyutu - CERCEVE_BASLIK;
  if (dilim < 1) throw new Error('parca-boyutu');
  const sayi = Math.ceil(yuk.length / dilim);
  if (sayi > 0xffff) throw new Error('parca-sayisi');
  const cikti: Uint8Array[] = [];
  for (let i = 0; i < sayi; i++) {
    const parca = yuk.subarray(i * dilim, Math.min(yuk.length, (i + 1) * dilim));
    const c = new Uint8Array(CERCEVE_BASLIK + parca.length);
    const g = new DataView(c.buffer);
    g.setUint8(0, CERCEVE_SURUM);
    g.setUint32(1, sira >>> 0);
    g.setUint16(5, i);
    g.setUint16(7, sayi);
    c.set(parca, CERCEVE_BASLIK);
    cikti.push(c);
  }
  return cikti;
}

export interface CozulmusCerceve {
  sira: number;
  parca: number;
  sayi: number;
  dilim: Uint8Array;
}

export function cerceveCoz(c: Uint8Array): CozulmusCerceve | null {
  if (c.length <= CERCEVE_BASLIK || c[0] !== CERCEVE_SURUM) return null;
  const g = new DataView(c.buffer, c.byteOffset, c.byteLength);
  const sayi = g.getUint16(7);
  const parca = g.getUint16(5);
  if (sayi < 1 || parca >= sayi) return null;
  return { sira: g.getUint32(1), parca, sayi, dilim: c.subarray(CERCEVE_BASLIK) };
}

/**
 * Bağlantı başına birleştirici. Parçalar sırayla gelmeyebilir (Android bildirim kuyruğu); eksik parça zaman aşımında atılır.
 * Java (TelsizCerceve.Birlestirici) ve Swift (TelsizBirlestirici) aynı kuralları uygular.
 */
export class Birlestirici {
  private yarim = new Map<number, { parcalar: (Uint8Array | null)[]; gelen: number; bayt: number; ilkMs: number }>();

  ekle(c: Uint8Array, simdi = Date.now()): Uint8Array | null {
    const z = cerceveCoz(c);
    if (!z) return null;
    for (const [k, v] of this.yarim) if (simdi - v.ilkMs > BIRLESTIRME_ZAMAN_ASIMI_MS) this.yarim.delete(k);
    let y = this.yarim.get(z.sira);
    if (!y) {
      if (z.sayi > MAKS_YUK_BAYT) return null;
      if (this.yarim.size >= MAKS_YARIM_MESAJ) {
        const enEski = [...this.yarim.entries()].sort((a, b) => a[1].ilkMs - b[1].ilkMs)[0];
        this.yarim.delete(enEski[0]);
      }
      y = { parcalar: new Array(z.sayi).fill(null), gelen: 0, bayt: 0, ilkMs: simdi };
      this.yarim.set(z.sira, y);
    }
    if (y.parcalar.length !== z.sayi) {
      this.yarim.delete(z.sira);
      return null;
    }
    if (y.parcalar[z.parca]) return null;
    y.parcalar[z.parca] = z.dilim.slice();
    y.gelen += 1;
    y.bayt += z.dilim.length;
    if (y.bayt > MAKS_YUK_BAYT) {
      this.yarim.delete(z.sira);
      return null;
    }
    if (y.gelen < z.sayi) return null;
    this.yarim.delete(z.sira);
    const tum = new Uint8Array(y.bayt);
    let o = 0;
    for (const p of y.parcalar) {
      tum.set(p as Uint8Array, o);
      o += (p as Uint8Array).length;
    }
    return tum;
  }

  get bekleyen(): number {
    return this.yarim.size;
  }
}

/** Gelen JSON telsiz mesajı mı; değilse null. Aktarım ve ömür kuralları burada (Swift/Java aynısı). */
export function kabloDogrula(o: unknown, simdi: number, omurMs: number, maksAtlama: number): TelsizKablo | null {
  if (!o || typeof o !== 'object') return null;
  const k = o as Record<string, unknown>;
  if (k.v !== KABLO_SURUM) return null;
  if (typeof k.id !== 'string' || !/^[A-Za-z0-9_-]{8,64}$/.test(k.id)) return null;
  if (typeof k.kanal !== 'string' || k.kanal.length > 64) return null;
  const t = Number(k.t), atlama = Number(k.atlama), sure = Number(k.sure);
  if (!Number.isFinite(t) || simdi - t >= omurMs || t > simdi + 5 * 60_000) return null;
  if (!Number.isInteger(atlama) || atlama < 0 || atlama > maksAtlama) return null;
  if (typeof k.mime !== 'string' || typeof k.veri !== 'string') return null;
  return { v: 1, id: k.id, kanal: k.kanal, t, atlama, sure: Number.isFinite(sure) ? sure : 0, mime: k.mime, veri: k.veri };
}

/**
 * Bluetooth'ta yeni bağlanana gönderilecek geçmiş: ömrü dolmamış, aktarım hakkı kalmış mesajlardan metinlerin hepsi ve en
 * yeni BLE_GECMIS_SES ses; toplam GECMIS_MAKS; yeniden eskiye.
 */
export function bleGecmisi<T extends { t: number; atlama: number; mime: string }>(liste: T[], simdi: number, omurMs: number, maksAtlama: number): T[] {
  const uygun = liste.filter((m) => simdi - m.t < omurMs && m.atlama < maksAtlama).sort((a, b) => b.t - a.t);
  const cikti: T[] = [];
  let ses = 0;
  for (const m of uygun) {
    if (m.mime === METIN_MIME) cikti.push(m);
    else if (ses < BLE_GECMIS_SES) {
      cikti.push(m);
      ses += 1;
    }
    if (cikti.length >= GECMIS_MAKS) break;
  }
  return cikti;
}

/** Metin mesajını temizler: denetim karakterleri atılır, kırpılır, MAKS_METIN'e kısaltılır. Boşsa null. */
export function metinTemizle(m: unknown): string | null {
  if (typeof m !== 'string') return null;
  const t = Array.from(m)
    .filter((c) => c === '\n' || c.codePointAt(0)! >= 32)
    .join('')
    .trim();
  if (!t) return null;
  return Array.from(t).slice(0, MAKS_METIN).join('');
}
