// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Uluslararası Sosyal Fayda Derneği (Social Business Global)
import { describe, expect, it } from 'vitest';
import {
  MAKS_ATLAMA,
  OMUR_MS,
  base64Bayt,
  cevrimdisiBelgeKimligi,
  cevrimdisiMetaDogrula,
  ilKanali,
  kanalGecerliMi,
  mesafeKm,
  mesafeMetni,
  mimeTemizle,
  mimeUzanti,
  yaklasikKonum,
} from '../src/protocol/channel';

describe('afet telsizi kuralları', () => {
  it('il adından kanal üretir (Türkçe harfler)', () => {
    expect(ilKanali('İstanbul')).toBe('il-istanbul');
    expect(ilKanali('Şanlıurfa')).toBe('il-sanliurfa');
    expect(ilKanali('Kahramanmaraş')).toBe('il-kahramanmaras');
    expect(ilKanali('')).toBeNull();
    expect(ilKanali(null)).toBeNull();
  });

  it('kanal doğrulaması', () => {
    expect(kanalGecerliMi('test')).toBe(true);
    expect(kanalGecerliMi('il-izmir')).toBe(true);
    expect(kanalGecerliMi('il-')).toBe(false);
    expect(kanalGecerliMi('herkes')).toBe(false);
    expect(kanalGecerliMi('il-../x')).toBe(false);
  });

  it('MIME temizleme ve uzantı', () => {
    expect(mimeTemizle('audio/webm;codecs=opus')).toBe('audio/webm');
    expect(mimeTemizle('audio/mp4')).toBe('audio/mp4');
    expect(mimeTemizle('text/html')).toBeNull();
    expect(mimeUzanti('audio/webm')).toBe('webm');
    expect(mimeUzanti('audio/mp4')).toBe('m4a');
  });

  it('konum ~1 km yuvarlanır, geçersiz reddedilir', () => {
    expect(yaklasikKonum(41.01234, 28.98765)).toEqual({ lat: 41.01, lng: 28.99 });
    expect(yaklasikKonum(999, 1)).toBeNull();
    expect(yaklasikKonum('x', 1)).toBeNull();
  });

  it('mesafe ve metni', () => {
    const km = mesafeKm({ lat: 41.0, lng: 29.0 }, { lat: 41.1, lng: 29.0 });
    expect(km).toBeGreaterThan(10);
    expect(km).toBeLessThan(12);
    expect(mesafeMetni(0.4, 'tr')).toBe('<1 km');
    expect(mesafeMetni(3.26, 'en')).toBe('~3.3 km');
  });

  it('çevrimdışı belge kimliği ve meta', () => {
    expect(cevrimdisiBelgeKimligi('abcdef1234567890')).toBe('c_abcdef1234567890');
    expect(cevrimdisiBelgeKimligi('kısa')).toBeNull();
    expect(cevrimdisiBelgeKimligi('a/b/c/d/e/f/g/h')).toBeNull();
    const simdi = 1_800_000_000_000;
    const m = cevrimdisiMetaDogrula({ id: 'abcdef1234567890', olusturulduMs: simdi - 1000, atlama: 99, ad: ' Ayşe ', kendim: true }, simdi);
    expect(m).toEqual({ id: 'abcdef1234567890', olusturulduMs: simdi - 1000, atlama: MAKS_ATLAMA, ad: 'Ayşe', kendim: true });
    expect(cevrimdisiMetaDogrula({ id: 'abcdef1234567890', olusturulduMs: simdi - OMUR_MS - 1 }, simdi)).toBeNull();
    expect(cevrimdisiMetaDogrula({ id: 'abcdef1234567890', olusturulduMs: simdi + 3_600_000 }, simdi)).toBeNull();
    expect(cevrimdisiMetaDogrula(null, simdi)).toBeNull();
  });

  it('base64 bayt tahmini', () => {
    expect(base64Bayt(Buffer.from('hangel telsiz').toString('base64'))).toBe(13);
    expect(base64Bayt('data:audio/webm;base64,' + Buffer.from('abcd').toString('base64'))).toBe(4);
  });
});
