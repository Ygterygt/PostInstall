# Değişiklik Günlüğü

Bu dosya [Keep a Changelog](https://keepachangelog.com/tr-TR/1.1.0/) biçimini, sürüm numaraları
[Semantic Versioning](https://semver.org/lang/tr/) kurallarını izler. Sürüm numarası `config.json` → `Version` alanındadır.

## [4.2.0] - 2026-09-27

### Eklenenler
- **Güncellemeler sekmesi:** `winget` ile güncellemesi olan uygulamaları listeler, seçilenleri sırayla günceller;
  `config.json` → `Updates.ExcludeIds` ile hariç tutulabilir.
- **Zamanlanmış bakım:** Bakım sekmesinden haftalık görev (temp temizliği, DNS önbelleği, TRIM, uygulama güncellemeleri).
  Pildeyken çalışmaz, kaçırılırsa ilk fırsatta çalışır.
- **Değişiklik günlüğü ve geri alma:** Kurulum sihirbazının değiştirdiği registry, servis, güç, DNS ve Defender ayarları
  önceki değerleriyle kaydedilir; Bakım sekmesinden tek tek ya da toplu geri alınabilir.
- GPU kartlarında üretici yazılımının kurulu olup olmadığı ve sürümü gösterilir.
- `Installers\` klasöründeki yükleyiciler için "zaten kurulu / güncellenecek" bilgisi; eski sürüm kuruluysa güncellenir.
- NVIDIA ve AMD Adrenalin sürücü paketleri için sessiz kurulum parametreleri.
- Arayüz zaten açıksa ikinci kopya açılmaz, mevcut pencere öne gelir.
- `PostInstall.exe` dosya özelliklerinde sürüm bilgisi.

### Düzeltilenler
- Uygulama kapatılırken çıkan "Bağımsız değişken türleri eşleşmiyor" hatası.
- Yeniden başlatma sonrası kurulum sihirbazının kaldığı yerden **hiç devam etmemesi**.
- GPU yazılımı kurulurken yanlış sekmeye geçilmesi; her GPU kartının son GPU'nun yazılımını kurması.
- GPU veritabanındaki geçersiz paket kimlikleri ve çalışmayan indirme bağlantıları.
- AMD için Microsoft Store'daki eski uygulamanın önerilmesi (PA-300 hatası).
- RAM hızının iki katı gösterilmesi (DDR5-4800 → "9600 MHz").
- Sistem PATH değişkenindeki `%SystemRoot%` gibi referansların bozulması.
- Bakım işlemlerinin motorun kendi log/state dosyalarını silmesi.
- Canlı izlemede anlamsız CPU yüzdesi ve saat hızı.
- Türkçe karakterlerin log'larda bozulması; modül çıktısının adım bitince toplu gelmesi.

### Değişenler
- Log, state ve raporlar artık `%ProgramData%\ComputerMaintenancePro` altında; program klasörü USB'ye ya da başka
  bir sürücüye taşınabilir.
- Varsayılan olarak daha az yıkıcı: Geri Dönüşüm Kutusu boşaltılmaz, DISM ResetBase kapalı, olay günlükleri silinmeden
  önce arşivlenir, DNS yalnızca otomatik (DHCP) ağlarda ve etki alanına katılmamış bilgisayarlarda değişir.
- Dizüstü bilgisayarlarda "Yüksek Performans" yerine "Dengeli" güç planı.
- Kurulum raporu masaüstüne kopyalanmaz (isteğe bağlı: `config.json` → `DocsSyncPath`).
- İnternetten indirilen kurulum dosyaları geçerli dijital imza olmadan çalıştırılmaz.

### Kaldırılanlar
- GPU kartlarındaki "Sürücüyü Yedekle" (sürücü güncellemeleri artık `Installers\` klasöründeki resmi paketlerle yapılır;
  eski sürüme dönmek için Aygıt Yöneticisi → Sürücüyü Geri Al).

## [4.1.0]

- İlk sürüm.

[4.2.0]: https://github.com/Ygterygt/PostInstall/releases/tag/v4.2.0
