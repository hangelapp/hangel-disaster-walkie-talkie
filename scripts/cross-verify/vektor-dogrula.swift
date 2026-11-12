// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Uluslararası Sosyal Fayda Derneği (Social Business Global)
// Afet Telsizi ortak test vektörü — iOS (CryptoKit) tarafının Node/Java ile aynı baytı çözdüğünü doğrular.
// Çalıştırma (macOS): swift scripts/cross-verify/vektor-dogrula.swift
// Vektör: test/frame.test.ts ve android/src/test/java/org/hangel/walkietalkie/telsiz/TelsizSifreTest.java ile aynı.
import Foundation
import CryptoKit

let beklenenAnahtar = "99e74e836c088e5a8f2b7356d048d8b42a36457e8a269466f4a4292a4fb305a7"
let veri = "AAECAwQFBgcICQoL+0baBh95ID9tz+rXmIi0wSTal5y6VfpBjk4l3cGcR+bT9inDO1wgoKIR6mWXyJoJTuHTY05Rpo3PuG3iFwxlYZWpyY8rSAsD1b6mmb6YU88OA2wtgtBvwwVLklNe+YYpcU9JB035QaZb1YD55+BWCglN+Rn8fcwa"
let beklenenMetin = "Enkaz altında 2 kişi var, su lazım"

// DisasterWalkieTalkiePlugin.swift TelsizMotoru.anahtar(_:) ile birebir aynı türetme.
let ham = SymmetricKey(data: Data("hangel-afet-telsiz-v1".utf8))
let anahtar = HKDF<SHA256>.deriveKey(inputKeyMaterial: ham, salt: Data("test".utf8), info: Data("kanal-anahtari".utf8), outputByteCount: 32)
let hex = anahtar.withUnsafeBytes { Data($0) }.map { String(format: "%02x", $0) }.joined()
guard hex == beklenenAnahtar else { print("HATA anahtar \(hex)"); exit(1) }
let kutu = try ChaChaPoly.SealedBox(combined: Data(base64Encoded: veri)!)
let acik = try ChaChaPoly.open(kutu, using: anahtar)
let o = try JSONSerialization.jsonObject(with: acik) as! [String: Any]
guard o["metin"] as? String == beklenenMetin, o["ad"] as? String == "Ayşe" else { print("HATA içerik"); exit(1) }
// Swift tarafı şifreler → Node/Java aynı anahtarla açabilsin diye yeniden şifrele-aç turu.
let yeni = try ChaChaPoly.seal(acik, using: anahtar).combined
_ = try ChaChaPoly.open(ChaChaPoly.SealedBox(combined: yeni), using: anahtar)
print("TAMAM: iOS CryptoKit ortak vektörü çözdü")
