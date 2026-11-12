// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Uluslararası Sosyal Fayda Derneği (Social Business Global)
// Afet Telsizi AĞ v3 (internetsiz) kuralları; kullanıcıya görünen metin yok (yalnız sunucuya giden Türkçe yardım özeti).
/**
 * Afet Telsizi — AĞ v3 (2026-11-09, yeniden tasarım).
 *
 * Bu dosya v3 iletilerinin TEK BAŞVURU KAYNAĞIDIR; iOS (ios/Sources/DisasterWalkieTalkiePlugin/DisasterWalkieTalkiePlugin.swift, "AĞ v3" bölümü) aynı kuralları
 * uygular. Android (TelsizMotoru.java) sonraki sürümde; o güne dek Android `v != 1` iletileri yok sayar ve AKTARMAZ.
 *
 * Kablo: düz UTF-8 JSON, MultipeerConnectivity'de ve Bluetooth LE çerçevesinde (src/protocol/frame.ts) v1/v2 ile AYNI yoldan.
 *   { v: 3, tur, id, t, atlama, kisi, ad, enlem?, boylam?, konumMs?, ...türe özgü alanlar }
 * Şifresiz: ad ZATEN maskelidir ("İ***** H**** K*******"), konum herkese açıktır. Kanal anahtarı
 * zaten herkesçe türetilebildiği için şifre burada gizlilik sağlamazdı. Eski istemciler (v1 TelsizKablo / v2 DuyuruKablo) bu
 * iletileri çözemez → yok sayar, aktarmaz. Bilinmeyen v3 türü de yok sayılır (aktarılmaz).
 *
 * Türler:
 *   varlik           — "ben buradayım": her 30–45 sn; kişi kodu, maskeli ad, konum, cihaz türü. En çok 3 atlama; 3 dk görülmeyen düşer.
 *   davet            — hedef kişi koduna özel kanal daveti (1–99). Ağ üzerinden aktarılır (hedefe varınca durur). 15 dk geçerli.
 *   davetYaniti      — davet edene yanıt (kabul/ret); kabulde iki taraf o kanala geçer.
 *   yardim           — yardım çağrısı: ihtiyac (enkaz|yarali|su-gida|barinma|ilac|diger), kisiSayisi (1–99), not (≤140). 24 sa; 16 atlama.
 *   yardimaGidiyorum — bir yardım çağrısına "gidiyorum" (yardimId). 24 sa; 16 atlama.
 * Atlama: gönderen 0 yollar; alan +1 saklar ve saklanan değer türün sınırından küçükse +1'li hâliyle diğer bağlantılara aktarır
 * (v1 ile aynı). Tekilleştirme: ileti kimliği (görülen kimlik ömrü boyunca hatırlanır).
 * Doğrudan komşu: atlama 0 ile gelen varlık iletisi, geldiği bağlantının o kişiye ait olduğunu söyler (aynı cihaz hem Bluetooth hem
 * Wi-Fi'dan bağlıysa tek sayılır; uyumsuz/eski cihazlar "bilinmeyen" olarak ayrı sayılır).
 * İstek/yanıt (2026-11-09): yeni bağlantıda ilk iletilen kendi varlığımızdır
 * ve `yanitIste: true` taşır; alan (ya da bağlantıyı yeni eşleyen) taraf kendi varlığını HEMEN yalnız o bağlantıya yollar. İlk dakikada
 * kimliği gelmemiş bağlantıya 5 sn'de bir yeniden istenir. `yanitIste` aktarılmaz.
 */

export const AG_SURUM = 3;

export const AG_TURLERI = ['varlik', 'davet', 'davetYaniti', 'yardim', 'yardimaGidiyorum'] as const;
export type AgTuru = (typeof AG_TURLERI)[number];

/** Saklanan atlama bu sınırdan küçükse aktarılır (varlık: en çok 3 cihaz öteye ulaşır). */
export const AG_MAKS_ATLAMA: Record<AgTuru, number> = { varlik: 3, davet: 12, davetYaniti: 12, yardim: 16, yardimaGidiyorum: 16 };
export const AG_OMUR_MS: Record<AgTuru, number> = {
  varlik: 3 * 60_000,
  davet: 15 * 60_000,
  davetYaniti: 15 * 60_000,
  yardim: 24 * 3_600_000,
  yardimaGidiyorum: 24 * 3_600_000,
};

/** (İsteğe bağlı) sunucuda yardım çağrısının saklanma süresi önerisi — ağdaki ömürle aynı. */
export const YARDIM_OMUR_MS_SUNUCU = AG_OMUR_MS.yardim;

export const VARLIK_ARALIK_MIN_MS = 30_000;
export const VARLIK_ARALIK_MAKS_MS = 45_000;
/** Bu süre görülmeyen cihaz listeden düşer. */
export const VARLIK_ZAMAN_ASIMI_MS = 3 * 60_000;
/** Konum en çok bu kadar eskiyse iletiye eklenir (yoksa ön planda tek seferlik istek; o da yoksa alan boş). */
export const KONUM_TAZE_MS = 2 * 60_000;

export const YARDIM_TURLERI = ['enkaz', 'yarali', 'su-gida', 'barinma', 'ilac', 'diger'] as const;
export type YardimTuru = (typeof YARDIM_TURLERI)[number];
export const YARDIM_NOT_MAKS = 140;
export const YARDIM_KISI_MAKS = 99;

export const CIHAZ_TURLERI = ['iphone', 'ipad', 'mac', 'android', 'diger'] as const;
export type CihazTuru = (typeof CIHAZ_TURLERI)[number];

/** Telsizde ad üst sınırı (grafem). */
export const AD_MAKS = 60;

export interface AgKablo {
  v: 3;
  tur: AgTuru;
  id: string;
  t: number;
  atlama: number;
  kisi: string;
  ad: string;
  enlem?: number;
  boylam?: number;
  konumMs?: number;
  cihaz?: CihazTuru;
  hedef?: string;
  kanal?: number;
  davetId?: string;
  kabul?: boolean;
  ihtiyac?: YardimTuru;
  kisiSayisi?: number;
  not?: string;
  yardimId?: string;
  yanitIste?: boolean;
}

const KIMLIK = /^[A-Za-z0-9_-]{8,64}$/;
const KISI = /^[a-z0-9]{8,16}$/;

export function agKimlikGecerli(id: unknown): id is string {
  return typeof id === 'string' && KIMLIK.test(id);
}

function graf(s: string): string[] {
  const S = (Intl as unknown as { Segmenter?: new (l?: string, o?: { granularity: string }) => { segment(s: string): Iterable<{ segment: string }> } }).Segmenter;
  if (S) return Array.from(new S(undefined, { granularity: 'grapheme' }).segment(s), (x) => x.segment);
  return Array.from(s);
}

/**
 * Ad maskesi: her kelimenin ilk harfi + kalan harf sayısı kadar "*". "İlayda Hande KÖSEOĞLU" → "İ***** H**** K*******".
 * Maskeli ad yeniden maskelenince aynı kalır. Boş → "". Swift `TelsizAg.maskele` ve çevrimdışı sayfadaki `adMaskele` AYNISI.
 */
export function adMaskele(ad: unknown): string {
  if (typeof ad !== 'string') return '';
  // Denetim karakterleri (U+0000–U+001F, U+007F) boşluk olur.
  const duz = Array.from(ad.normalize('NFC'), (c) => {
    const k = c.codePointAt(0)!;
    return k < 32 || k === 0x7f ? ' ' : c;
  }).join('');
  const temiz = graf(duz).slice(0, AD_MAKS).join('');
  return temiz
    .split(/\s+/)
    .filter(Boolean)
    .map((k) => {
      const h = graf(k);
      return h[0] + '*'.repeat(h.length - 1);
    })
    .join(' ');
}

/** Not: denetim karakterleri atılır, satır sonu boşluğa döner, kırpılır, 140 karaktere kısaltılır. */
export function yardimNotTemizle(n: unknown): string {
  if (typeof n !== 'string') return '';
  const t = Array.from(n.replace(/[\r\n\t]+/g, ' '))
    .filter((c) => c.codePointAt(0)! >= 32)
    .join('')
    .trim();
  return Array.from(t).slice(0, YARDIM_NOT_MAKS).join('');
}

export function yardimTuruGecerli(t: unknown): t is YardimTuru {
  return typeof t === 'string' && (YARDIM_TURLERI as readonly string[]).includes(t);
}

export function kisiSayisiTemizle(n: unknown): number {
  const x = Math.floor(Number(n));
  return Number.isFinite(x) ? Math.max(1, Math.min(YARDIM_KISI_MAKS, x)) : 1;
}

/** Yardım çağrısının çekirdeği (sunucu da bunu doğrular). Tür bilinmiyorsa null. */
export function yardimTemizle(o: unknown): { tur: YardimTuru; kisiSayisi: number; not: string } | null {
  if (!o || typeof o !== 'object') return null;
  const y = o as Record<string, unknown>;
  if (!yardimTuruGecerli(y.tur)) return null;
  return { tur: y.tur, kisiSayisi: kisiSayisiTemizle(y.kisiSayisi), not: yardimNotTemizle(y.not) };
}

const YARDIM_TR: Record<YardimTuru, string> = {
  enkaz: 'Enkaz altında',
  yarali: 'Yaralı / ilk yardım',
  'su-gida': 'Su / gıda',
  barinma: 'Barınma',
  ilac: 'İlaç',
  diger: 'Diğer',
};

/** Yardım çağrısının okunur düz metin özeti (ör. sunucuya yüklerken kanal k0 metni olarak). */
export function yardimMetni(y: { tur: YardimTuru; kisiSayisi: number; not: string }): string {
  return ['🆘 Yardım çağrısı', YARDIM_TR[y.tur], `${y.kisiSayisi} kişi`, y.not].filter(Boolean).join(' · ');
}

function konumAl(o: Record<string, unknown>): Pick<AgKablo, 'enlem' | 'boylam' | 'konumMs'> {
  const a = o.enlem, b = o.boylam;
  if (typeof a !== 'number' || typeof b !== 'number' || !Number.isFinite(a) || !Number.isFinite(b) || Math.abs(a) > 90 || Math.abs(b) > 180) return {};
  const km = Number(o.konumMs);
  return { enlem: a, boylam: b, ...(Number.isFinite(km) && km > 0 ? { konumMs: km } : {}) };
}

/**
 * Gelen JSON v3 ağ iletisi mi; değilse null. Ömür, atlama, kimlik ve türe özgü alanlar burada denetlenir (Swift `agDogrula` aynısı).
 * Dönen nesne yalnız bilinen alanları taşır; ad maskelenir, not temizlenir.
 */
export function agKabloDogrula(o: unknown, simdi: number): AgKablo | null {
  if (!o || typeof o !== 'object') return null;
  const k = o as Record<string, unknown>;
  if (k.v !== AG_SURUM) return null;
  if (typeof k.tur !== 'string' || !(AG_TURLERI as readonly string[]).includes(k.tur)) return null;
  const tur = k.tur as AgTuru;
  if (!agKimlikGecerli(k.id)) return null;
  if (typeof k.kisi !== 'string' || !KISI.test(k.kisi)) return null;
  const t = Number(k.t), atlama = Number(k.atlama);
  if (!Number.isFinite(t) || simdi - t >= AG_OMUR_MS[tur] || t > simdi + 5 * 60_000) return null;
  if (!Number.isInteger(atlama) || atlama < 0 || atlama > AG_MAKS_ATLAMA[tur]) return null;
  if (typeof k.ad !== 'string') return null;
  const temel: AgKablo = { v: 3, tur, id: k.id, t, atlama, kisi: k.kisi, ad: adMaskele(k.ad), ...konumAl(k) };
  switch (tur) {
    case 'varlik': {
      const c = typeof k.cihaz === 'string' && (CIHAZ_TURLERI as readonly string[]).includes(k.cihaz) ? (k.cihaz as CihazTuru) : 'diger';
      return { ...temel, cihaz: c, ...(k.yanitIste === true ? { yanitIste: true } : {}) };
    }
    case 'davet':
    case 'davetYaniti': {
      const kanal = Number(k.kanal);
      if (typeof k.hedef !== 'string' || !KISI.test(k.hedef) || !Number.isInteger(kanal) || kanal < 1 || kanal > 99) return null;
      if (tur === 'davet') return { ...temel, hedef: k.hedef, kanal };
      if (!agKimlikGecerli(k.davetId) || typeof k.kabul !== 'boolean') return null;
      return { ...temel, hedef: k.hedef, kanal, davetId: k.davetId, kabul: k.kabul };
    }
    case 'yardim': {
      if (!yardimTuruGecerli(k.ihtiyac)) return null;
      return { ...temel, ihtiyac: k.ihtiyac, kisiSayisi: kisiSayisiTemizle(k.kisiSayisi), not: yardimNotTemizle(k.not) };
    }
    case 'yardimaGidiyorum':
      if (!agKimlikGecerli(k.yardimId)) return null;
      return { ...temel, yardimId: k.yardimId };
  }
}

// ─── Başvuru düğümü: Swift motorunun v3 davranışının TS eşi (testler çok düğümlü senaryoları bunun üzerinde koşar) ─────────────

export interface AgCihaz {
  kisi: string;
  ad: string;
  enlem?: number;
  boylam?: number;
  sonGorulmeMs: number;
  dogrudan: boolean;
  atlama: number;
  tur: CihazTuru | 'bilinmiyor';
}

export interface AgYardim {
  id: string;
  tur: YardimTuru;
  kisiSayisi: number;
  not: string;
  ad: string;
  kisi: string;
  enlem?: number;
  boylam?: number;
  t: number;
  atlama: number;
  kendim: boolean;
  gidenler: { kisi: string; ad: string; t: number }[];
}

export interface AgDavet {
  id: string;
  gonderenKisi: string;
  gonderenAd: string;
  kanal: number;
  t: number;
}

export type AgOlay =
  | { olay: 'davet'; veri: AgDavet }
  | { olay: 'davetYaniti'; veri: { id: string; kabul: boolean; kisi: string; ad: string; kanal: number } }
  | { olay: 'yardim'; veri: { yardim: AgYardim } }
  | { olay: 'kanal'; veri: { kanal: string } };

let sayac = 0;
function yeniKimlik(): string {
  sayac += 1;
  return `${Date.now().toString(36)}${Math.random().toString(36).slice(2, 10)}${sayac.toString(36)}`.slice(0, 32).padEnd(12, '0');
}

/** Tek bir cihazın ağ v3 durumu. `gonder` bu düğümün iletisini bağlantılara verir (haric: geldiği bağlantı). */
export class AgDugumu {
  kanal = 'k0';
  readonly agdakiler = new Map<string, { ad: string; enlem?: number; boylam?: number; sonGorulmeMs: number; atlama: number; tur: CihazTuru }>();
  readonly baglantiKisi = new Map<string, string>();
  readonly yardimlar = new Map<string, AgYardim>();
  readonly gelenDavetler = new Map<string, AgDavet>();
  readonly gidenDavetler = new Map<string, { hedef: string; kanal: number; t: number }>();
  private readonly gorulen = new Map<string, number>();
  readonly olaylar: AgOlay[] = [];

  constructor(
    readonly kisi: string,
    public ad: string,
    readonly cihaz: CihazTuru,
    /** `kime` verilirse yalnız o bağlantıya (doğrudan yanıt). */
    private readonly gonder: (k: AgKablo, haric: string | null, kime?: string) => void,
    public konum: { enlem: number; boylam: number; konumMs: number } | null = null,
  ) {}

  private temel(tur: AgTuru, simdi: number): AgKablo {
    const k = this.konum && simdi - this.konum.konumMs <= KONUM_TAZE_MS ? this.konum : null;
    return { v: 3, tur, id: yeniKimlik(), t: simdi, atlama: 0, kisi: this.kisi, ad: adMaskele(this.ad), ...(k ? { enlem: k.enlem, boylam: k.boylam, konumMs: k.konumMs } : {}) };
  }

  private yay(k: AgKablo, simdi: number): AgKablo {
    this.gorulen.set(k.id, simdi + AG_OMUR_MS[k.tur]);
    this.gonder(k, null);
    return k;
  }

  varlikYay(simdi: number): AgKablo {
    return this.yay({ ...this.temel('varlik', simdi), cihaz: this.cihaz }, simdi);
  }

  private readonly yanitlanan = new Map<string, number>();

  /** Yeni bağlantı: kendi varlığımız, yanıt istekli, yalnız o bağlantıya (Swift agGecmisi'nin ilk iletisi). */
  yeniBaglanti(baglanti: string, simdi: number): void {
    this.varlikYanitla(baglanti, simdi, true);
  }

  private varlikYanitla(baglanti: string, simdi: number, yanitIste = false): void {
    const son = this.yanitlanan.get(baglanti);
    if (son !== undefined && simdi - son < 3_000) return;
    this.yanitlanan.set(baglanti, simdi);
    const k: AgKablo = { ...this.temel('varlik', simdi), cihaz: this.cihaz, ...(yanitIste ? { yanitIste: true } : {}) };
    this.gorulen.set(k.id, simdi + AG_OMUR_MS.varlik);
    this.gonder(k, null, baglanti);
  }

  davetGonder(hedef: string, kanal: number, simdi: number): string | null {
    if (!KISI.test(hedef) || !Number.isInteger(kanal) || kanal < 1 || kanal > 99 || hedef === this.kisi) return null;
    const k = this.yay({ ...this.temel('davet', simdi), hedef, kanal }, simdi);
    this.gidenDavetler.set(k.id, { hedef, kanal, t: simdi });
    return k.id;
  }

  davetYanitla(id: string, kabul: boolean, simdi: number): boolean {
    const d = this.gelenDavetler.get(id);
    if (!d) return false;
    this.gelenDavetler.delete(id);
    this.yay({ ...this.temel('davetYaniti', simdi), hedef: d.gonderenKisi, kanal: d.kanal, davetId: id, kabul }, simdi);
    if (kabul) this.kanalaGec(d.kanal);
    return true;
  }

  yardimGonder(tur: YardimTuru, kisiSayisi: number, not: string, simdi: number): string {
    const k = this.yay({ ...this.temel('yardim', simdi), ihtiyac: tur, kisiSayisi: kisiSayisiTemizle(kisiSayisi), not: yardimNotTemizle(not) }, simdi);
    this.yardimSakla(k, true);
    return k.id;
  }

  yardimaGidiyorum(yardimId: string, simdi: number): boolean {
    const y = this.yardimlar.get(yardimId);
    if (!y) return false;
    const k = this.yay({ ...this.temel('yardimaGidiyorum', simdi), yardimId }, simdi);
    this.gidenEkle(y, k);
    return true;
  }

  private kanalaGec(n: number): void {
    this.kanal = `k${n}`;
    this.olaylar.push({ olay: 'kanal', veri: { kanal: this.kanal } });
  }

  private yardimSakla(k: AgKablo, kendim: boolean): AgYardim {
    const y: AgYardim = {
      id: k.id, tur: k.ihtiyac!, kisiSayisi: k.kisiSayisi!, not: k.not ?? '', ad: k.ad, kisi: k.kisi,
      ...(k.enlem !== undefined ? { enlem: k.enlem, boylam: k.boylam } : {}), t: k.t, atlama: k.atlama, kendim, gidenler: [],
    };
    this.yardimlar.set(y.id, y);
    return y;
  }

  private gidenEkle(y: AgYardim, k: AgKablo): void {
    if (!y.gidenler.some((g) => g.kisi === k.kisi)) y.gidenler.push({ kisi: k.kisi, ad: k.ad, t: k.t });
  }

  /** Bağlantıdan gelen ham JSON. Geçerli ve yeni ise işler, gerekirse aktarır. */
  al(ham: unknown, baglanti: string, simdi: number): void {
    const k = agKabloDogrula(ham, simdi);
    if (!k) return;
    if (k.tur === 'varlik' && k.atlama === 0) {
      const yeni = this.baglantiKisi.get(baglanti) !== k.kisi;
      this.baglantiKisi.set(baglanti, k.kisi);
      if ((k.yanitIste || yeni) && k.kisi !== this.kisi) this.varlikYanitla(baglanti, simdi);
    }
    if (k.kisi === this.kisi) return;
    for (const [id, son] of this.gorulen) if (son < simdi) this.gorulen.delete(id);
    if (this.gorulen.has(k.id)) return;
    this.gorulen.set(k.id, simdi + AG_OMUR_MS[k.tur]);
    const y: AgKablo = { ...k, atlama: k.atlama + 1 };
    delete y.yanitIste;
    let aktar = true;
    switch (k.tur) {
      case 'varlik': {
        const o = this.agdakiler.get(k.kisi);
        const atlama = o && simdi - o.sonGorulmeMs < VARLIK_ARALIK_MAKS_MS * 2 ? Math.min(o.atlama, y.atlama) : y.atlama;
        this.agdakiler.set(k.kisi, { ad: k.ad, enlem: k.enlem, boylam: k.boylam, sonGorulmeMs: simdi, atlama, tur: k.cihaz ?? 'diger' });
        break;
      }
      case 'davet':
        if (k.hedef === this.kisi) {
          aktar = false;
          const d: AgDavet = { id: k.id, gonderenKisi: k.kisi, gonderenAd: k.ad, kanal: k.kanal!, t: k.t };
          this.gelenDavetler.set(d.id, d);
          this.olaylar.push({ olay: 'davet', veri: d });
        }
        break;
      case 'davetYaniti':
        if (k.hedef === this.kisi) {
          aktar = false;
          const g = this.gidenDavetler.get(k.davetId!);
          if (g && g.hedef === k.kisi) {
            this.gidenDavetler.delete(k.davetId!);
            if (k.kabul) this.kanalaGec(g.kanal);
            this.olaylar.push({ olay: 'davetYaniti', veri: { id: k.davetId!, kabul: k.kabul!, kisi: k.kisi, ad: k.ad, kanal: g.kanal } });
          }
        }
        break;
      case 'yardim':
        if (!this.yardimlar.has(k.id)) this.olaylar.push({ olay: 'yardim', veri: { yardim: this.yardimSakla(y, false) } });
        break;
      case 'yardimaGidiyorum': {
        const yd = this.yardimlar.get(k.yardimId!);
        if (yd) {
          this.gidenEkle(yd, k);
          this.olaylar.push({ olay: 'yardim', veri: { yardim: yd } });
        }
        break;
      }
    }
    if (aktar && y.atlama < AG_MAKS_ATLAMA[k.tur]) this.gonder(y, baglanti);
  }

  /** Cihaz listesi = doğrudan bağlantılar ∪ varlık iletileri. Aynı kişi iki yoldan bağlıysa tek; kimliği bilinmeyen bağlantı ayrı sayılır. */
  cihazlar(aktifBaglantilar: string[], simdi: number): { cihazlar: AgCihaz[]; dogrudanSayi: number; agdakiSayi: number } {
    const aktif = new Set(aktifBaglantilar);
    for (const b of [...this.baglantiKisi.keys()]) if (!aktif.has(b)) this.baglantiKisi.delete(b);
    for (const [k, c] of this.agdakiler) if (simdi - c.sonGorulmeMs >= VARLIK_ZAMAN_ASIMI_MS) this.agdakiler.delete(k);
    const dogrudan = new Set<string>();
    const liste: AgCihaz[] = [];
    for (const b of aktifBaglantilar) {
      const k = this.baglantiKisi.get(b);
      if (k && k !== this.kisi) dogrudan.add(k);
      else if (!k) liste.push({ kisi: '', ad: '', sonGorulmeMs: simdi, dogrudan: true, atlama: 1, tur: 'bilinmiyor' });
    }
    for (const k of dogrudan) {
      const c = this.agdakiler.get(k);
      liste.push({ kisi: k, ad: c?.ad ?? '', ...(c?.enlem !== undefined ? { enlem: c.enlem, boylam: c.boylam } : {}), sonGorulmeMs: c?.sonGorulmeMs ?? simdi, dogrudan: true, atlama: 1, tur: c?.tur ?? 'diger' });
    }
    for (const [k, c] of this.agdakiler) {
      if (dogrudan.has(k)) continue;
      liste.push({ kisi: k, ad: c.ad, ...(c.enlem !== undefined ? { enlem: c.enlem, boylam: c.boylam } : {}), sonGorulmeMs: c.sonGorulmeMs, dogrudan: false, atlama: c.atlama, tur: c.tur });
    }
    liste.sort((a, b) => Number(b.dogrudan) - Number(a.dogrudan) || a.atlama - b.atlama || b.sonGorulmeMs - a.sonGorulmeMs);
    return { cihazlar: liste, dogrudanSayi: liste.filter((c) => c.dogrudan).length, agdakiSayi: liste.length };
  }
}
