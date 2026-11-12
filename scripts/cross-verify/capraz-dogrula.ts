// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Uluslararası Sosyal Fayda Derneği (Social Business Global)
// geliştirici doğrulama betiği (capraz-dogrula.sh); kullanıcıya görünen metin yok.
import { execFileSync } from 'node:child_process';
import { createCipheriv, createDecipheriv, hkdfSync, randomBytes } from 'node:crypto';
import { ANAHTAR_IKM, ANAHTAR_INFO, Birlestirici, METIN_MIME, cercevele, kabloDogrula, metinTemizle } from '../../src/protocol/frame';
import { MAKS_ATLAMA, OMUR_MS } from '../../src/protocol/channel';

const kosucu = process.argv[2];
let hata = 0;
const tamam = (ad: string, kosul: boolean, ek = '') => {
  console.log(`${kosul ? 'GEÇTİ' : 'KALDI'}  ${ad}${ek ? ` — ${ek}` : ''}`);
  if (!kosul) hata += 1;
};
const anahtar = (k: string) => Buffer.from(hkdfSync('sha256', Buffer.from(ANAHTAR_IKM), Buffer.from(k), Buffer.from(ANAHTAR_INFO), 32));

// 1) Swift üretir → TS birleştirir, doğrular, çözer.
const satirlar = execFileSync(kosucu, ['uret'], { encoding: 'utf8' }).trim().split('\n');
const b = new Birlestirici();
let yuk: Uint8Array | null = null;
for (const s of satirlar.reverse()) yuk = b.ekle(Buffer.from(s, 'hex')) ?? yuk;
const k = yuk ? kabloDogrula(JSON.parse(Buffer.from(yuk).toString('utf8')), Date.now(), OMUR_MS, MAKS_ATLAMA) : null;
tamam('Swift çerçeveleri (MTU 185, sırasız) TS ile birleşti ve kablo doğrulandı', !!k, `${satirlar.length} çerçeve`);
if (k) {
  const v = Buffer.from(k.veri, 'base64');
  const d = createDecipheriv('chacha20-poly1305', anahtar(k.kanal), v.subarray(0, 12), { authTagLength: 16 });
  d.setAuthTag(v.subarray(v.length - 16));
  const ic = JSON.parse(Buffer.concat([d.update(v.subarray(12, v.length - 16)), d.final()]).toString('utf8'));
  tamam('Swift şifreli içeriği Node çözdü (Türkçe + Arapça + durum + kişi + konum)',
    ic.metin === 'Enkaz altındayım / yaralıyım — أنا تحت الأنقاض' && ic.durum === 'yardim' && ic.kisi === 'a1b2c3d4e5f6' && ic.enlem === 38.4237 && ic.ad === 'Ayşe',
    JSON.stringify(ic).slice(0, 120));
}

// 2) TS üretir (sırasız, MTU 20) → Swift birleştirir ve çözer.
const ic = { ad: 'محمد', ses: '', metin: 'Güvendeyim — İğdır 👨‍👩‍👧', durum: 'guvende', kisi: '0123456789ab', enlem: 36.2021, boylam: 36.1604 };
const nonce = randomBytes(12);
const c = createCipheriv('chacha20-poly1305', anahtar('k42'), nonce, { authTagLength: 16 });
const veri = Buffer.concat([nonce, Buffer.concat([c.update(Buffer.from(JSON.stringify(ic))), c.final()]), c.getAuthTag()]).toString('base64');
const kablo = { v: 1, id: 'ffffffffffffffff', kanal: 'k42', t: Date.now(), atlama: 5, sure: 0, mime: METIN_MIME, veri };
const cerceveler = cercevele(Buffer.from(JSON.stringify(kablo)), 7, 20).map((x) => Buffer.from(x).toString('hex'));
const karisik = [...cerceveler.slice(1), cerceveler[0], cerceveler[2]]; // sırasız + yinelenen parça
const cikti = JSON.parse(execFileSync(kosucu, ['coz'], { input: karisik.join('\n') + '\n', encoding: 'utf8' }));
tamam('TS çerçeveleri (MTU 20, sırasız, yinelenen parça) Swift ile birleşti ve çözüldü',
  cikti.metin === ic.metin && cikti.ad === ic.ad && cikti.durum === 'guvende' && cikti.atlama === 5 && cikti.kanal === 'k42',
  `${cerceveler.length} çerçeve`);

// 3) metinTemizle Swift ↔ TS aynı mı (Java 08.11'de aynı kümeyle eşitlendi).
const ornekler = ['  merhaba\u0007 ', 'ş'.repeat(400), '👨‍👩‍👧'.repeat(100), 'é'.repeat(300), '　 x　', '﻿y﻿', 'أنا تحت الأنقاض', '\u0085z\u0085', '   '];
const sw = execFileSync(kosucu, ['metin'], { input: ornekler.map((x) => JSON.stringify(x)).join('\n') + '\n', encoding: 'utf8' }).trim().split('\n').map((x) => JSON.parse(x));
ornekler.forEach((o, i) => {
  const ts = metinTemizle(o);
  tamam(`metinTemizle #${i + 1}`, sw[i] === ts, sw[i] === ts ? '' : `swift=${JSON.stringify(sw[i])?.slice(0, 40)} (${sw[i] ? Array.from(sw[i] as string).length : 0} kod nok.) ts=${JSON.stringify(ts)?.slice(0, 40)} (${ts ? Array.from(ts).length : 0})`);
});

console.log(hata ? `SONUÇ: ${hata} kaldı` : 'SONUÇ: hepsi geçti');
process.exit(hata ? 1 : 0);
