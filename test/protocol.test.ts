// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Uluslararası Sosyal Fayda Derneği (Social Business Global)
/**
 * 2026-11-08 — . Telefon gerektirmeyen her şey burada:
 * uçtan uca kodlama/çözme (şifre + çerçeve + birleştirme), bozuk/yarım/yinelenen/sırasız paket, çok atlamalı aktarımda döngü
 * önleme ve aktarım sınırı, büyük yük ve metin sınırı, Türkçe/Arapça, saat farkı, iPhone (Swift JSONEncoder) ↔ Android (org.json)
 * JSON biçimi. Kural kaynağı: src/protocol/frame.ts (Swift ve Java aynı kuralları uygular; Java'nın TS ile birebir aynılığı
 * 08.11'de masaüstü JDK ile 127 vektörle, Swift'inki scripts/cross-verify/capraz-dogrula.sh ile denendi).
 */
import { createCipheriv, createDecipheriv, hkdfSync, randomBytes } from 'node:crypto';
import { describe, expect, it } from 'vitest';
import {
  ANAHTAR_IKM,
  ANAHTAR_INFO,
  BIRLESTIRME_ZAMAN_ASIMI_MS,
  Birlestirici,
  CERCEVE_BASLIK,
  MAKS_METIN,
  MAKS_YARIM_MESAJ,
  MAKS_YUK_BAYT,
  METIN_MIME,
  cercevele,
  durumOzeti,
  kabloDogrula,
  metinTemizle,
  type TelsizIcerik,
  type TelsizKablo,
} from '../src/protocol/frame';
import { MAKS_ATLAMA, OMUR_MS } from '../src/protocol/channel';

const SIMDI = 1_800_000_000_000;

function anahtar(kanal: string): Buffer {
  return Buffer.from(hkdfSync('sha256', Buffer.from(ANAHTAR_IKM), Buffer.from(kanal), Buffer.from(ANAHTAR_INFO), 32));
}
function sifrele(ic: TelsizIcerik, kanal: string): string {
  const nonce = randomBytes(12);
  const c = createCipheriv('chacha20-poly1305', anahtar(kanal), nonce, { authTagLength: 16 });
  const ct = Buffer.concat([c.update(Buffer.from(JSON.stringify(ic), 'utf8')), c.final()]);
  return Buffer.concat([nonce, ct, c.getAuthTag()]).toString('base64');
}
function ac(veri: string, kanal: string): TelsizIcerik {
  const b = Buffer.from(veri, 'base64');
  const d = createDecipheriv('chacha20-poly1305', anahtar(kanal), b.subarray(0, 12), { authTagLength: 16 });
  d.setAuthTag(b.subarray(b.length - 16));
  return JSON.parse(Buffer.concat([d.update(b.subarray(12, b.length - 16)), d.final()]).toString('utf8'));
}
function kablo(o: Partial<TelsizKablo> & { ic?: TelsizIcerik } = {}): TelsizKablo {
  const kanal = o.kanal ?? 'k0';
  return {
    v: 1,
    id: o.id ?? randomBytes(16).toString('hex'),
    kanal,
    t: o.t ?? SIMDI - 1000,
    atlama: o.atlama ?? 0,
    sure: o.sure ?? 0,
    mime: o.mime ?? METIN_MIME,
    veri: o.veri ?? sifrele(o.ic ?? { ad: 'Ayşe', ses: '', metin: 'Güvendeyim' }, kanal),
  };
}
const bayt = (k: unknown) => new TextEncoder().encode(JSON.stringify(k));
const coz = (b: Uint8Array) => JSON.parse(new TextDecoder().decode(b));
function karistir<T>(a: T[], tohum = 7): T[] {
  const c = [...a];
  let s = tohum;
  for (let i = c.length - 1; i > 0; i--) {
    s = (s * 1103515245 + 12345) & 0x7fffffff;
    const j = s % (i + 1);
    [c[i], c[j]] = [c[j], c[i]];
  }
  return c;
}

describe('uçtan uca: içerik → şifre → kablo JSON → BLE çerçeveleri → birleştirme → doğrulama → çözme', () => {
  const icerikler: TelsizIcerik[] = [
    { ad: 'Ayşe Gül Şahin', ses: '', metin: 'Enkaz altındayım / yaralıyım', durum: 'yardim', kisi: 'a1b2c3d4e5f6' },
    { ad: 'محمد', ses: '', metin: 'أنا تحت الأنقاض / مصاب — الطابق الثاني', enlem: 36.2021, boylam: 36.1604, durum: 'yardim', kisi: '0123456789ab' },
    { ad: 'Ömer', ses: '', metin: 'İğdır, Çanakkale, Şişli; ı/İ ğ/Ğ ü/Ü ş/Ş ö/Ö ç/Ç 👨‍👩‍👧 ✅' },
    { ad: 'Zeynep', ses: Buffer.alloc(120_000, 7).toString('base64') }, // ~30 sn ses (32 kbit/sn)
  ];
  for (const mtu of [20, 185, 512]) {
    it(`MTU ${mtu}: dört içerik (Türkçe, Arapça, emoji, 30 sn ses) sırasız gelse de aynen çözülür`, () => {
      const b = new Birlestirici();
      icerikler.forEach((ic, i) => {
        const k = kablo({ ic, mime: ic.ses ? 'audio/mp4' : METIN_MIME, sure: ic.ses ? 30_000 : 0 });
        const yuk = bayt(k);
        expect(yuk.length).toBeLessThanOrEqual(MAKS_YUK_BAYT);
        const cerceveler = cercevele(yuk, 0xfffffffe + i, mtu); // sıra uint32 taşması da denenir
        expect(cerceveler.every((c) => c.length <= mtu)).toBe(true);
        let sonuc: Uint8Array | null = null;
        for (const c of karistir(cerceveler, i + mtu)) sonuc = b.ekle(c, SIMDI) ?? sonuc;
        expect(sonuc).not.toBeNull();
        const gelen = kabloDogrula(coz(sonuc!), SIMDI, OMUR_MS, MAKS_ATLAMA);
        expect(gelen).toEqual(k);
        expect(ac(gelen!.veri, gelen!.kanal)).toEqual(ic);
      });
      expect(b.bekleyen).toBe(0);
    });
  }

  it('aynı bağlantıdan iki mesajın çerçeveleri iç içe gelse de ayrı ayrı birleşir', () => {
    const a = cercevele(bayt(kablo({ id: 'aaaaaaaaaaaaaaaa' })), 1, 40);
    const c = cercevele(bayt(kablo({ id: 'cccccccccccccccc', ic: { ad: 'B', ses: '', metin: 'Toplanma alanındayım' } })), 2, 40);
    const b = new Birlestirici();
    const cikti: string[] = [];
    const n = Math.max(a.length, c.length);
    for (let i = 0; i < n; i++) {
      for (const x of [c[n - 1 - i], a[i]]) {
        if (!x) continue;
        const r = b.ekle(x, SIMDI);
        if (r) cikti.push(coz(r).id);
      }
    }
    expect(cikti.sort()).toEqual(['aaaaaaaaaaaaaaaa', 'cccccccccccccccc']);
  });
});

describe('bozuk, yarım, yinelenen paket', () => {
  it('eksik parça: mesaj tamamlanmaz, 60 sn sonra yarım kayıt atılır (bellek)', () => {
    const c = cercevele(bayt(kablo()), 9, 30);
    const b = new Birlestirici();
    for (const x of c.slice(0, -1)) expect(b.ekle(x, SIMDI)).toBeNull();
    expect(b.bekleyen).toBe(1);
    b.ekle(cercevele(new Uint8Array([1]), 10, 30)[0], SIMDI + BIRLESTIRME_ZAMAN_ASIMI_MS + 1);
    expect(b.bekleyen).toBe(0);
  });

  it('çok sayıda yarım mesaj (saldırı / kopan bağlantı): en çok MAKS_YARIM_MESAJ tutulur', () => {
    const b = new Birlestirici();
    for (let s = 0; s < 50; s++) b.ekle(cercevele(new Uint8Array(100), s, 30)[0], SIMDI + s);
    expect(b.bekleyen).toBe(MAKS_YARIM_MESAJ);
  });

  it('yinelenen parça sayılmaz; aynı sırada farklı parça sayısı gelirse yarım mesaj atılır', () => {
    const c = cercevele(new Uint8Array(50).fill(3), 4, 20);
    const b = new Birlestirici();
    expect(b.ekle(c[0], SIMDI)).toBeNull();
    expect(b.ekle(c[0], SIMDI)).toBeNull();
    const yanlis = c[1].slice();
    yanlis[8] = yanlis[8] + 1; // parça sayısı farklı
    expect(b.ekle(yanlis, SIMDI)).toBeNull();
    expect(b.bekleyen).toBe(0);
  });

  it('bozuk başlık (sürüm, parça ≥ sayı, sayı 0, boş dilim) atılır', () => {
    const b = new Birlestirici();
    expect(b.ekle(new Uint8Array([2, 0, 0, 0, 1, 0, 0, 0, 1, 9]), SIMDI)).toBeNull();
    expect(b.ekle(new Uint8Array([1, 0, 0, 0, 1, 0, 1, 0, 1, 9]), SIMDI)).toBeNull();
    expect(b.ekle(new Uint8Array([1, 0, 0, 0, 1, 0, 0, 0, 0, 9]), SIMDI)).toBeNull();
    expect(b.ekle(new Uint8Array([1, 0, 0, 0, 1, 0, 0, 0, 1]), SIMDI)).toBeNull();
    expect(b.bekleyen).toBe(0);
  });

  it('yarım JSON / yanlış kanal / değiştirilmiş şifreli içerik: doğrulama ya da çözme reddeder (sessizce atılır)', () => {
    const k = kablo();
    const yarim = JSON.stringify(k).slice(0, 40);
    expect(() => JSON.parse(yarim)).toThrow(); // yerel motorlar try ile atar
    expect(() => ac(k.veri, 'k1')).toThrow();
    const b = Buffer.from(k.veri, 'base64');
    b[14] ^= 0x40;
    expect(() => ac(b.toString('base64'), k.kanal)).toThrow();
    expect(kabloDogrula({ ...k, mime: 5 }, SIMDI, OMUR_MS, MAKS_ATLAMA)).toBeNull();
    expect(kabloDogrula({ ...k, veri: undefined }, SIMDI, OMUR_MS, MAKS_ATLAMA)).toBeNull();
    expect(kabloDogrula({ ...k, kanal: 'x'.repeat(65) }, SIMDI, OMUR_MS, MAKS_ATLAMA)).toBeNull();
    expect(kabloDogrula({ ...k, atlama: 1.5 }, SIMDI, OMUR_MS, MAKS_ATLAMA)).toBeNull();
    expect(kabloDogrula({ ...k, atlama: -1 }, SIMDI, OMUR_MS, MAKS_ATLAMA)).toBeNull();
    expect(kabloDogrula(null, SIMDI, OMUR_MS, MAKS_ATLAMA)).toBeNull();
  });
});

/**
 * Çok atlamalı ağ — yerel motorların kuralının başvuru modeli (Swift TelsizMotoru.al, Java TelsizMotoru.al):
 * doğrula → kimlik görüldüyse at → atlama+1 ile sakla → atlama+1 < MAKS_ATLAMA ise geldiği yol HARİÇ tüm komşulara ilet.
 */
class Ag {
  gorulen = new Map<number, Map<string, number>>();
  gonderim = 0;
  constructor(public komsular: Map<number, number[]>) {
    for (const d of komsular.keys()) this.gorulen.set(d, new Map());
  }
  yay(kaynak: number, k: TelsizKablo) {
    this.gorulen.get(kaynak)!.set(k.id, 0);
    const kuyruk: { kime: number; kimden: number; k: TelsizKablo }[] = this.komsular.get(kaynak)!.map((n) => ({ kime: n, kimden: kaynak, k }));
    while (kuyruk.length) {
      const { kime, kimden, k: gelen } = kuyruk.shift()!;
      this.gonderim += 1;
      if (this.gonderim > 100_000) throw new Error('döngü');
      const g = kabloDogrula(JSON.parse(JSON.stringify(gelen)), SIMDI, OMUR_MS, MAKS_ATLAMA);
      const bilinen = this.gorulen.get(kime)!;
      if (!g || bilinen.has(g.id)) continue;
      const atlama = g.atlama + 1;
      bilinen.set(g.id, atlama);
      if (atlama < MAKS_ATLAMA) {
        for (const n of this.komsular.get(kime)!) if (n !== kimden) kuyruk.push({ kime: n, kimden: kime, k: { ...g, atlama } });
      }
    }
  }
}
function halka(n: number) {
  return new Map(Array.from({ length: n }, (_, i) => [i, [(i + 1) % n, (i + n - 1) % n]]));
}
function hat(n: number) {
  return new Map(Array.from({ length: n }, (_, i) => [i, [i - 1, i + 1].filter((x) => x >= 0 && x < n)]));
}
function tam(n: number) {
  return new Map(Array.from({ length: n }, (_, i) => [i, Array.from({ length: n }, (_, j) => j).filter((j) => j !== i)]));
}

describe('çok atlamalı aktarım: döngü önleme ve aktarım sınırı', () => {
  it('halka (A–B–C–…–A): mesaj herkese bir kez ulaşır, sonsuz döngü yok', () => {
    const ag = new Ag(halka(8));
    ag.yay(0, kablo());
    for (const g of ag.gorulen.values()) expect(g.size).toBe(1);
    expect(ag.gonderim).toBeLessThanOrEqual(16);
  });

  it('herkes herkese bağlı (8 telefon, aynı odada): her telefona bir kez; gönderim sayısı sınırlı', () => {
    const ag = new Ag(tam(8));
    ag.yay(0, kablo());
    for (const g of ag.gorulen.values()) expect(g.size).toBe(1);
    expect(ag.gonderim).toBeLessThanOrEqual(8 * 7);
  });

  it(`hat (16 telefon): en çok ${MAKS_ATLAMA} aktarım uzağa ulaşır, ötesine gitmez`, () => {
    const ag = new Ag(hat(16));
    ag.yay(0, kablo());
    const ulasan = [...ag.gorulen.entries()].filter(([, g]) => g.size === 1).map(([d]) => d);
    expect(Math.max(...ulasan)).toBe(MAKS_ATLAMA);
    expect(ag.gorulen.get(MAKS_ATLAMA)!.values().next().value).toBe(MAKS_ATLAMA);
  });

  it('aynı mesaj iki yoldan (Wi-Fi + Bluetooth) ve köprüden yeniden gelse de tek kayıt', () => {
    const ag = new Ag(tam(3));
    const k = kablo();
    ag.yay(0, k);
    ag.yay(1, { ...k, atlama: 3 }); // köprü/geçmiş ile tekrar gelen
    for (const g of ag.gorulen.values()) expect(g.size).toBe(1);
  });
});

describe('sınırlar, metin ve saat', () => {
  it('yük tam MAKS_YUK_BAYT çerçevelenir ve birleşir; bir bayt fazlası reddedilir', () => {
    const yuk = new Uint8Array(MAKS_YUK_BAYT).map((_, i) => i % 256);
    const c = cercevele(yuk, 1, 512);
    expect(c.length).toBe(Math.ceil(MAKS_YUK_BAYT / (512 - CERCEVE_BASLIK)));
    const b = new Birlestirici();
    let r: Uint8Array | null = null;
    for (const x of c) r = b.ekle(x, SIMDI) ?? r;
    expect(r).toEqual(yuk);
    expect(() => cercevele(new Uint8Array(MAKS_YUK_BAYT + 1), 1, 512)).toThrow();
  });

  it('metin: 280 kod noktası (Türkçe, Arapça, emoji), denetim karakteri atılır, sağdan sola işaretleri korunur', () => {
    expect(Array.from(metinTemizle('ş'.repeat(500))!)).toHaveLength(MAKS_METIN);
    expect(Array.from(metinTemizle('أ'.repeat(500))!)).toHaveLength(MAKS_METIN);
    expect(Array.from(metinTemizle('🧱'.repeat(500))!)).toHaveLength(MAKS_METIN);
    expect(metinTemizle('‏مرحبا\u0000\u0007')).toBe('‏مرحبا');
    expect(metinTemizle('  İğdır\nÇanakkale  ')).toBe('İğdır\nÇanakkale');
    expect(metinTemizle('　 ')).toBeNull(); // yalnız boşluk → gönderilmez (Java 08.11'de aynı kurala çekildi)
  });

  it('saat farkı: 5 dk ileri saat kabul, daha fazlası red; 72 sa eski red', () => {
    const k = kablo();
    expect(kabloDogrula({ ...k, t: SIMDI + 4 * 60_000 }, SIMDI, OMUR_MS, MAKS_ATLAMA)).not.toBeNull();
    expect(kabloDogrula({ ...k, t: SIMDI + 5 * 60_000 + 1 }, SIMDI, OMUR_MS, MAKS_ATLAMA)).toBeNull();
    expect(kabloDogrula({ ...k, t: SIMDI - OMUR_MS + 1 }, SIMDI, OMUR_MS, MAKS_ATLAMA)).not.toBeNull();
    expect(kabloDogrula({ ...k, t: SIMDI - OMUR_MS }, SIMDI, OMUR_MS, MAKS_ATLAMA)).toBeNull();
  });

  it('durum sayımı: kişi başına SON durum; "Enkaz…" (yardim) yardım sayılır; başka kanal / süresi geçen sayılmaz', () => {
    const m = (t: number, durum: string, kisi: string, kanal = 'k0') => ({ t: SIMDI - t, mime: METIN_MIME, kanal, durum, kisi });
    const o = durumOzeti(
      [
        m(5000, 'guvende', 'aaaaaaaa1'),
        m(1000, 'yardim', 'aaaaaaaa1'), // aynı kişinin son durumu
        m(2000, 'toplanma', 'bbbbbbbb2'),
        m(3000, 'yardim', 'cccccccc3'),
        m(1000, 'guvende', 'dddddddd4', 'k7'),
        m(13 * 3_600_000, 'guvende', 'eeeeeeee5'),
        m(1000, 'enkaz', 'ffffffff6'), // bilinmeyen kod sayılmaz
      ],
      'k0',
      SIMDI,
    );
    expect(o).toEqual({ guvende: 0, toplanma: 1, yardim: 2 });
  });
});

describe('iPhone (Swift JSONEncoder) ↔ Android (org.json) JSON biçimi', () => {
  it('Swift ve Java "/" kaçışlı ("\\/") JSON üretir; alan sırası farklı olabilir — ikisi de aynı kabloya çözülür', () => {
    const k = kablo({ ic: { ad: 'Ali', ses: '', metin: 'a/b' } });
    const kacisli = (o: Record<string, unknown>, sira: string[]) =>
      `{${sira.map((a) => `"${a}":${JSON.stringify(o[a]).replace(/\//g, '\\/')}`).join(',')}}`;
    const swift = kacisli(k as unknown as Record<string, unknown>, ['v', 'id', 'kanal', 't', 'atlama', 'sure', 'mime', 'veri']);
    const java = kacisli(k as unknown as Record<string, unknown>, ['veri', 'mime', 'sure', 'atlama', 't', 'kanal', 'id', 'v']);
    expect(swift).toContain('text\\/plain');
    for (const ham of [swift, java]) {
      const g = kabloDogrula(JSON.parse(ham), SIMDI, OMUR_MS, MAKS_ATLAMA);
      expect(g).toEqual(k);
      expect(ac(g!.veri, g!.kanal).metin).toBe('a/b');
    }
  });

  it('base64 satır sonu içermez (iOS Data(base64Encoded:) satır sonlu base64\'ü çözemez)', () => {
    const k = kablo({ ic: { ad: 'x', ses: Buffer.alloc(5000, 1).toString('base64') } });
    expect(k.veri).not.toMatch(/\s/);
  });
});
