// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Uluslararası Sosyal Fayda Derneği (Social Business Global)
// capraz-dogrula.sh tarafından DisasterWalkieTalkiePlugin.swift'ten çıkarılan türlerin ardına eklenir (tek başına derlenmez).
func anahtar(_ kanal: String) -> SymmetricKey {
    // DisasterWalkieTalkiePlugin.swift TelsizMotoru.anahtar(_:) ile birebir aynı türetme (ortak vektör scripts/cross-verify/vektor-dogrula.swift).
    HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: Data("hangel-afet-telsiz-v1".utf8)), salt: Data(kanal.utf8),
                           info: Data("kanal-anahtari".utf8), outputByteCount: 32)
}
let arg = CommandLine.arguments.dropFirst().first ?? ""
switch arg {
case "uret":
    // Swift motorunun durumGonder yolu: TelsizIcerik → ChaChaPoly → TelsizKablo → BLE çerçeveleri (MTU 185, sıra taşması).
    var ic = TelsizIcerik(ad: "Ayşe", ses: "")
    ic.metin = "Enkaz altındayım / yaralıyım — أنا تحت الأنقاض"
    ic.enlem = 38.42370
    ic.boylam = 27.14280
    ic.durum = "yardim"
    ic.kisi = "a1b2c3d4e5f6"
    let veri = try! ChaChaPoly.seal(try! JSONEncoder().encode(ic), using: anahtar("k0")).combined.base64EncodedString()
    let k = TelsizKablo(v: 1, id: "0123456789abcdef0123456789abcdef", kanal: "k0", t: Int64(Date().timeIntervalSince1970 * 1000),
                        atlama: 2, sure: 0, mime: "text/plain", veri: veri)
    for c in TelsizCerceve.cercevele(try! JSONEncoder().encode(k), sira: 0xFFFF_FFFF, parcaBoyutu: 185) {
        print(c.map { String(format: "%02x", $0) }.joined())
    }
case "coz":
    let b = TelsizBirlestirici()
    var sonuc: Data?
    while let satir = readLine() {
        var d = Data()
        var i = satir.startIndex
        while i < satir.endIndex { let j = satir.index(i, offsetBy: 2); d.append(UInt8(satir[i..<j], radix: 16)!); i = j }
        if let r = b.ekle(d) { sonuc = r }
    }
    guard let s = sonuc, let k = try? JSONDecoder().decode(TelsizKablo.self, from: s),
          let kutu = try? ChaChaPoly.SealedBox(combined: Data(base64Encoded: k.veri)!),
          let acik = try? ChaChaPoly.open(kutu, using: anahtar(k.kanal)),
          let ic = try? JSONDecoder().decode(TelsizIcerik.self, from: acik) else { print("HATA"); exit(1) }
    let o: [String: Any?] = ["id": k.id, "kanal": k.kanal, "t": k.t, "atlama": k.atlama, "mime": k.mime, "ad": ic.ad, "metin": ic.metin,
                             "durum": ic.durum, "kisi": ic.kisi, "enlem": ic.enlem, "boylam": ic.boylam]
    print(String(data: try! JSONSerialization.data(withJSONObject: o.compactMapValues { $0 }, options: [.sortedKeys]), encoding: .utf8)!)
case "metin":
    // Her satır JSON dizgesi; çıktı: temizlenmiş metnin JSON'u ya da null.
    while let satir = readLine() {
        let girdi = try! JSONSerialization.jsonObject(with: Data(satir.utf8), options: [.fragmentsAllowed]) as! String
        if let t = TelsizMotoru.metinTemizle(girdi) {
            print(String(data: try! JSONSerialization.data(withJSONObject: t, options: [.fragmentsAllowed]), encoding: .utf8)!)
        } else { print("null") }
    }
default:
    print("kullanım: uret | coz | metin"); exit(2)
}
