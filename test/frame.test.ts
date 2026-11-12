// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Uluslararası Sosyal Fayda Derneği (Social Business Global)
import { createCipheriv, createDecipheriv, hkdfSync } from 'node:crypto';
import { describe, expect, it } from 'vitest';
import {
  ANAHTAR_IKM,
  ANAHTAR_INFO,
  BLE_GECMIS_SES,
  BLE_RX_UUID,
  BLE_SERVIS_UUID,
  BLE_TX_UUID,
  Birlestirici,
  CERCEVE_BASLIK,
  MAKS_METIN,
  MAKS_YUK_BAYT,
  METIN_MIME,
  bleGecmisi,
  cerceveCoz,
  cercevele,
  kabloDogrula,
  metinTemizle,
} from '../src/protocol/frame';
import { MAKS_ATLAMA, OMUR_MS } from '../src/protocol/channel';

/**
 * ORTAK TEST VEKTÖRÜ — aynı değerler:
 *   android/src/test/java/org/hangel/walkietalkie/telsiz/TelsizSifreTest.java
 *   scripts/cross-verify/vektor-dogrula.swift (iOS CryptoKit)
 * Değiştirirsen üçünü birlikte değiştir.
 */
const VEKTOR = {
  kanal: 'test',
  anahtarHex: '99e74e836c088e5a8f2b7356d048d8b42a36457e8a269466f4a4292a4fb305a7',
  veri: 'AAECAwQFBgcICQoL+0baBh95ID9tz+rXmIi0wSTal5y6VfpBjk4l3cGcR+bT9inDO1wgoKIR6mWXyJoJTuHTY05Rpo3PuG3iFwxlYZWpyY8rSAsD1b6mmb6YU88OA2wtgtBvwwVLklNe+YYpcU9JB035QaZb1YD55+BWCglN+Rn8fcwa',
  icerik: { ad: 'Ayşe', ses: '', metin: 'Enkaz altında 2 kişi var, su lazım', enlem: 38.4237, boylam: 27.1428 },
};

function anahtar(kanal: string): Buffer {
  return Buffer.from(hkdfSync('sha256', Buffer.from(ANAHTAR_IKM), Buffer.from(kanal), Buffer.from(ANAHTAR_INFO), 32));
}

function ac(veri: string, kanal: string): unknown {
  const b = Buffer.from(veri, 'base64');
  const d = createDecipheriv('chacha20-poly1305', anahtar(kanal), b.subarray(0, 12), { authTagLength: 16 });
  d.setAuthTag(b.subarray(b.length - 16));
  return JSON.parse(Buffer.concat([d.update(b.subarray(12, b.length - 16)), d.final()]).toString('utf8'));
}

describe('afet telsizi ortak kablo biçimi', () => {
  it('UUID’ler aynı tabanda ve "hangel" son baytlarda', () => {
    for (const u of [BLE_SERVIS_UUID, BLE_RX_UUID, BLE_TX_UUID]) {
      expect(u).toMatch(/^7A1E000[123]-4A6E-4C2B-9F3D-68616E67656C$/);
    }
  });

  it('ortak vektör: anahtar türetme ve çözme (iOS CryptoKit / Java ile aynı)', () => {
    expect(anahtar(VEKTOR.kanal).toString('hex')).toBe(VEKTOR.anahtarHex);
    expect(ac(VEKTOR.veri, VEKTOR.kanal)).toEqual(VEKTOR.icerik);
  });

  it('başka kanalın anahtarıyla açılmaz; tek bayt değişirse açılmaz', () => {
    expect(() => ac(VEKTOR.veri, 'il-izmir')).toThrow();
    const b = Buffer.from(VEKTOR.veri, 'base64');
    b[20] ^= 1;
    expect(() => ac(b.toString('base64'), VEKTOR.kanal)).toThrow();
  });

  it('şifrele → aç turu (nonce ‖ şifreli ‖ etiket)', () => {
    const nonce = Buffer.alloc(12, 7);
    const c = createCipheriv('chacha20-poly1305', anahtar('il-hatay'), nonce, { authTagLength: 16 });
    const ct = Buffer.concat([c.update(Buffer.from('{"ad":"","ses":"AAAA"}')), c.final()]);
    const veri = Buffer.concat([nonce, ct, c.getAuthTag()]).toString('base64');
    expect(ac(veri, 'il-hatay')).toEqual({ ad: '', ses: 'AAAA' });
  });

  it('çerçeveleme: böl ve sırasız birleştir', () => {
    const yuk = new Uint8Array(1000).map((_, i) => i % 251);
    const c = cercevele(yuk, 0xdeadbeef, 100);
    expect(c.length).toBe(Math.ceil(1000 / (100 - CERCEVE_BASLIK)));
    expect(c.every((x) => x.length <= 100)).toBe(true);
    const z = cerceveCoz(c[1])!;
    expect(z.sira).toBe(0xdeadbeef);
    expect(z.parca).toBe(1);
    expect(z.sayi).toBe(c.length);
    const b = new Birlestirici();
    const karisik = [...c].reverse();
    let sonuc: Uint8Array | null = null;
    for (const x of karisik) sonuc = b.ekle(x) ?? sonuc;
    expect(sonuc).toEqual(yuk);
    expect(b.bekleyen).toBe(0);
  });

  it('çerçeve: yinelenen parça sayılmaz, bozuk başlık atılır', () => {
    const c = cercevele(new Uint8Array([1, 2, 3, 4, 5]), 1, 12);
    expect(c.length).toBe(2);
    const b = new Birlestirici();
    expect(b.ekle(c[0])).toBeNull();
    expect(b.ekle(c[0])).toBeNull();
    expect(b.ekle(c[1])).toEqual(new Uint8Array([1, 2, 3, 4, 5]));
    expect(cerceveCoz(new Uint8Array([2, 0, 0, 0, 1, 0, 0, 0, 1, 9]))).toBeNull();
    expect(cerceveCoz(new Uint8Array([1, 0, 0, 0, 1, 0, 1, 0, 1, 9]))).toBeNull();
  });

  it('çerçeve baytları Java (TelsizSifreTest.tsIleAyniBaslik) ve Swift ile birebir aynı', () => {
    const c = cercevele(new Uint8Array([1, 2, 3, 4, 5]), 1, 12);
    expect(Array.from(c[0])).toEqual([1, 0, 0, 0, 1, 0, 0, 0, 2, 1, 2, 3]);
    expect(Array.from(c[1])).toEqual([1, 0, 0, 0, 1, 0, 1, 0, 2, 4, 5]);
  });

  it('çerçeve: yarım mesaj zaman aşımında atılır', () => {
    const c = cercevele(new Uint8Array(30), 5, 19);
    const b = new Birlestirici();
    b.ekle(c[0], 0);
    expect(b.bekleyen).toBe(1);
    b.ekle(cercevele(new Uint8Array(3), 6, 19)[0], 61_000);
    expect(b.bekleyen).toBe(0);
  });

  it('çerçeve: boyut sınırları', () => {
    expect(() => cercevele(new Uint8Array(0), 1, 100)).toThrow();
    expect(() => cercevele(new Uint8Array(MAKS_YUK_BAYT + 1), 1, 100)).toThrow();
    expect(() => cercevele(new Uint8Array(10), 1, CERCEVE_BASLIK)).toThrow();
  });

  it('kablo doğrulama: ömür, aktarım, kimlik', () => {
    const simdi = 1_800_000_000_000;
    const iyi = { v: 1, id: 'abcdef0123456789', kanal: 'test', t: simdi - 1000, atlama: 3, sure: 0, mime: METIN_MIME, veri: 'x' };
    expect(kabloDogrula(iyi, simdi, OMUR_MS, MAKS_ATLAMA)).not.toBeNull();
    expect(kabloDogrula({ ...iyi, v: 2 }, simdi, OMUR_MS, MAKS_ATLAMA)).toBeNull();
    expect(kabloDogrula({ ...iyi, id: '../x' }, simdi, OMUR_MS, MAKS_ATLAMA)).toBeNull();
    expect(kabloDogrula({ ...iyi, t: simdi - OMUR_MS }, simdi, OMUR_MS, MAKS_ATLAMA)).toBeNull();
    expect(kabloDogrula({ ...iyi, atlama: MAKS_ATLAMA + 1 }, simdi, OMUR_MS, MAKS_ATLAMA)).toBeNull();
    expect(kabloDogrula({ ...iyi, t: simdi + 10 * 60_000 }, simdi, OMUR_MS, MAKS_ATLAMA)).toBeNull();
  });

  it('Bluetooth geçmişi: metinlerin hepsi + en yeni 3 ses, aktarım hakkı bitenler yok', () => {
    const simdi = 10_000_000;
    const liste = [
      ...Array.from({ length: 6 }, (_, i) => ({ id: `s${i}`, t: simdi - i * 1000, atlama: 0, mime: 'audio/mp4' })),
      ...Array.from({ length: 4 }, (_, i) => ({ id: `m${i}`, t: simdi - 500 - i * 1000, atlama: 1, mime: METIN_MIME })),
      { id: 'bitmis', t: simdi, atlama: MAKS_ATLAMA, mime: METIN_MIME },
      { id: 'eski', t: simdi - OMUR_MS, atlama: 0, mime: METIN_MIME },
    ];
    const g = bleGecmisi(liste, simdi, OMUR_MS, MAKS_ATLAMA);
    expect(g.filter((m) => m.mime !== METIN_MIME).map((m) => m.id)).toEqual(['s0', 's1', 's2']);
    expect(g.filter((m) => m.mime === METIN_MIME)).toHaveLength(4);
    expect(g.find((m) => m.id === 'bitmis' || m.id === 'eski')).toBeUndefined();
    expect(BLE_GECMIS_SES).toBe(3);
  });

  it('metin temizleme', () => {
    expect(metinTemizle('  merhaba\u0007 ')).toBe('merhaba');
    expect(metinTemizle('   ')).toBeNull();
    expect(metinTemizle(5)).toBeNull();
    expect(Array.from(metinTemizle('ş'.repeat(400)) as string)).toHaveLength(MAKS_METIN);
  });
});
