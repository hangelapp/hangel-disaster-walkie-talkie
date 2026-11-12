// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Uluslararası Sosyal Fayda Derneği (Social Business Global)
/**
 * 2026-11-09 — Afet Telsizi AĞ v3 (varlık, davet, yardım çağrısı). Kural kaynağı src/protocol/mesh.ts; iOS
 * (DisasterWalkieTalkiePlugin.swift "AĞ v3") aynı kuralları uygular. Çok düğümlü senaryolar başvuru düğümü (AgDugumu) üzerinde koşar:
 * bağlantılar kablo JSON'unu (Swift JSONEncoder çıktısıyla aynı alanlar) birbirine verir.
 */
import { describe, expect, it } from 'vitest';
import {
  AG_MAKS_ATLAMA,
  AG_OMUR_MS,
  AgDugumu,
  KONUM_TAZE_MS,
  VARLIK_ZAMAN_ASIMI_MS,
  adMaskele,
  agKabloDogrula,
  yardimMetni,
  yardimNotTemizle,
  yardimTemizle,
  type AgKablo,
  type CihazTuru,
} from '../src/protocol/mesh';
import { kabloDogrula } from '../src/protocol/frame';
import { MAKS_ATLAMA, OMUR_MS } from '../src/protocol/channel';

const SIMDI = 1_800_000_000_000;

describe('ad maskesi', () => {
  it('her kelimenin ilk harfi + kalan harf sayısı kadar yıldız', () => {
    // Kural (09.11): "kalan harf sayısı kadar *" → KÖSEOĞLU 8 harf → K + 7 yıldız.
    expect(adMaskele('İlayda Hande KÖSEOĞLU')).toBe('İ***** H**** K*******');
    expect(adMaskele('Ayşe')).toBe('A***');
    expect(adMaskele('  Ali   Veli  ')).toBe('A** V***');
    expect(adMaskele('Ö')).toBe('Ö');
  });
  it('maskeli ad yeniden maskelenince aynı kalır; boş/yanlış tür → ""', () => {
    const m = adMaskele('İlayda Hande KÖSEOĞLU');
    expect(adMaskele(m)).toBe(m);
    expect(adMaskele('')).toBe('');
    expect(adMaskele(undefined)).toBe('');
    expect(adMaskele(42)).toBe('');
  });
  it('ayrık (NFD) İ ve Ü tek harf sayılır; Arapça/Farsça ad; denetim karakteri boşluk olur; en çok 60 harf', () => {
    expect(adMaskele('İsmail Ümit')).toBe('İ***** Ü***');
    expect(adMaskele('محمد علی')).toBe('م*** ع**');
    expect(adMaskele('Ali\nVeli\u0007Can')).toBe('A** V*** C**');
    expect(adMaskele('a'.repeat(80))).toBe('a' + '*'.repeat(59));
  });
});

function kablo(o: Partial<AgKablo> & { tur: AgKablo['tur'] }): Record<string, unknown> {
  return { v: 3, id: 'k1234567890ab', t: SIMDI, atlama: 0, kisi: 'abcd1234ef56', ad: 'İlayda Hande', ...o };
}

describe('v3 kablo doğrulama', () => {
  it('varlık: ad maskelenir, bilinmeyen cihaz türü "diger", konum aralık dışıysa düşer', () => {
    const k = agKabloDogrula(kablo({ tur: 'varlik', cihaz: 'iphone', enlem: 41.0123, boylam: 29.0456, konumMs: SIMDI - 1000 }), SIMDI)!;
    expect(k).toMatchObject({ v: 3, tur: 'varlik', ad: 'İ***** H****', cihaz: 'iphone', enlem: 41.0123, boylam: 29.0456, konumMs: SIMDI - 1000 });
    expect(agKabloDogrula(kablo({ tur: 'varlik', cihaz: 'buzdolabı' as CihazTuru }), SIMDI)!.cihaz).toBe('diger');
    const k2 = agKabloDogrula(kablo({ tur: 'varlik', enlem: 95, boylam: 29 }), SIMDI)!;
    expect(k2.enlem).toBeUndefined();
    expect(k2.boylam).toBeUndefined();
  });

  it('ömür, saat ileriliği, atlama sınırı ve kimlikler', () => {
    expect(agKabloDogrula(kablo({ tur: 'varlik', t: SIMDI - AG_OMUR_MS.varlik }), SIMDI)).toBeNull();
    expect(agKabloDogrula(kablo({ tur: 'varlik', t: SIMDI + 6 * 60_000 }), SIMDI)).toBeNull();
    expect(agKabloDogrula(kablo({ tur: 'varlik', atlama: AG_MAKS_ATLAMA.varlik + 1 }), SIMDI)).toBeNull();
    expect(agKabloDogrula(kablo({ tur: 'varlik', atlama: AG_MAKS_ATLAMA.varlik }), SIMDI)).not.toBeNull();
    expect(agKabloDogrula(kablo({ tur: 'yardim', ihtiyac: 'enkaz', t: SIMDI - 23 * 3_600_000 }), SIMDI)).not.toBeNull();
    expect(agKabloDogrula(kablo({ tur: 'varlik', id: 'kısa' }), SIMDI)).toBeNull();
    expect(agKabloDogrula(kablo({ tur: 'varlik', kisi: 'BUYUK-HARF' }), SIMDI)).toBeNull();
    expect(agKabloDogrula({ ...kablo({ tur: 'varlik' }), ad: undefined }, SIMDI)).toBeNull();
  });

  it('yardım çağrısının atlama sınırı normal iletiden (12) yüksek; varlık 3', () => {
    expect(AG_MAKS_ATLAMA.yardim).toBeGreaterThan(MAKS_ATLAMA);
    expect(AG_MAKS_ATLAMA.yardimaGidiyorum).toBe(AG_MAKS_ATLAMA.yardim);
    expect(AG_MAKS_ATLAMA.varlik).toBe(3);
    expect(AG_OMUR_MS.yardim).toBe(24 * 3_600_000);
  });

  it('davet / davet yanıtı: hedef kişi kodu ve kanal 1–99 zorunlu', () => {
    expect(agKabloDogrula(kablo({ tur: 'davet', hedef: 'ffff0000aaaa', kanal: 92 }), SIMDI)).toMatchObject({ hedef: 'ffff0000aaaa', kanal: 92 });
    expect(agKabloDogrula(kablo({ tur: 'davet', hedef: 'ffff0000aaaa', kanal: 0 }), SIMDI)).toBeNull();
    expect(agKabloDogrula(kablo({ tur: 'davet', hedef: 'ffff0000aaaa', kanal: 100 }), SIMDI)).toBeNull();
    expect(agKabloDogrula(kablo({ tur: 'davet', kanal: 5 }), SIMDI)).toBeNull();
    expect(agKabloDogrula(kablo({ tur: 'davetYaniti', hedef: 'ffff0000aaaa', kanal: 5, davetId: 'd1234567890', kabul: true }), SIMDI)).not.toBeNull();
    expect(agKabloDogrula(kablo({ tur: 'davetYaniti', hedef: 'ffff0000aaaa', kanal: 5, davetId: 'd1234567890' }), SIMDI)).toBeNull();
  });

  it('yardım biçimi: tür kümesi, kişi sayısı 1–99, not ≤140 ve temiz', () => {
    const y = agKabloDogrula(kablo({ tur: 'yardim', ihtiyac: 'su-gida', kisiSayisi: 250, not: '  3 çocuk\nvar\u0007 ' }), SIMDI)!;
    expect(y).toMatchObject({ ihtiyac: 'su-gida', kisiSayisi: 99, not: '3 çocuk var' });
    expect(agKabloDogrula(kablo({ tur: 'yardim', ihtiyac: 'enkaz', kisiSayisi: 0 }), SIMDI)!.kisiSayisi).toBe(1);
    expect(agKabloDogrula(kablo({ tur: 'yardim', ihtiyac: 'pizza' as never }), SIMDI)).toBeNull();
    expect(yardimNotTemizle('ğ'.repeat(200))).toHaveLength(140);
    expect(yardimTemizle({ tur: 'ilac', kisiSayisi: '3', not: 'insülin' })).toEqual({ tur: 'ilac', kisiSayisi: 3, not: 'insülin' });
    expect(yardimTemizle({ tur: 'yok' })).toBeNull();
    expect(yardimMetni({ tur: 'enkaz', kisiSayisi: 2, not: 'Kat 3' })).toBe('🆘 Yardım çağrısı · Enkaz altında · 2 kişi · Kat 3');
  });

  it('geriye uyum: eski v1 ileti v3 sayılmaz, v3 ileti eski v1 doğrulamasından geçmez; bilinmeyen v3 türü yok sayılır', () => {
    const v1 = { v: 1, id: 'm1234567890ab', kanal: 'k0', t: SIMDI, atlama: 0, sure: 0, mime: 'text/plain', veri: 'AAAA' };
    expect(agKabloDogrula(v1, SIMDI)).toBeNull();
    expect(kabloDogrula(v1, SIMDI, OMUR_MS, MAKS_ATLAMA)).not.toBeNull();
    for (const tur of ['varlik', 'davet', 'davetYaniti', 'yardim', 'yardimaGidiyorum'] as const) {
      expect(kabloDogrula(kablo({ tur, hedef: 'ffff0000aaaa', kanal: 3, ihtiyac: 'enkaz', yardimId: 'y1234567890', davetId: 'd1234567890', kabul: true }), SIMDI, OMUR_MS, MAKS_ATLAMA)).toBeNull();
    }
    expect(agKabloDogrula(kablo({ tur: 'gelecektekiTur' as never }), SIMDI)).toBeNull();
    expect(agKabloDogrula({ ...kablo({ tur: 'varlik' }), v: 4 }, SIMDI)).toBeNull();
  });
});

// ─── Çok düğümlü ağ: A — B — C — D (zincir), bağlantı kimliği "x>y" ────────────────────────────────────────────────────────────

type Ag = { dugumler: Record<string, AgDugumu>; teslim: (simdi: number) => void; kuyruk: { kime: string; kimden: string; veri: string }[] };

function zincir(adlar: string[], baglar: [string, string][], cihaz: CihazTuru = 'iphone'): Ag {
  const kuyruk: Ag['kuyruk'] = [];
  const komsu: Record<string, string[]> = {};
  for (const [a, b] of baglar) {
    (komsu[a] ??= []).push(b);
    (komsu[b] ??= []).push(a);
  }
  const dugumler: Record<string, AgDugumu> = {};
  for (const ad of adlar) {
    const kisi = ad.toLowerCase() + '0'.repeat(11);
    dugumler[ad] = new AgDugumu(kisi, `${ad} Soyad`, cihaz, (k, haric, kime) => {
      // Bağlantı kimliği alıcı gözünden: "alıcı>gönderen". `haric` bu düğümün iletiyi aldığı bağlantıdır ("ben>kaynak").
      for (const n of komsu[ad] ?? []) {
        if (haric === `${ad}>${n}`) continue;
        if (kime && kime !== `${ad}>${n}`) continue;
        kuyruk.push({ kime: n, kimden: `${n}>${ad}`, veri: JSON.stringify(k) });
      }
    });
  }
  const teslim = (simdi: number) => {
    for (let i = 0; i < 1000 && kuyruk.length; i++) {
      const p = kuyruk.shift()!;
      dugumler[p.kime].al(JSON.parse(p.veri), p.kimden, simdi);
    }
  };
  return { dugumler, teslim, kuyruk };
}

function aktif(ad: string, baglar: [string, string][]): string[] {
  return baglar.flatMap(([a, b]) => (a === ad ? [`${ad}>${b}`] : b === ad ? [`${ad}>${a}`] : []));
}

describe('varlık ve cihaz listesi', () => {
  const baglar: [string, string][] = [['A', 'B'], ['B', 'C'], ['C', 'D'], ['D', 'E']];

  it('doğrudan komşu eşlenir; varlık en çok 3 atlama öteye ulaşır; ad maskeli', () => {
    const ag = zincir(['A', 'B', 'C', 'D', 'E'], baglar);
    for (const ad of 'ABCDE') ag.dugumler[ad].varlikYay(SIMDI);
    ag.teslim(SIMDI);
    const a = ag.dugumler.A.cihazlar(aktif('A', baglar), SIMDI);
    expect(a.dogrudanSayi).toBe(1);
    expect(a.cihazlar[0]).toMatchObject({ kisi: 'b00000000000', ad: 'B S****', dogrudan: true, atlama: 1, tur: 'iphone' });
    expect(a.cihazlar.map((c) => c.kisi)).toEqual(['b00000000000', 'c00000000000', 'd00000000000']);
    expect(a.cihazlar.find((c) => c.kisi === 'd00000000000')).toMatchObject({ dogrudan: false, atlama: 3 });
    expect(a.agdakiSayi).toBe(3); // E 4 atlama ötede → görünmez
  });

  it('aynı cihaz iki yoldan (Bluetooth + Wi-Fi) bağlıysa TEK sayılır; kimliği bilinmeyen bağlantı (dinleyen Mac) ayrı cihaz', () => {
    const ag = zincir(['A', 'B'], [['A', 'B']]);
    ag.dugumler.B.varlikYay(SIMDI);
    ag.teslim(SIMDI);
    // B'nin varlığı ikinci taşımadan da geldi (aynı ileti, farklı bağlantı): eşleme işlenir, ileti yinelenmiş sayılır.
    const ilk = ag.dugumler.B.varlikYay(SIMDI + 1);
    ag.dugumler.A.al(JSON.parse(JSON.stringify(ilk)), 'mpc:B', SIMDI + 1);
    ag.teslim(SIMDI + 1);
    const l = ag.dugumler.A.cihazlar(['A>B', 'mpc:B', 'ble:MAC-DINLEYICI'], SIMDI + 2);
    expect(l.dogrudanSayi).toBe(2);
    expect(l.cihazlar.filter((c) => c.kisi === 'b00000000000')).toHaveLength(1);
    expect(l.cihazlar.find((c) => c.kisi === '')).toMatchObject({ tur: 'bilinmiyor', dogrudan: true });
  });

  it('yeni bağlantı: iki taraf varlığı HEMEN alır (istek/yanıt) — periyodik varlık beklenmez, en çok 3 ileti, aktarılmaz', () => {
    const ag = zincir(['A', 'B', 'C'], [['A', 'B'], ['B', 'C']]);
    // Yalnız A—B bağlantısı yeni kuruldu: A kendi varlığını yanıt istekli yollar.
    ag.dugumler.A.yeniBaglanti('A>B', SIMDI);
    const ilk = JSON.parse(ag.kuyruk[0].veri);
    expect(ilk).toMatchObject({ tur: 'varlik', atlama: 0, yanitIste: true });
    let ileti = 0;
    const cyeGiden: Record<string, unknown>[] = [];
    for (let i = 0; i < 20 && ag.kuyruk.length; i++) {
      const p = ag.kuyruk.shift()!;
      if (p.kime === 'C') { cyeGiden.push(JSON.parse(p.veri)); continue; } // aktarılan kopya bu sayıma girmez
      ileti += 1;
      ag.dugumler[p.kime].al(JSON.parse(p.veri), p.kimden, SIMDI);
    }
    expect(ileti).toBeLessThanOrEqual(3);
    expect(ag.dugumler.A.cihazlar(['A>B'], SIMDI).cihazlar[0]).toMatchObject({ kisi: 'b00000000000', dogrudan: true });
    expect(ag.dugumler.B.cihazlar(['B>A', 'B>C'], SIMDI).cihazlar.find((c) => c.kisi === 'a00000000000')).toMatchObject({ dogrudan: true });
    // yanıt isteği aktarılan kopyada yok (yalnız doğrudan komşuya anlamlı)
    expect(cyeGiden.length).toBeGreaterThan(0);
    for (const k of cyeGiden) expect(k.yanitIste).toBeUndefined();
  });

  it('3 dk görülmeyen düşer; bağlantısı kopan doğrudan sayılmaz', () => {
    const ag = zincir(['A', 'B', 'C'], [['A', 'B'], ['B', 'C']]);
    ag.dugumler.B.varlikYay(SIMDI);
    ag.dugumler.C.varlikYay(SIMDI);
    ag.teslim(SIMDI);
    expect(ag.dugumler.A.cihazlar(['A>B'], SIMDI + VARLIK_ZAMAN_ASIMI_MS - 1).agdakiSayi).toBe(2);
    const sonra = ag.dugumler.A.cihazlar([], SIMDI + VARLIK_ZAMAN_ASIMI_MS);
    expect(sonra).toEqual({ cihazlar: [], dogrudanSayi: 0, agdakiSayi: 0 });
  });

  it('konum yalnız ≤2 dk tazeyse iletiye girer', () => {
    const ag = zincir(['A', 'B'], [['A', 'B']]);
    ag.dugumler.B.konum = { enlem: 38.4192, boylam: 27.1287, konumMs: SIMDI - KONUM_TAZE_MS - 1 };
    expect(ag.dugumler.B.varlikYay(SIMDI).enlem).toBeUndefined();
    ag.dugumler.B.konum = { enlem: 38.4192, boylam: 27.1287, konumMs: SIMDI - 1000 };
    ag.dugumler.B.varlikYay(SIMDI);
    ag.teslim(SIMDI);
    expect(ag.dugumler.A.cihazlar(['A>B'], SIMDI).cihazlar[0]).toMatchObject({ enlem: 38.4192, boylam: 27.1287 });
  });
});

describe('telsiz daveti (özel kanal)', () => {
  const baglar: [string, string][] = [['A', 'B'], ['B', 'C']];

  it('ağ üzerinden hedefe varır, yalnız hedefte "davet" olayı; kabul → iki taraf o kanala geçer, gönderene "kabul etti"', () => {
    const ag = zincir(['A', 'B', 'C'], baglar);
    const id = ag.dugumler.A.davetGonder('c00000000000', 92, SIMDI)!;
    ag.teslim(SIMDI);
    expect(ag.dugumler.B.olaylar).toEqual([]);
    expect(ag.dugumler.C.olaylar).toEqual([{ olay: 'davet', veri: { id, gonderenKisi: 'a00000000000', gonderenAd: 'A S****', kanal: 92, t: SIMDI } }]);
    expect(ag.dugumler.C.davetYanitla(id, true, SIMDI + 5000)).toBe(true);
    ag.teslim(SIMDI + 5000);
    expect(ag.dugumler.C.kanal).toBe('k92');
    expect(ag.dugumler.A.kanal).toBe('k92');
    expect(ag.dugumler.B.kanal).toBe('k0');
    expect(ag.dugumler.A.olaylar).toContainEqual({ olay: 'davetYaniti', veri: { id, kabul: true, kisi: 'c00000000000', ad: 'C S****', kanal: 92 } });
  });

  it('ret: kimse kanal değiştirmez; aynı davete ikinci yanıt yok sayılır; kendine davet ve geçersiz kanal reddedilir', () => {
    const ag = zincir(['A', 'B'], [['A', 'B']]);
    const id = ag.dugumler.A.davetGonder('b00000000000', 7, SIMDI)!;
    ag.teslim(SIMDI);
    expect(ag.dugumler.B.davetYanitla(id, false, SIMDI)).toBe(true);
    expect(ag.dugumler.B.davetYanitla(id, true, SIMDI)).toBe(false);
    ag.teslim(SIMDI);
    expect(ag.dugumler.A.kanal).toBe('k0');
    expect(ag.dugumler.A.olaylar).toContainEqual({ olay: 'davetYaniti', veri: { id, kabul: false, kisi: 'b00000000000', ad: 'B S****', kanal: 7 } });
    expect(ag.dugumler.A.davetGonder('a00000000000', 7, SIMDI)).toBeNull();
    expect(ag.dugumler.A.davetGonder('b00000000000', 0, SIMDI)).toBeNull();
    expect(ag.dugumler.A.davetGonder('b00000000000', 100, SIMDI)).toBeNull();
  });

  it('başkasının adına sahte yanıt (yanlış gönderen) yok sayılır', () => {
    const ag = zincir(['A', 'B', 'C'], baglar);
    const id = ag.dugumler.A.davetGonder('b00000000000', 9, SIMDI)!;
    ag.teslim(SIMDI);
    const sahte = { v: 3, tur: 'davetYaniti', id: 'sahte1234567', t: SIMDI, atlama: 0, kisi: 'c00000000000', ad: 'C', hedef: 'a00000000000', kanal: 9, davetId: id, kabul: true };
    ag.dugumler.A.al(sahte, 'A>B', SIMDI);
    expect(ag.dugumler.A.kanal).toBe('k0');
  });
});

describe('yardım çağrısı + yardıma gidiyorum', () => {
  it('ağa yayılır (16 atlamaya dek), her düğümde bir kez saklanır; "gidiyorum" çağrının gidenler listesine eklenir', () => {
    const adlar = Array.from({ length: 10 }, (_, i) => String.fromCharCode(65 + i));
    const baglar = adlar.slice(1).map((ad, i) => [adlar[i], ad] as [string, string]);
    const ag = zincir(adlar, baglar);
    const id = ag.dugumler.A.yardimGonder('enkaz', 3, 'Kat 2, merdiven çöktü', SIMDI);
    ag.teslim(SIMDI);
    const j = ag.dugumler.J.yardimlar.get(id)!;
    expect(j).toMatchObject({ tur: 'enkaz', kisiSayisi: 3, not: 'Kat 2, merdiven çöktü', ad: 'A S****', kisi: 'a00000000000', atlama: 9, kendim: false });
    expect(ag.dugumler.J.olaylar.filter((o) => o.olay === 'yardim')).toHaveLength(1);
    expect(ag.dugumler.A.yardimlar.get(id)!.kendim).toBe(true);

    expect(ag.dugumler.C.yardimaGidiyorum(id, SIMDI + 60_000)).toBe(true);
    ag.teslim(SIMDI + 60_000);
    expect(ag.dugumler.A.yardimlar.get(id)!.gidenler).toEqual([{ kisi: 'c00000000000', ad: 'C S****', t: SIMDI + 60_000 }]);
    expect(ag.dugumler.J.yardimlar.get(id)!.gidenler).toHaveLength(1);
    expect(ag.dugumler.C.yardimaGidiyorum('bilinmeyen12', SIMDI)).toBe(false);
  });

  it('döngülü ağda (üçgen) her ileti bir kez işlenir', () => {
    const baglar: [string, string][] = [['A', 'B'], ['B', 'C'], ['C', 'A']];
    const ag = zincir(['A', 'B', 'C'], baglar);
    ag.dugumler.A.yardimGonder('yarali', 1, '', SIMDI);
    ag.teslim(SIMDI);
    expect(ag.kuyruk).toHaveLength(0);
    expect(ag.dugumler.B.olaylar.filter((o) => o.olay === 'yardim')).toHaveLength(1);
    expect(ag.dugumler.C.olaylar.filter((o) => o.olay === 'yardim')).toHaveLength(1);
  });
});
