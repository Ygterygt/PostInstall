# Computer Maintenance Pro — Kullanım Kılavuzu

Windows 10 / 11 için kurulum sonrası hazırlık, sistem bakımı ve donanım izleme aracı.

## Kurulum

1. İndirdiğiniz `ComputerMaintenancePro-vX.Y.Z.zip` dosyasına **sağ tıklayın → Özellikler**.
   En altta **"Engellemeyi kaldır"** kutusu varsa işaretleyip **Tamam** deyin.
   (Bunu yapmazsanız Windows her dosya için "internetten indirildi" uyarısı verebilir.)
2. Zip'i istediğiniz bir yere çıkarın (ör. `C:\ComputerMaintenancePro` ya da bir USB bellek).
3. Klasördeki **`PostInstall.exe`**'ye çift tıklayın ve yönetici izni sorusuna **Evet** deyin.

> **"Windows bilgisayarınızı korudu" uyarısı çıkarsa:** **Ek bilgi → Yine de çalıştır**'a tıklayın.
> Program henüz dijital olarak imzalı olmadığı için bu uyarı görünebilir.

Kurulum gerekmez; program klasörden çalışır. Kaldırmak için klasörü silmeniz yeterlidir
(kayıtlar: `C:\ProgramData\ComputerMaintenancePro`).

## Sekmeler

| Sekme | Ne yapar? |
| :--- | :--- |
| **Canlı İzleme** | İşlemci, ekran kartı, bellek, disk ve pil durumunu 2 saniyede bir gösterir. |
| **Sistem Bakımı** | Geçici dosya temizliği, Windows Update önbelleği, sistem dosyası onarımı (DISM), ağ sıfırlama, SSD TRIM, pil raporu. Haftalık **zamanlanmış bakım** ve yapılan ayar değişikliklerini **geri alma** da buradadır. |
| **Kurulum Sihirbazı** | Yeni kurulmuş bir Windows'u adım adım hazırlar: temel ayarlar, çalışma zamanları, sürücüler, uygulamalar, ağ ve güvenlik. Gerekirse bilgisayarı yeniden başlatır ve **kendiliğinden kaldığı yerden devam eder**. |
| **GPU & Sürücüler** | Ekran kartınıza uygun üretici yazılımını (NVIDIA App vb.) önerir ve kurar. |
| **Güncellemeler** | Güncellemesi olan uygulamaları listeler; seçtiklerinizi günceller. |
| **Konsol & Loglar** | Yapılan her işlemin kaydı. |

## Kendi yükleyicilerinizi eklemek

`Installers` klasörüne `.exe`, `.msi` veya `.msix` kurulum dosyaları koyun. Kurulum Sihirbazı bunları
sessizce kurar; aynı veya daha yeni sürüm zaten kuruluysa atlar, eski sürüm kuruluysa günceller.
Ekran kartı sürücüsü güncellemeleri de bu yolla yapılır (NVIDIA / AMD'nin resmi sürücü paketi).

## Güvenlik

- Sihirbaz başlamadan önce bir **Sistem Geri Yükleme Noktası** oluşturur.
- Değiştirdiği ayarları önceki değerleriyle kaydeder; **Sistem Bakımı → Değişiklikleri Geri Al** ile geri alabilirsiniz.
- İnternetten indirdiği kurulum dosyalarını dijital imzaları geçerli değilse çalıştırmaz.

## Sorun giderme

| Sorun | Çözüm |
| :--- | :--- |
| Program açılmıyor | `C:\ProgramData\ComputerMaintenancePro\Logs\UI_Startup.log` dosyasına bakın. |
| Açılmıyor, mevcut pencere öne geliyor | Program zaten açık; görev çubuğundaki pencereyi kullanın. |
| "Takılı Kopya Bulundu" uyarısı | Arka planda yanıt vermeyen eski bir kopya var; **Evet** diyerek kapatıp programı açabilirsiniz. |
| Bir kurulum adımı başarısız | `Logs\PostInstall.log` ve `Logs\PostInstall_Error.log` dosyalarını geliştiriciye gönderin. |

Tüm değişiklikler için `CHANGELOG.md` dosyasına bakın.
