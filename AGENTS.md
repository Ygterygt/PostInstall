# AGENTS.md — Computer Maintenance Pro

> Bu dosya, projeyi inceleyecek yapay zekâ asistanları (Claude, Codex, Copilot, Cursor…) ve geliştiriciler için
> **hızlı bağlam** sağlar. Kodu değiştirmeden önce buradaki "Tuzaklar" ve "Kurallar" bölümlerini okuyun.
> Yol haritası ve açık işler: [docs/ROADMAP.md](docs/ROADMAP.md) (Kanban panosu).

## 1. Proje ne yapar?

Windows 10/11 için **kurulum sonrası (post-install) hazırlık + sistem bakımı + donanım izleme** aracı.
Tek bir WinForms arayüzünden:

- **Canlı İzleme:** CPU/GPU/RAM/disk/pil telemetrisi (2 sn'de bir)
- **Sistem Bakımı:** temp temizliği, Windows Update önbelleği, DISM, ağ sıfırlama, TRIM, pil raporu; haftalık **zamanlanmış bakım** (Görev Zamanlayıcı)
- **Kurulum Sihirbazı:** `steps.json`'daki 13 modülü sırayla çalıştırır; yeniden başlatmaya dayanıklıdır
- **GPU & Sürücüler:** GPU'ya göre üretici yardımcı yazılımını önerir/kurar (sürücü yedekleme yok; sürücü güncellemeleri `Installers\` ile yapılır)
- **Güncellemeler:** `winget upgrade` ile güncellemesi olan uygulamaları listeler, seçilenleri sırayla günceller
- **Konsol & Loglar:** tüm olayların birleşik günlüğü

Hedef ortam: **Windows PowerShell 5.1** (Windows'la gelen). PowerShell 7 hedef değildir ama kod orada da çalışmalıdır.

## 2. Mimari

```
PostInstall.exe (Program.cs)        UAC ile yükseltir, konsolsuz powershell.exe başlatır
  └─ PostInstallUI.ps1               WinForms arayüzü (6 sekme), tek örnek (mutex), -StartTab ile sekme seçilebilir
       ├─ PostInstallEngine.ps1      State machine: adımlar, retry, zaman aşımı, RunOnce ile reboot sonrası devam
       │    └─ steps.json → Modules\NN_*.ps1   Her modül AYRI bir powershell.exe sürecinde çalışır
       └─ Tools\*.ps1                Dot-source edilen yardımcı kütüphaneler
```

- **Motor ↔ modül sözleşmesi:** Modül stdout'a `[INFO]/[SUCCESS]/[WARN]/[ERROR]/[NOTE]/[SKIP]` önekli satırlar yazar
  (motor bunlardan log seviyesi çıkarır, UTF-8 olarak canlı akıtır) ve çıkış koduyla sonucu bildirir:
  `0`/`1638` başarı · `3010`/`1641` reboot gerekli · `1460` zaman aşımı (motor üretir) · diğerleri hata.
- **Reboot akışı:** Modül `3010` döner → adımın `AllowRebootIfTriggered` değeri `true` ise motor state'i kaydeder,
  **tek** RunOnce girdisi (HKLM, olmazsa HKCU) yazar ve `REBOOT` döner; `false` ise reboot kurulum sonuna ertelenir.
  Reboot sonrası `PostInstall.exe -Resume` → UI `-Resume` → `Start-PostInstallProcess -Resume` kaldığı adımdan devam eder.
- **UI ↔ arka plan:** Uzun işler runspace'lerde çalışır, UI'a yalnızca `ConcurrentQueue` üzerinden mesaj gelir;
  100 ms'lik `uiTimer` kuyrukları boşaltır. Telemetri için **tek, kalıcı** bir örnekleyici runspace vardır.

## 3. Dosya haritası

| Dosya | Görev |
| :--- | :--- |
| `PostInstallUI.ps1` | Arayüz (~2000 satır). Bölgeler: Startup Trace, Single Instance Guard, Tab 1–6, Timers, Form Lifecycle |
| `PostInstallEngine.ps1` | `Start-PostInstallProcess`, `Invoke-EngineStep`, `Invoke-StepProcess`, state ve RunOnce |
| `steps.json` | Adım listesi: `Id, Order, Title, Description, Script, Critical, AllowRebootIfTriggered, RequiresReboot, TimeoutSeconds?, Retryable?` |
| `config.json` | Yollar, reboot, retry, `Maintenance.*`, `Network.*`, `Updates.ExcludeIds` ayarları |
| `gpu_compatibility.json` | GPU → yardımcı yazılım eşlemesi (`WinGetId` + `WinGetSource`, `AppxName`, `ManualDownloadPage`, `Note`) |
| `Modules\00…12_*.ps1` | Kurulum adımları (sıra `steps.json`'daki `Order`'a göredir; `08_PostInstallAudit` en sondadır) |
| `Tools\ChangeJournal.ps1` | Ayar değişikliği günlüğü: `Set-TrackedRegistryValue`, `Set-TrackedServiceStartType`, `Set-TrackedPowerPlan/PowerTimeout`, `Set-TrackedTrim`, `Set-TrackedTcpGlobal`, `Set-TrackedDnsServers`, `Set-TrackedMpPreference`; `Undo-ChangeJournal` (en yeniden eskiye) |
| `Tools\Common.ps1` | Ortak: `Get-SuiteRoot`, `Get-SuiteConfig`, `Get-SuiteDataDir`, RAM hız normalizasyonu, REG_EXPAND_SZ-güvenli PATH |
| `Tools\PackageEngine.ps1` | `Install-ResilientPackage` (WinGet → imzalı CDN → yerel önbellek), GPU yardımcıları (`Find-GpuProfile`, `Install-GpuCompanionApp`) |
| `Tools\MaintenanceEngine.ps1` | Temizlik/DISM/ağ/TRIM/pil fonksiyonları |
| `Tools\UpdateEngine.ps1` | `Get-AvailableAppUpdates`, `Update-AppPackage`, `ConvertFrom-WingetTable` (winget tablosunu **sütun konumuna göre** ayrıştırır; başlıklar yerelleştirilmiş olabilir) |
| `Tools\SchedulerEngine.ps1` | Zamanlanmış bakım ayarları (varsayılan `config.ScheduledMaintenance` ← kullanıcı seçimi `State\ScheduledMaintenance.json`), görev kaydı/durumu (`\ComputerMaintenancePro\` klasörü) |
| `Tools\Invoke-ScheduledMaintenance.ps1` | Görevin çalıştırdığı betik; `-DryRun` yalnızca planı yazar. Log: `Logs\ScheduledMaintenance.log`, özet: `Reports\LastScheduledMaintenance.json` |
| `Tools\HardwareMonitorEngine.ps1` | Telemetri örneği (`Get-LiveTelemetrySample`) |
| `Tools\SilentDetector.ps1` | Yükleyici türü + sessiz parametre tespiti, "zaten kurulu mu" kontrolü |
| `Tools\SnapshotEngine.ps1`, `DriverEngine.ps1`, `ReportingEngine.ps1`, `SystemSpecsCollector.ps1` | Geri yükleme noktası, `Drivers\` klasöründen çevrimdışı INF enjeksiyonu (modül 05), HTML rapor, donanım profili |
| `Tools\Build-Launcher.ps1` | `Program.cs` → `PostInstall.exe` (Windows'taki `csc.exe` ile; sürüm `config.json`'dan exe'ye işlenir) |
| `Tools\New-ReleasePackage.ps1` | Son kullanıcı zip'i + SHA256 (`dist\`). **İzin listesiyle** çalışır: pakete girecek yeni dosya/klasör buraya eklenmelidir |
| `CHANGELOG.md`, `docs\KULLANIM.md` | Sürüm notları (release notları buradan alınır) ve pakete giren son kullanıcı kılavuzu |
| `Tools\Enforce-Encoding.ps1` | Tüm `.ps1/.json` dosyalarını UTF-8 **BOM'lu** yapar |
| `Test-PostInstallSuite.ps1` | Test bataryası (aşağıya bakın) |
| `dev\New-TestVM.ps1`, `dev\Copy-SuiteToVM.ps1` | Geliştirici araçları (pakete girmez): Windows 11 uyumlu Hyper-V test VM'i oluşturur, paketi VM'e kopyalar |
| `Installers\` | Çevrimdışı kurulum dosyaları (git'e girmez). Modül 10 hepsini sessiz kurar; aynı/yeni sürüm kuruluysa atlar, **eski kuruluysa günceller**. GPU sürücü güncellemeleri de buradan yapılır (NVIDIA: `-s -noreboot`, AMD Adrenalin: `-install`) |

## 4. Çalışma zamanı dosyaları

Hepsi `%ProgramData%\ComputerMaintenancePro\` altındadır (repo içinde **değil**):

| Yol | İçerik |
| :--- | :--- |
| `Logs\PostInstall.log`, `PostInstall_Error.log` | Motor günlükleri |
| `Logs\UI_Startup.log` | Arayüz açılış adımları — **UI açılmıyorsa ilk bakılacak yer** |
| `State\PostInstall_State.json` | Motor state'i (oturum, adım sonuçları, seçili adımlar) |
| `State\OfflineSelection.json` | Sihirbaz sayfa 3'te seçilen yükleyiciler (modül 10 okur) |
| `State\UI.pid` | Tek örnek kilidini tutan UI sürecinin PID'i |
| `State\ChangeJournal.json` | Modüllerin değiştirdiği ayarlar + önceki değerleri (geri alma için; testlerde `$env:CMP_CHANGE_JOURNAL` ile yönlendirilir) |
| `State\ScheduledMaintenance.json` | Zamanlanmış bakım için kullanıcı seçimleri (repo'daki `config.json` değiştirilmez) |
| `Backups\`, `Reports\`, `EventLogArchive\` | Registry/ortam/DNS/sürücü yedekleri, raporlar, arşivlenen olay günlükleri |

## 5. Test ve doğrulama

```powershell
# Tüm testler (Windows PowerShell 5.1 ile çalıştırın; çıkış kodu = başarısız test sayısı)
powershell -NoProfile -ExecutionPolicy Bypass -File .\Test-PostInstallSuite.ps1

# Dosyaları düzenledikten sonra kodlamayı normalize edin
powershell -NoProfile -ExecutionPolicy Bypass -File .\Tools\Enforce-Encoding.ps1

# Launcher'ı derleme
powershell -NoProfile -ExecutionPolicy Bypass -File .\Tools\Build-Launcher.ps1
```

- Test bataryası **sistemi değiştirmez**: yazan/silen her test `%TEMP%` altında sandbox kullanır.
  Motorun uçtan uca testi sahte modüllerle retry, atlama, ertelenmiş reboot, zaman aşımı, UTF-8 ve resume'u doğrular.
- CI: `.github/workflows/ci.yml` (windows-latest) — PSScriptAnalyzer (`PSScriptAnalyzerSettings.psd1`) + test bataryası.
- **Sürüm çıkarma:** `config.json` → `Version`'ı artırın, `CHANGELOG.md`'ye aynı sürümün bölümünü ekleyin (test bunu denetler),
  main'e birleştirin, sonra `git tag v4.2.0 && git push origin v4.2.0`. `release.yml` testleri çalıştırır, zip'i üretir ve
  GitHub Release yayınlar. Etiket config sürümüyle uyuşmazsa paketleme durur; `v4.2.0-beta.1` gibi etiketler ön sürüm olur.
- **Modülleri gerçek sistemde çalıştırmak sistem değişikliği yapar** (kurulum, registry, DNS…). Salt okunur olanlar:
  `02_StorageAndDisks` (TRIM hariç), `05_HardwareAndDrivers` (Drivers klasörü yoksa), `08_PostInstallAudit` (rapor yazar).
- UI değişikliklerinde: arayüzü açıp kapatın, `UI_Startup.log`'da "Pencere gosterildi" satırını ve kapanışta hata
  diyaloğu çıkmadığını doğrulayın.

## 6. Kurallar

- **Yollar:** Asla `C:\PostInstall` sabit yazmayın. Modüllerde:
  `. (Join-Path (Split-Path -Parent $PSScriptRoot) "Tools\Common.ps1")` → `Get-SuiteRoot`, `Get-SuiteConfig`, `Get-SuiteDataDir`.
  (Test bataryası bunu denetler.)
- **Kodlama:** `.ps1/.json` dosyaları UTF-8 **BOM'lu**, satır sonları LF (`.bat` CRLF, bkz. `.gitattributes`).
  BOM yoksa PS 5.1 Türkçe karakterleri bozar.
- **Modül çıktısı:** `Write-Output "[SEVIYE] mesaj"`. Kütüphane fonksiyonları dönüş değeri döndürüyorsa mesajları
  `Write-Host` ile yazar (bkz. `Write-PackageLog`), yoksa `| Out-Null` mesajları da yutar.
- **Yeni adım:** `Modules\NN_Ad.ps1` + `steps.json` girdisi (Order kesintisiz 1..N olmalı) + gerekiyorsa `TimeoutSeconds`.
- **Yeni GPU profili / paket kimliği:** Kimliği `winget show --id <ID> --exact --source <winget|msstore>` ile doğrulayın;
  `WinGetSource` zorunlu. Store uygulamasının **sürücüyle uyumlu ve güncel** olduğunu da kontrol edin (bkz. Tuzak 8).
  Sabit sürüm içeren doğrudan indirme URL'si eklemeyin; üretici sayfası `ManualDownloadPage`'e yazılır.
- **Ayar değiştiren kod** değeri doğrudan yazmaz; `Tools\ChangeJournal.ps1`'deki `Set-Tracked*` fonksiyonlarını kullanır (önceki değer kaydedilir, arayüzden geri alınabilir). Güvenliği düşürecek geri almalar `-NotUndoable` ile işaretlenir.
- **İndirilen kurulum dosyaları** geçerli Authenticode imzası olmadan çalıştırılmaz.
- **Varsayılan olarak yıkıcı olmayın:** Geri Dönüşüm Kutusu, olay günlükleri, DNS, ResetBase gibi işlemler `config.json`
  ile açılır/kapanır ve yedeklenir.
- Commit mesajları İngilizce, Conventional Commits (`fix(ui): ...`). UI metinleri ve log mesajları Türkçe.

## 7. Tuzaklar (bu projede gerçekten yaşandı)

1. **Dot-source parametre ezmesi:** Bir `param()` bloğu olan betik dot-source edilince parametreleri **çağıranın**
   kapsamına yazılır. Motorun `$Resume`'u UI'ın `-Resume`'unu `$false` yapıyordu (reboot sonrası hiç devam etmiyordu).
   Motor parametreleri bu yüzden `$CliResume/$CliReset/$CliHeadless` adındadır (`-Resume` alias'ı korunur).
2. **`ConvertFrom-Json` (PS 5.1):** JSON dizisini **tek nesne** olarak yayar; `@(... | ConvertFrom-Json)` 1 elemanlı
   iç içe dizi üretir. Önce değişkene atayın, sonra `@($x)`.
3. **`$PSScriptRoot` betik `param()` varsayılanlarında boştur (PS 5.1).** Gövdede çözün. Fonksiyon parametre
   varsayılanlarında sorun yoktur.
4. **`@($list)` + `List[object]` (PS 5.1):** "Bağımsız değişken türleri eşleşmiyor" fırlatır. `.ToArray()` kullanın.
5. **WinForms olay işleyicileri closure değildir:** Döngü değişkenini handler içinde okumak son değeri verir.
   Karta özel veriyi `$button.Tag`'e koyup `$this.Tag` ile okuyun.
6. **Scriptblock runspace affinity:** Bir `[scriptblock]` nesnesini başka runspace'e argüman olarak geçip çağırmayın;
   metin olarak (`.ToString()`) geçip `[scriptblock]::Create()` ile yeniden oluşturun.
7. **Dock z-order:** `Dock=Fill` kontrol, `Dock=Top` kontrolden sonra eklenirse onun altında kalır;
   Fill kontrolüne `.BringToFront()` çağırın.
8. **AMD Store uygulaması:** Microsoft Store'daki "AMD Radeon Software" (`9NZ1BJQN6BHL`) eski ve güncel sürücülerle
   PA-300 hatası verir. Adrenalin yalnızca AMD sürücü paketiyle gelir; otomatik kurulmaz.
9. **`Get-AppxPackage`** açılış yolunda (STA, mesaj döngüsü başlamadan) kullanılmaz; AppX tespiti registry'den yapılır
   (`Get-AppxPackageFromRegistry`).
10. **Performans sayaçları** oran tabanlıdır: ilk `NextValue()` hep 0 döner; sayaçlar örnekler arasında yaşamalıdır.
11. **`Win32_PhysicalMemory.ConfiguredClockSpeed`** modern sistemlerde zaten MT/s'dir; ×2 yapmayın
    (`ConvertTo-MemorySpeedInfo`).
12. **Machine PATH** `[Environment]::GetEnvironmentVariable` ile okunursa `%SystemRoot%` genişler; ham okuyun/yazın
    (`Get-RawPathValue` / `Set-RawPathValue`, `REG_EXPAND_SZ`).
13. **PowerShell `-eq` tip dönüşümü:** `$true -eq "REBOOT"` → `True`. Adım sonuçları string'dir
    (`SUCCESS/WARNING/FAILED/REBOOT`); bool ile karıştırmayın.
14. **.NET regex yerine koymada `$_`** "tüm girdi" demektir; `-replace` ile PowerShell kodu üretirken dikkat edin.
15. **Otomatik değişkenler:** `$args`, `$matches`, `$profile`, `$input` gibi adlara atama yapmayın
    (PSScriptAnalyzer da uyarır; CI analiz adımında `Error` seviyesi build'i düşürür).
16. **`winget upgrade`'in JSON çıktısı yok;** tablo metni ayrıştırılır. Başlık metnine göre değil,
    sütun **konumlarına** göre çalışın (başlıklar Türkçe/İngilizce olabilir).

## 8. Bilinen sınırlamalar

- Chrome/Opera/ChatGPT/Claude gibi web-yükleyicileri "Generic Executable" olarak tahmini `/silent /quiet` ile çalışır;
  pencere açabilirler.
- NVIDIA sessiz kurulum parametresi (`-s -noreboot`) gerçek kurulumla henüz doğrulanmadı.
- Tam sihirbaz akışı (yönetici, tüm modüller, gerçek reboot) otomatik test edilmiyor; yalnızca motor sandbox'ta test ediliyor.
- GPU profil sırası: "NVIDIA RTX A4000" gibi profesyonel kartlar önce "Modern GeForce" desenine (`RTX`) takılabilir.
- `PostInstallUI.ps1` tek büyük dosya (bölünmesi ROADMAP'te CMP-29).
