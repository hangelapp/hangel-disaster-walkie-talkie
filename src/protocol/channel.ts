// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Uluslararası Sosyal Fayda Derneği (Social Business Global)
// Afet Telsizi saf kuralları (sabitler, kanal adı, mesafe, çevrimdışı kuyruk doğrulaması); kullanıcıya görünen metin yok.
/**
 * Afet Telsizi — kanal ve kuyruk kuralları (saf işlevler, testli: test/channel.test.ts).
 *
 * Çevrimdışı: yerel motor (iOS DisasterWalkieTalkiePlugin: MultipeerConnectivity + Bluetooth LE; Android telsiz/: Bluetooth LE)
 * telefondan telefona aktarır — iPhone ↔ Android de (ortak biçim src/protocol/frame.ts).
 * Çevrimiçi (İSTEĞE BAĞLI): uygulama, yerel kuyruğu (getPendingUploads) KENDİ sunucusuna yükleyebilir ve sunucudaki mesajları
 * ağa verebilir (injectFromServer). Bu depoda sunucu yoktur; hangel'in kendi sunucu tarafı bu açık kaynak sürüme dahil değildir.
 */

export const MAKS_SURE_MS = 30_000;
/** 30 sn Opus/AAC ~60–150 KB; base64 + pay için üst sınır. */
export const MAKS_SES_BAYT = 1_500_000;
export const OMUR_MS = 72 * 3600_000;
/** Telefondan telefona en çok kaç kez aktarılır (yerel tarafla aynı sayı: TelsizMotoru.maksAtlama). */
export const MAKS_ATLAMA = 12;
export const TEST_KANALI = 'test';

/**
 * 2026-11-05: numaralı kanallar 0–99. "k0" = GENEL kanal, açılışta seçili; kullanıcılar Genel'de anlaşıp başka bir
 * numaraya geçer. Kanal adı hem (varsa) sunucu kaydı hem internetsiz ağ (yerel şifre anahtarı kanal adından) için
 * aynıdır → aynı numaradaki herkes iki yoldan da birbirini duyar. Eski "test" ve "il-…" kanalları eski uygulama
 * derlemeleri için kabul edilmeye devam eder (yeni ekranda gösterilmez).
 */
export const KANAL_SAYISI = 100;
export const GENEL_KANAL = 'k0';

export function numaraliKanal(n: number): string {
  const x = Math.max(0, Math.min(KANAL_SAYISI - 1, Math.floor(Number.isFinite(n) ? n : 0)));
  return `k${x}`;
}

/** "k12" → 12; numaralı kanal değilse null. */
export function kanalNumarasi(k: unknown): number | null {
  if (typeof k !== 'string') return null;
  const m = /^k(0|[1-9][0-9]?)$/.exec(k);
  return m ? Number(m[1]) : null;
}

export const IZINLI_MIME = ['audio/webm', 'audio/ogg', 'audio/mp4', 'audio/aac', 'audio/x-m4a', 'audio/m4a', 'audio/mpeg'] as const;

/** "İstanbul" → "il-istanbul". Türkçe harfler ASCII'ye; boşluk/noktalama tire. */
export function ilKanali(il: string | null | undefined): string | null {
  if (!il) return null;
  const s = il
    .toLocaleLowerCase('tr-TR')
    .replace(/ı/g, 'i').replace(/ğ/g, 'g').replace(/ü/g, 'u').replace(/ş/g, 's').replace(/ö/g, 'o').replace(/ç/g, 'c')
    .normalize('NFD').replace(/[̀-ͯ]/g, '')
    .replace(/[^a-z0-9]+/g, '-').replace(/^-+|-+$/g, '')
    .slice(0, 40);
  return s.length >= 2 ? `il-${s}` : null;
}

export function kanalGecerliMi(k: unknown): k is string {
  return typeof k === 'string' && (k === TEST_KANALI || kanalNumarasi(k) !== null || /^il-[a-z0-9-]{2,40}$/.test(k));
}

/** MIME'nin ana kısmı ("audio/webm;codecs=opus" → "audio/webm") izinli mi. */
export function mimeTemizle(m: unknown): string | null {
  if (typeof m !== 'string') return null;
  const ana = m.split(';')[0].trim().toLowerCase();
  return (IZINLI_MIME as readonly string[]).includes(ana) ? ana : null;
}

export function mimeUzanti(mime: string): string {
  if (mime === 'audio/webm') return 'webm';
  if (mime === 'audio/ogg') return 'ogg';
  if (mime === 'audio/mpeg') return 'mp3';
  if (mime === 'audio/aac') return 'aac';
  return 'm4a';
}

/** Konum ~1 km hassasiyete yuvarlanır (KVKK: tam konum saklanmaz). */
export function yaklasikKonum(lat: unknown, lng: unknown): { lat: number; lng: number } | null {
  const a = Number(lat), b = Number(lng);
  if (!Number.isFinite(a) || !Number.isFinite(b) || Math.abs(a) > 90 || Math.abs(b) > 180) return null;
  return { lat: Math.round(a * 100) / 100, lng: Math.round(b * 100) / 100 };
}

export function mesafeKm(a: { lat: number; lng: number }, b: { lat: number; lng: number }): number {
  const R = 6371;
  const dLat = ((b.lat - a.lat) * Math.PI) / 180;
  const dLng = ((b.lng - a.lng) * Math.PI) / 180;
  const s = Math.sin(dLat / 2) ** 2 + Math.cos((a.lat * Math.PI) / 180) * Math.cos((b.lat * Math.PI) / 180) * Math.sin(dLng / 2) ** 2;
  return 2 * R * Math.asin(Math.min(1, Math.sqrt(s)));
}

/** Görünen mesafe: 1 km altı "<1 km", 10 km altı tek ondalık, üstü tam sayı (yaklaşık konumdan; ± ~1 km). */
export function mesafeMetni(km: number, dil: string): string {
  if (!Number.isFinite(km)) return '';
  if (km < 1) return '<1 km';
  const nf = new Intl.NumberFormat(dil, { maximumFractionDigits: km < 10 ? 1 : 0 });
  return `~${nf.format(km)} km`;
}

/** Sunucu belge kimliği → internetsiz ağdaki kimlik ("c_<id>" ise öneksiz; köprüde aynı mesaj iki kez dolaşmasın). */
export function agKimligi(belgeId: string): string {
  return belgeId.startsWith('c_') ? belgeId.slice(2) : belgeId;
}

/** Çevrimdışı (yerel) kuyruktan gelen mesaj kimliği: yalnız güvenli karakterler; belge kimliği "c_<id>" olur → tekrar yüklemede çift kayıt yok. */
export function cevrimdisiBelgeKimligi(id: unknown): string | null {
  if (typeof id !== 'string') return null;
  const t = id.trim();
  return /^[A-Za-z0-9_-]{8,64}$/.test(t) ? `c_${t}` : null;
}

export interface CevrimdisiMeta {
  id: string;
  olusturulduMs: number;
  atlama: number;
  /** Mesajı ilk kaydeden kişinin (yerel cihazdaki) adı — aktaran telefon yüklese de gönderen doğru görünsün. */
  ad: string;
  /** Yükleyen cihaz mesajın sahibi mi (kendi kaydı). */
  kendim: boolean;
}

/** Yerel kuyruk meta verisini doğrular; geleceğe ait ya da 72 saatten eski kayıtlar reddedilir. */
export function cevrimdisiMetaDogrula(m: unknown, simdi = Date.now()): CevrimdisiMeta | null {
  if (!m || typeof m !== 'object') return null;
  const o = m as Record<string, unknown>;
  const id = typeof o.id === 'string' ? o.id : '';
  if (!cevrimdisiBelgeKimligi(id)) return null;
  const t = Number(o.olusturulduMs);
  if (!Number.isFinite(t) || t > simdi + 5 * 60_000 || simdi - t > OMUR_MS) return null;
  const atlama = Math.max(0, Math.min(MAKS_ATLAMA, Math.floor(Number(o.atlama) || 0)));
  const ad = typeof o.ad === 'string' ? Array.from(o.ad).filter((c) => c.charCodeAt(0) >= 32).join('').trim().slice(0, 60) : '';
  return { id, olusturulduMs: t, atlama, ad, kendim: o.kendim === true };
}

/** base64 (data: öneki olabilir) → bayt sayısı tahmini; sınır denetimi için çözmeden önce. */
export function base64Bayt(b64: string): number {
  const ham = b64.includes(',') ? b64.slice(b64.indexOf(',') + 1) : b64;
  const dolgu = ham.endsWith('==') ? 2 : ham.endsWith('=') ? 1 : 0;
  return Math.floor((ham.length * 3) / 4) - dolgu;
}

export interface TelsizMesaji {
  id: string;
  kanal: string;
  uid: string;
  ad: string;
  url: string;
  mime: string;
  sureMs: number;
  olusturulduMs: number;
  konum: { lat: number; lng: number } | null;
  kaynak: 'cevrimici' | 'cevrimdisi';
  atlama: number | null;
  /** 2026-11-05: internetsiz yazılmış kısa metin (mime "text/plain"); sesli mesajda null. */
  metin?: string | null;
}
