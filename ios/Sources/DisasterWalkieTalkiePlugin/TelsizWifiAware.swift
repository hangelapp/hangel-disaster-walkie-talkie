// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Uluslararası Sosyal Fayda Derneği (Social Business Global)
//
// TelsizWifiAware — Afet Telsizi'nin Wi-Fi Aware taşıması (2026-11-06).
//
// Ne yapar: internet ve baz istasyonu yokken, ÖNCEDEN EŞLEŞTİRİLMİŞ iPhone'lar (aile, ekip, mahalle gönüllüleri) arasında
// doğrudan Wi-Fi bağlantısı kurar ve Afet Telsizi motorunun (DisasterWalkieTalkiePlugin.swift → TelsizMotoru) mesaj zincirini bu
// bağlantıdan da taşır: sesli ve yazılı telsiz mesajları (yardım çağrıları dahil, isteğe bağlı konumla) ve duyurular.
// Her telefon alan + gönderen + aktarıcıdır; kimlikle tekilleştirme, 12 aktarım sınırı ve kanal şifresi motordadır
// (MultipeerConnectivity / Bluetooth LE ile aynı kablo biçimi). Yeni bağlanan telefona son 72 saatin mesajları gider.
//
// Neden ek taşıma: MultipeerConnectivity eşleştirme istemez ama yalnız uygulama ön plandayken çalışır; Wi-Fi Aware
// eşleştirilmiş telefonlarla uygulama arka plandayken de bağlantıyı sürdürebilir ve menzili/hızı daha yüksektir.
//
// Sınırlar (Apple): iOS 26+, iPhone 12 ve sonrası. iPhone ↔ iPhone bağlantı yalnız EŞLEŞTİRİLMİŞ cihazlar arasında kurulur
// (sistemin eşleştirme ekranı, PIN ile; DeviceDiscoveryUI). Desteklemeyen cihazda / eski iOS'ta bu dosya hiçbir şey
// çalıştırmaz, JS getWifiAwareStatus().supported false döner.
// Info.plist WiFiAwareServices: "_hangel-telsiz._tcp" (Publishable + Subscribable); yetki com.apple.developer.wifi-aware.
// Yetki profilde yoksa uygulama yetkiyi ve Info.plist anahtarını birlikte çıkarmalıdır → destek = false.
//
// Gizlilik: Wi-Fi Aware bağlantısı Wi-Fi katmanında kimlik doğrulamalı ve şifreli; içerik ayrıca kanal anahtarıyla şifreli.
// Sunucuya hiçbir şey gitmez; eşleştirilen cihaz listesi sistemde (Ayarlar) tutulur.

import Foundation
import UIKit
#if canImport(WiFiAware)
import WiFiAware
import Network
import DeviceDiscoveryUI
#endif

enum WifiAwareKopru {
    static let servis = "_hangel-telsiz._tcp"
    private static var degisti: (() -> Void)?
    private static var kuruldu = false

    /// Eklenti yüklenince (ana iş parçacığı): destekleyen cihazda taşımayı motora bağlar ve eşleşmiş cihaz sayısını izler.
    static func kur(_ d: @escaping () -> Void) {
        degisti = d
        guard !kuruldu else { return }
        kuruldu = true
        #if canImport(WiFiAware)
        if #available(iOS 26.0, *), destekli {
            let t = TelsizWifiAware.shared
            t.durumDegisti = { DispatchQueue.main.async { WifiAwareKopru.degisti?() } }
            t.eslesmeleriIzle()
            TelsizMotoru.shared.ekTasimaBagla(t)
        }
        #endif
    }

    /// Cihaz Wi-Fi Aware'i destekliyor ve servis Info.plist'te tanımlı mı (yetki çıkarıldıysa anahtar da yoktur).
    static var destekli: Bool {
        #if canImport(WiFiAware)
        if #available(iOS 26.0, *) {
            guard Bundle.main.object(forInfoDictionaryKey: "WiFiAwareServices") != nil else { return false }
            return WACapabilities.supportedFeatures.contains(.wifiAware)
                && WAPublishableService.allServices[servis] != nil
                && WASubscribableService.allServices[servis] != nil
        }
        #endif
        return false
    }

    static func durum() -> [String: Any] {
        var o: [String: Any] = ["destek": destekli, "eslesmis": 0, "bagli": 0]
        #if canImport(WiFiAware)
        if #available(iOS 26.0, *), destekli {
            o["eslesmis"] = TelsizWifiAware.shared.eslesmisSayisi
            o["bagli"] = TelsizWifiAware.shared.bagliSayisi
        }
        #endif
        return o
    }

    /// Sistemin eşleştirme ekranı. rol "gorunur": bu telefon görünür olur, diğeri onu bulup PIN girer (yayıncı tarafı);
    /// rol "ara": yakındaki görünür telefonu listeden seçer (abone tarafı). Ekran açıkken arka plandaki taşıma duraklar
    /// (aynı servis aynı anda iki kez yayınlanamaz), kapanınca sürer. `kapat`: web'in verdiği "Kapat" yazısı (11 dil).
    @MainActor
    static func eslesmeEkraniniAc(rol: String, kapat: String, uzerinde vc: UIViewController?) -> Bool {
        #if canImport(WiFiAware)
        if #available(iOS 26.0, *), destekli, let vc {
            return TelsizWifiAware.shared.eslesmeEkrani(rol: rol, kapat: kapat, uzerinde: vc)
        }
        #endif
        return false
    }
}

#if canImport(WiFiAware)

/// Wi-Fi Aware üzerinden TLV çerçeveli TCP bağlantıları; her telefon hem yayıncı (gelen bağlantı) hem abone (giden bağlantı).
@available(iOS 26.0, *)
final class TelsizWifiAware: TelsizEkTasima, @unchecked Sendable {
    static let shared = TelsizWifiAware()

    var yukAlindi: ((String, Data) -> Void)?
    var yeniBaglanti: ((String) -> Void)?
    var baglantilarDegisti: (([String]) -> Void)?
    var durumDegisti: (() -> Void)?

    private struct Bag {
        let cihaz: WAPairedDevice.ID
        let ad: String
        let giden: AsyncStream<Data>.Continuation
    }

    private let kilit = NSLock()
    private var baglar: [String: Bag] = [:]
    private var dinleyiciGorevi: Task<Void, Never>?
    private var tarayiciGorevi: Task<Void, Never>?
    private var izlemeGorevi: Task<Void, Never>?
    private var istendi = false
    private var duraklatildi = false
    private(set) var eslesmisSayisi = 0

    /// 30 sn sesli mesaj ~250 KB base64; JSON + pay.
    private static let maksYuk = 3 * 1024 * 1024

    var bagliSayisi: Int {
        kilit.lock(); defer { kilit.unlock() }
        return Set(baglar.values.map(\.cihaz)).count
    }

    private var yayin: WAPublishableService? { WAPublishableService.allServices[WifiAwareKopru.servis] }
    private var abone: WASubscribableService? { WASubscribableService.allServices[WifiAwareKopru.servis] }

    // MARK: TelsizEkTasima

    func baslat() {
        kilit.lock()
        istendi = true
        let durakli = duraklatildi
        kilit.unlock()
        if !durakli { calistir() }
    }

    func durdur() {
        kilit.lock()
        istendi = false
        kilit.unlock()
        kes()
    }

    func gonder(_ veri: Data, haric: String?) {
        guard veri.count <= Self.maksYuk else { return }
        kilit.lock()
        let hedefler = baglar.filter { $0.key != haric }.map(\.value.giden)
        kilit.unlock()
        for h in hedefler { h.yield(veri) }
    }

    func gonderKime(_ id: String, _ veri: Data) {
        guard veri.count <= Self.maksYuk else { return }
        kilit.lock()
        let h = baglar[id]?.giden
        kilit.unlock()
        h?.yield(veri)
    }

    // MARK: Eşleşmiş cihazlar

    func eslesmeleriIzle() {
        guard izlemeGorevi == nil else { return }
        izlemeGorevi = Task { [weak self] in
            do {
                for try await cihazlar in WAPairedDevice.allDevices {
                    guard let self else { return }
                    self.eslesmisSayisi = cihazlar.count
                    self.durumDegisti?()
                }
            } catch {
                // Destek/yetki yoksa akış hata verir; sayı 0 kalır.
            }
        }
    }

    // MARK: Bağlantılar

    private func calistir() {
        guard let yayin, let abone else { return }
        kilit.lock()
        let zatenVar = dinleyiciGorevi != nil
        kilit.unlock()
        guard !zatenVar else { return }

        // Gelen: bu telefon servisi yayınlar, eşleşmiş telefonlardan bağlantı kabul eder.
        // Tekil (shared) nesne; görevler durdur()'da iptal edilir → güçlü yakalama döngü yaratmaz.
        let ben = self
        let dinle = Task {
            do {
                let dinleyici = try NetworkListener(
                    for: WAPublisherListener.wifiAware(.connecting(to: yayin, from: .allPairedDevices)),
                    using: .parameters { TLV { TCP() } }.wifiAware { $0.performanceMode = .bulk }
                )
                try await dinleyici.run { baglanti in
                    let cihaz = await TelsizWifiAware.cihazi(baglanti)
                    await ben.yurut(baglanti, cihaz: cihaz?.id ?? 0, ad: cihaz?.name ?? "iPhone", yon: "g")
                }
            } catch {
                // İptal (durdur) ya da radyo meşgul: sessiz; motor yeniden başlatınca tekrar dener.
            }
        }
        // Giden: eşleşmiş telefonların yayınını bulur, henüz bağlı olmadıklarımıza bağlanır.
        let tara = Task {
            do {
                let tarayici = NetworkBrowser(for: WASubscriberBrowser.wifiAware(.connecting(to: .allPairedDevices, from: abone)))
                try await tarayici.run { noktalar in
                    for nokta in noktalar where !ben.bagliMi(nokta.device.id) {
                        let cihaz = nokta.device
                        Task {
                            let baglanti = NetworkConnection(to: nokta, using: .parameters { TLV { TCP() } }.wifiAware { $0.performanceMode = .bulk })
                            await ben.yurut(baglanti, cihaz: cihaz.id, ad: cihaz.name ?? "iPhone", yon: "c")
                        }
                    }
                }
            } catch {
                // İptal ya da destek yok: sessiz.
            }
        }
        kilit.lock()
        dinleyiciGorevi = dinle
        tarayiciGorevi = tara
        kilit.unlock()
    }

    private func kes() {
        kilit.lock()
        let g = [dinleyiciGorevi, tarayiciGorevi]
        dinleyiciGorevi = nil
        tarayiciGorevi = nil
        let acik = baglar.values.map(\.giden)
        baglar = [:]
        kilit.unlock()
        g.forEach { $0?.cancel() }
        acik.forEach { $0.finish() }
        bildirBaglantilar()
    }

    /// Gelen bağlantının eşleşmiş cihazı (iOS 26.4+ uç noktadan, öncesinde bağlantı yolundan).
    private static func cihazi(_ b: NetworkConnection<TLV>) async -> WAPairedDevice? {
        if #available(iOS 26.4, *), let d = b.remoteEndpoint?.wifiAware?.device { return d }
        return try? await b.currentPath?.wifiAware?.endpoint.device
    }

    /// Kilitli bölge (async işlevlerden de güvenle çağrılır).
    private func kilitli<T>(_ f: () -> T) -> T {
        kilit.lock(); defer { kilit.unlock() }
        return f()
    }

    private func bagliMi(_ cihaz: WAPairedDevice.ID) -> Bool {
        kilit.lock(); defer { kilit.unlock() }
        return baglar.values.contains { $0.cihaz == cihaz }
    }

    /// Bir bağlantıyı sonuna kadar yürütür: giden kuyruğu gönderir, gelen her TLV mesajını motora verir.
    private func yurut(_ baglanti: NetworkConnection<TLV>, cihaz: WAPairedDevice.ID, ad: String, yon: String) async {
        let id = "wa\(yon)-\(cihaz)-\(UUID().uuidString.prefix(6))"
        let (akis, giden) = AsyncStream<Data>.makeStream(bufferingPolicy: .bufferingNewest(64))
        kilitli { baglar[id] = Bag(cihaz: cihaz, ad: String(ad.prefix(20)), giden: giden) }
        bildirBaglantilar()
        yeniBaglanti?(id)
        await withTaskGroup(of: Void.self) { grup in
            grup.addTask {
                for await veri in akis {
                    do { try await baglanti.send(veri, type: 1) } catch { return }
                }
            }
            grup.addTask { [weak self] in
                do {
                    for try await mesaj in baglanti.messages {
                        let veri = mesaj.content
                        guard veri.count <= Self.maksYuk else { continue }
                        self?.yukAlindi?(id, veri)
                    }
                } catch {
                    // Bağlantı koptu / iptal.
                }
            }
            await grup.next()
            grup.cancelAll()
        }
        kilitli {
            baglar[id]?.giden.finish()
            baglar[id] = nil
        }
        bildirBaglantilar()
    }

    private func bildirBaglantilar() {
        kilit.lock()
        var gorulen = Set<WAPairedDevice.ID>()
        var adlar: [String] = []
        for b in baglar.values where gorulen.insert(b.cihaz).inserted { adlar.append(b.ad) }
        kilit.unlock()
        baglantilarDegisti?(adlar)
        durumDegisti?()
    }

    // MARK: Eşleştirme ekranı

    @MainActor
    func eslesmeEkrani(rol: String, kapat: String, uzerinde vc: UIViewController) -> Bool {
        guard let yayin, let abone else { return false }
        let ic: UIViewController
        if rol == "gorunur" {
            let saglayici = WAPublisherListener.wifiAware(.connecting(to: yayin, from: .userSpecifiedDevices))
            guard DDDevicePairingViewController.isSupported(saglayici) else { return false }
            ic = DDDevicePairingViewController(listenerProvider: saglayici, access: .permanent)
        } else {
            let saglayici = WASubscriberBrowser.wifiAware(.connecting(to: .userSpecifiedDevices, from: abone))
            let tanim = saglayici.makeDescriptor()
            let parametre = saglayici.configureParameters(nil)
            guard DDDevicePickerViewController.isSupported(tanim, using: parametre),
                  let secici = DDDevicePickerViewController(browseDescriptor: tanim, parameters: parametre, access: .permanent) else { return false }
            ic = secici
            // Seçim + PIN tamamlanınca cihaz eşleşmiş listesine girer; ekran kapanır, arka plan taşıması ona bağlanır.
            Task { @MainActor [weak secici] in
                _ = try? await secici?.endpoint
                secici?.parent?.dismiss(animated: true)
            }
        }
        duraklat()
        let kap = WAEslesmeKabi(ic: ic, kapatYazisi: kapat) { [weak self] in self?.devamEt() }
        let nav = UINavigationController(rootViewController: kap)
        nav.modalPresentationStyle = .formSheet
        var ust = vc
        while let p = ust.presentedViewController { ust = p }
        ust.present(nav, animated: true)
        return true
    }

    private func duraklat() {
        kilit.lock()
        duraklatildi = true
        kilit.unlock()
        kes()
    }

    private func devamEt() {
        kilit.lock()
        duraklatildi = false
        let iste = istendi
        kilit.unlock()
        if iste { calistir() }
    }
}

/// Sistem eşleştirme ekranını taşıyan kap: "Kapat" düğmesi (VoiceOver'da adıyla) ve kapanınca taşımayı sürdürme.
@available(iOS 26.0, *)
private final class WAEslesmeKabi: UIViewController {
    private let ic: UIViewController
    private let kapatYazisi: String
    private let kapaninca: () -> Void
    private var bitti = false

    init(ic: UIViewController, kapatYazisi: String, kapaninca: @escaping () -> Void) {
        self.ic = ic
        self.kapatYazisi = kapatYazisi
        self.kapaninca = kapaninca
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { nil }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        let dugme = UIBarButtonItem(title: kapatYazisi.isEmpty ? "OK" : kapatYazisi, style: .done, target: self, action: #selector(kapat))
        dugme.accessibilityLabel = kapatYazisi
        navigationItem.rightBarButtonItem = dugme
        addChild(ic)
        ic.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(ic.view)
        NSLayoutConstraint.activate([
            ic.view.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            ic.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            ic.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            ic.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])
        ic.didMove(toParent: self)
    }

    @objc private func kapat() {
        dismiss(animated: true)
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        guard !bitti, isBeingDismissed || navigationController?.isBeingDismissed == true else { return }
        bitti = true
        kapaninca()
    }
}

#endif
