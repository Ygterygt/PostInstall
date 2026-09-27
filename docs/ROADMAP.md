# Computer Maintenance Pro — Kanban Yol Haritası

> Son güncelleme: 2026-09-27 · Sahip: @Ygterygt
> Bu dosya projenin tek Kanban panosudur. Kart taşımak = ilgili satırı sütunlar arasında taşımak.

## Kanban Kuralları

| Kural | Değer |
| :--- | :--- |
| Sütunlar | `Backlog → Ready → In Progress → Review/Test → Done` |
| WIP limiti | **In Progress ≤ 3**, **Review/Test ≤ 3** |
| Hizmet sınıfları | 🔴 **Expedite** (veri kaybı / kullanıcıyı kilitleyen hata) · 🟠 **Standard-P1** (doğruluk, güvenlik) · 🟢 **Standard-P2** (iyileştirme) · 🔵 **Intangible** (teknik borç, altyapı) |
| Ready tanımı (DoR) | Sorun + etkilenen dosya + kabul kriteri yazılı |
| Done tanımı (DoD) | AST parse temiz · `Test-PostInstallSuite.ps1` %100 PASS · davranış elle doğrulandı · pano güncellendi |
| Çekme sırası | Önce Expedite, sonra P1, sonra P2; aynı sınıfta en küçük kart önce |

---

## 1. Mevcut Mimari (inceleme özeti)

```
PostInstall.exe (Program.cs, UAC yükseltme)
  └─ PostInstallUI.ps1  (WinForms, 5 sekme: İzleme · Bakım · Sihirbaz · GPU · Konsol)
       ├─ PostInstallEngine.ps1 (state machine, RunOnce ile reboot sonrası devam)
       │    └─ steps.json → Modules\00..12_*.ps1 (her biri ayrı powershell.exe süreci)
       └─ Tools\*.ps1  (Package/Maintenance/HardwareMonitor/Snapshot/Driver/Reporting/SilentDetector/SpecsCollector)
config.json · gpu_compatibility.json · Installers\ (çevrimdışı paketler)
```

Güçlü yanlar: adım bazlı state machine + atomik state yazımı, 3 katmanlı paket kurulumu (WinGet → CDN → yerel), sessiz parametre tespiti, VSS geri yükleme noktası, UI'da runspace tabanlı asenkron iş.

## 2. İlham Alınacak GitHub Repoları

| Repo | ★ | Neyi alıyoruz |
| :--- | ---: | :--- |
| [ChrisTitusTech/winutil](https://github.com/ChrisTitusTech/winutil) | 63k | Deklaratif `applications.json` (winget/choco id, kategori) → paket kataloğu; tweak'lerin **undo** karşılıkları |
| [Raphire/Win11Debloat](https://github.com/Raphire/Win11Debloat) | 58k | Tweak başına geri alınabilir `.reg` dosyaları, sade CLI parametreleri |
| [microsoft/winget-cli](https://github.com/microsoft/winget-cli) | 26k | Resmi çıkış kodları (`0x8A15002B`, `0x8A150061`, `0x8A150109`…), `--disable-interactivity` |
| [marticliment/UniGetUI](https://github.com/marticliment/UniGetUI) | 26k | Güncellenebilir paket listesi + toplu güncelleme UX'i |
| [farag2/Sophia-Script-for-Windows](https://github.com/farag2/Sophia-Script-for-Windows) | 10k | Her fonksiyonun `-Enable/-Disable` çifti, alan adına katılmış makinede güvenli davranış |
| [LibreHardwareMonitor/LibreHardwareMonitor](https://github.com/LibreHardwareMonitor/LibreHardwareMonitor) | 9k | `LibreHardwareMonitorLib.dll` ile gerçek CPU sıcaklığı/saat/fan (ACPI termal bölge yerine) |
| [HotCakeX/Harden-Windows-Security](https://github.com/HotCakeX/Harden-Windows-Security) | 5k | ASR kuralları, denetim (audit) modunda güvenlik tabanı |
| [pester/Pester](https://github.com/pester/Pester) · [PowerShell/PSScriptAnalyzer](https://github.com/PowerShell/PSScriptAnalyzer) | 3k · 2k | Birim test + statik analiz, CI kapısı |
| [PSAppDeployToolkit/PSAppDeployToolkit](https://github.com/PSAppDeployToolkit/PSAppDeployToolkit) | 2k | Kurulum yürütme, MSI kilit (1618) bekleme, süreç ağacı yönetimi |
| [Romanitho/Winget-AutoUpdate](https://github.com/Romanitho/Winget-AutoUpdate) | 2k | Zamanlanmış görevle günlük uygulama güncellemesi, allow/block listesi |
| [chocolatey/boxstarter](https://github.com/chocolatey/boxstarter) | 1k | Reboot-dayanıklı kurulum desenleri (tek kayıtlı devam girdisi, çift çalışmayı önleme) |
| [aaronparker/evergreen](https://github.com/aaronparker/evergreen) | 0.4k | Sabitlenmiş sürüm URL'leri yerine her zaman güncel resmi indirme adresi |
| [mgajda83/PSWindowsUpdate](https://github.com/mgajda83/PSWindowsUpdate) | 0.5k | Windows Update'i yalnızca taramak değil, kurmak |
| [Klocman/Bulk-Crap-Uninstaller](https://github.com/Klocman/Bulk-Crap-Uninstaller) | 22k | Kurulu uygulama tespiti (Uninstall + AppX + winget birleşik görünüm) |

## 3. Kanban Panosu

### 🔴 Expedite / 🟠 P1 — Hatalar (Sprint 1)

| ID | Sınıf | Kart | Etkilenen | Kabul kriteri | Durum |
| :--- | :---: | :--- | :--- | :--- | :---: |
| CMP-01 | 🔴 | Tamamlanmış/eskimiş state yeniden kullanılıyor → ikinci çalıştırma hiçbir şey yapmıyor; reboot sonrası adım seçimi kayboluyor | Engine, UI | Resume dışında her çalıştırma temiz oturum; seçim state'te saklanır; atlanan adım `Skipped` | ✅ Done |
| CMP-02 | 🔴 | UI `FAILED`/`REBOOT_TRIGGERED` durumlarını işlemiyor → sihirbaz sonsuza dek kilitli, GUI'de reboot hiç tetiklenmiyor | UI | Her sonuç için özet sayfası; `AutoReboot`/`RebootCountdownSeconds` uygulanır | ✅ Done |
| CMP-03 | 🔴 | RunOnce hem HKCU hem HKLM'ye yazılıyor → reboot sonrası iki kopya aynı anda çalışıyor | Engine, UI | Tek RunOnce girdisi + UI tek örnek (mutex) | ✅ Done |
| CMP-04 | 🔴 | Modül 03 `C:\Windows\Temp`'i silerken motorun log/state dosyalarını siliyor; geri dönüşüm kutusunu onaysız boşaltıyor; olay günlüklerini yedeksiz siliyor; `config.Maintenance` hiç okunmuyor | 03, MaintenanceEngine, config | Çalışma dosyaları `%ProgramData%\ComputerMaintenancePro`; yaş eşiği + dışlama; geri dönüşüm opsiyonel; olay günlüğü `.evtx` arşivlenerek temizlenir | ✅ Done |
| CMP-05 | 🔴 | GPU kartı butonları döngü değişkenini paylaşıyor → her buton son GPU'nun yazılımını kuruyor | UI | Her kart kendi profilini kurar | ✅ Done |
| CMP-06 | 🟠 | Sihirbaz sayfa 3'teki yükleyici seçimi modüle hiç iletilmiyor | UI, 10 | Seçimi kaldırılan yükleyici çalışmaz | ✅ Done |
| CMP-07 | 🟠 | RAM hızı ×2 hesaplanıyor (DDR5-4800 → "9600 MHz"), XMP uyarısı hiç çıkmıyor | 05, 08, SpecsCollector | Ortak normalizasyon fonksiyonu, doğru MT/s | ✅ Done |
| CMP-08 | 🟠 | Machine PATH genişletilmiş okunup `REG_SZ` yazılıyor → `%SystemRoot%` referansları kalıcı bozuluyor | 07 | Ham değer okunur, `REG_EXPAND_SZ` korunur | ✅ Done |
| CMP-09 | 🟠 | DNS koşulsuz Cloudflare'e çevriliyor → alan adına katılmış makinede AD çözümlemesi bozulur, statik DNS ezilir | 11, config | Domain'de atla, statik DNS'e dokunma, önceki değeri yedekle, config'den yönet | ✅ Done |
| CMP-10 | 🟠 | Bakım butonları: scriptblock runspace'ler arası taşınıyor (oturum affinity), tüm çıktı `[void]` ile yutuluyor, runspace sızıntısı | UI | Çıktı canlı log'a akar, runspace'ler temizlenir | ✅ Done |
| CMP-11 | 🟠 | Canlı izleme her 2 sn'de yeni runspace + yeni PerformanceCounter açıyor → CPU % anlamsız, CIM sorguları tekrar | UI, HardwareMonitorEngine | Kalıcı örnekleyici runspace, gerçek CPU %, anlık saat hızı | ✅ Done |

### 🟠 P1 / 🔵 Altyapı (Sprint 2)

| ID | Sınıf | Kart | Kabul kriteri | Durum |
| :--- | :---: | :--- | :--- | :---: |
| CMP-12 | 🟠 | `C:\PostInstall` her yere sabit kodlu → klasör USB/D:'ye taşınınca kırılıyor | Tüm yollar suite köküne göre (`Tools\Common.ps1`) | ✅ Done |
| CMP-13 | 🟠 | PackageEngine: yanlış winget çıkış kodları, "Git" ↔ "GitHub Desktop" yanlış pozitifi, CDN indirmesi imza doğrulamasız çalıştırılıyor | Resmi kodlar, kelime-sınırlı eşleşme, winget ile tespit, Authenticode zorunlu | ✅ Done |
| CMP-14 | 🟠 | Motor: modül çıktısı adım bitince toplu geliyor, `AllowRebootIfTriggered`/`MaxRetriesPerStep`/adım zaman aşımı yok sayılıyor, zaman aşımında alt süreçler öksüz kalıyor, Türkçe karakter bozuluyor | Canlı akış (UTF-8), ertelenmiş reboot, retry, süreç ağacı sonlandırma | ✅ Done |
| CMP-15 | 🟢 | Dizüstünde de Yüksek Performans planı aktif ediliyor (pil) | Laptop → Dengeli, masaüstü → Yüksek Perf (varsa) | ✅ Done |
| CMP-16 | 🔵 | Test bataryası gerçek sistemde temp siliyor, sabit yol kullanıyor, çıkış kodu vermiyor; `TestResults.json`/`Backups` git'te; exe için build script yok | Sandbox testler, birim testler, `.gitignore`, `Tools\Build-Launcher.ps1` | ✅ Done |
| CMP-17 | 🔵 | CI yok | GitHub Actions: PSScriptAnalyzer + test bataryası (windows-latest) | ✅ Done |

### 🐞 Çalışma sırasında keşfedilen kartlar (Sprint 1–2)

| ID | Sınıf | Kart | Kabul kriteri | Durum |
| :--- | :---: | :--- | :--- | :---: |
| CMP-18 | 🟠 | İzleme ve GPU sekmesinde Fill paneli Top çubuğunun altında kalıyor → üst sıra kart başlıkları görünmüyor | Dock z-order düzeltildi, ekran görüntüsüyle doğrulandı | ✅ Done |
| CMP-19 | 🔴 | Motorun `param([switch]$Resume)` bloğu dot-source edilince UI'ın `$Resume`'unu `$false` yapıyor → reboot sonrası GUI kuruluma **hiç** otomatik devam etmiyordu | CLI parametreleri alias ile yeniden adlandırıldı (`-Resume` CLI'da aynen çalışır) + regresyon testi | ✅ Done |
| CMP-21a | 🔴 | Uygulama kapatılırken "Bağımsız değişken türleri eşleşmiyor" hata diyaloğu (PS 5.1'de `@()` + `List[object]` binder hatası, FormClosing) | `.ToArray()` + kapanış adımları izole `try` + regresyon testi; kapanış diyalogsuz doğrulandı | ✅ Done |
| CMP-22a | 🟠 | GPU veritabanındaki 7 winget kimliğinden 6'sı mevcut değildi (`0x8A150014`); doğrudan URL'lerin çoğu 404/403 ya da HTML sayfasıydı | Kimlikler `winget show` ile doğrulandı, kaynak (winget/msstore) alanı eklendi, AppX tespiti, sabit sürüm URL'leri yerine `ManualDownloadPage`, şema + eşleşme testleri | ✅ Done |
| CMP-33 | 🟢 | GPU kartlarındaki 'Sürücüyü Yedekle' (119 paket / ~7 GB tek klasöre, geçmişsiz) kaldırıldı; sürücü güncellemeleri `Installers\` üzerinden resmi paketlerle (NVIDIA `-s -noreboot`, AMD `-install`) | Kullanıcı kararı; eski sürüme dönüş için Aygıt Yöneticisi 'Sürücüyü Geri Al' | ✅ Done |
| CMP-34 | 🔵 | Uçtan uca test için izole ortam yoktu | `dev\New-TestVM.ps1` (Gen2, Secure Boot, vTPM, Guest Services) + `dev\Copy-SuiteToVM.ps1`; Hyper-V entegrasyon hizmeti adları yerelleştirildiği için kimlikle (GUID) bulunur; VM kuruldu, "Temiz Windows" denetim noktası alındı | ✅ Done |
| CMP-35 | 🟠 | Tam sihirbaz (yönetici, tüm modüller, gerçek reboot/resume, NVIDIA/AMD sessiz kurulum, zamanlanmış görev, geri alma) gerçek sistemde doğrulanmadı | VM'de uçtan uca koşu, loglar incelendi, bulunan hatalar kartlandı | ⏸️ Blocked (host RAM yetersiz; VM hazır, paket kopyalandı) |
| CMP-20a | 🟠 | PS 5.1'de `ConvertFrom-Json` diziyi tek nesne yayar; `$PSScriptRoot` betik `param()` varsayılanlarında boştur | İki tuzak da testlerle kilitlendi | ✅ Done |

### 🟢 Backlog — Özellikler (Sprint 3+)

| ID | Kart | İlham |
| :--- | :--- | :--- |
| CMP-20 | Paket listesini `packages.json` kataloğuna taşı, sihirbazda uygulama bazlı seçim | winutil |
| CMP-21 | Sabit sürümlü CDN URL'leri yerine Evergreen ile güncel URL | evergreen |
| CMP-22 | LibreHardwareMonitorLib ile gerçek sensörler (CPU paket sıcaklığı, fan, güç) | LibreHardwareMonitor |
| CMP-23 | ✅ **Done (Sprint 3)** — Bakım sekmesinde "Zamanlanmış Bakım" paneli: haftalık Görev Zamanlayıcı görevi (kullanıcı adına, en yüksek yetki), Temp/DNS/TRIM/uygulama güncellemeleri, pildeyken çalışmaz, kaçırılırsa ilk fırsatta çalışır, sihirbaz çalışırken atlanır | Winget-AutoUpdate |
| CMP-24 | Windows Update kurulumu (yalnız tarama değil) + sürücü güncellemeleri | PSWindowsUpdate |
| CMP-25 | ✅ **Done (Sprint 3)** — Değişiklik günlüğü (`State\ChangeJournal.json`): modül 01/11/12'nin registry, servis, güç, TRIM, TCP, DNS ve Defender değişiklikleri önceki değerleriyle kaydedilir; Bakım sekmesinden tek tek/toplu geri alınır. UAC ve SMBv1 güvenlik gereği geri alınmaz | Win11Debloat, Sophia |
| CMP-26 | ASR kuralları (audit modu), Defender PUA koruması | Harden-Windows-Security |
| CMP-27 | Telemetri geçmişi (CSV) + raporda trend grafikleri, sağlık skoru | UniGetUI / LHM |
| CMP-28 | ✅ **Done (Sprint 3)** — Güncellemeler sekmesi: `winget upgrade` tablosu sütun konumuna göre ayrıştırılır (dil bağımsız), seçili uygulamalar sırayla güncellenir, `config.Updates.ExcludeIds` ile hariç tutma | UniGetUI |
| CMP-29 | `PostInstallUI.ps1` (1700 satır) sekme başına dosyalara bölünsün | — |
| CMP-30 | TR/EN yerelleştirme kaynak dosyası | Sophia |
| CMP-31 | ⬆️ **Öncelik yükseldi (dağıtım)** — Betik ve exe için kod imzalama (imzasız exe SmartScreen/antivirüs uyarısına takılır) | PSADT |
| CMP-36 | ✅ **Done (Sprint 4)** — Sürüm paketi: `config.json`'dan sürüm (exe'ye de işlenir), `CHANGELOG.md`, `v*` etiketiyle tetiklenen `release.yml` (test → zip + SHA256 → GitHub Release, notlar CHANGELOG'dan), izin listesiyle paketleme (`Tools\New-ReleasePackage.ps1`), son kullanıcı kılavuzu `KULLANIM.md`; rapor artık masaüstüne kopyalanmıyor | — |

## 4. Sprint 1–2 Teslim Özeti (2026-09-27)

- 20 kart **Done** (CMP-17: CI GitHub'da yeşil; ilk koşular PSScriptAnalyzer'ın bir yanlış alarmı yüzünden düşüyordu, düzeltildi).
- Test bataryası: **47/47 PASS** (Windows PowerShell 5.1). Yeni kapsam: birim testleri, temp temizliği sandbox'ı, motorun uçtan uca testi (retry, atlama, ertelenmiş reboot, watchdog, UTF-8, resume, dot-source regresyonu).
- Davranış değişiklikleri (config ile geri alınabilir): log/state `%ProgramData%\ComputerMaintenancePro`'ya taşındı · Geri Dönüşüm Kutusu varsayılan olarak boşaltılmaz · `DismResetBase` varsayılanı `false` · `MaxRetriesPerStep` 1 · dizüstünde Dengeli güç planı · DNS yalnızca DHCP adaptörlerinde ve domain dışı makinelerde değişir.

## 5. Akış Metrikleri (takip)

| Metrik | Hedef |
| :--- | :--- |
| Lead time (Ready → Done) | Expedite < 1 gün, P1 < 3 gün |
| WIP ihlali | 0 |
| Test başarı oranı | %100 (CI kapısı) |
