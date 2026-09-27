#Requires -Version 5.1
<#
.SYNOPSIS
    01_SystemBaseline.ps1 - Enterprise System Baseline & Performance Optimization
.DESCRIPTION
    Applies safe, reversible enterprise best practices inspired by Sophia Script & WinUtil:
    1. Adaptive power plan & sleep timeouts (laptop: Balanced, desktop: High Performance)
    2. SSD TRIM verification and activation
    3. Windows Explorer productivity tweaks (show file extensions, show hidden files)
    4. Privacy / sponsored-app preventions
    5. Windows Defender security intelligence / signature update
    6. Essential service start types (wuauserv, BITS, w32time) + NTP sync
    Every setting change goes through Tools\ChangeJournal.ps1, so it can be undone from the UI.
#>
[CmdletBinding()]
param()

$ErrorActionPreference = "Continue"
. (Join-Path (Split-Path -Parent $PSScriptRoot) "Tools\ChangeJournal.ps1")

Write-Output "[INFO] 01_SystemBaseline: Sistem temel yapilandirmasi baslatiliyor..."
$Script:ChangeCount = 0
function Register-Change { param($Entry) if ($Entry) { $Script:ChangeCount++ } }

#region === 1. POWER PLAN & SLEEP TIMEOUTS (ADAPTIVE: LAPTOP vs DESKTOP) ===
Write-Output "[INFO] Guvenli ve Uyarlanabilir Guc Plani optimizasyonu..."
try {
    $battery   = Get-CimInstance Win32_Battery -ErrorAction SilentlyContinue
    $isLaptop  = [bool]$battery
    $balanced  = "381b4222-f694-41f0-9685-ff5bb260df2e"
    $highPerf  = "8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c"
    $available = (powercfg /list 2>&1) -join "`n"

    if ($isLaptop) {
        # Laptop: Balanced keeps turbo on AC but lets the CPU park on battery (High Performance drains it)
        Register-Change (Set-TrackedPowerPlan -Guid $balanced -Description "Guc plani: Dengeli (dizustu)")
        Register-Change (Set-TrackedPowerTimeout -Setting monitor -Source ac -Minutes 20)
        Register-Change (Set-TrackedPowerTimeout -Setting standby -Source ac -Minutes 45)
        Register-Change (Set-TrackedPowerTimeout -Setting monitor -Source dc -Minutes 5)
        Register-Change (Set-TrackedPowerTimeout -Setting standby -Source dc -Minutes 15)
        Write-Output "[SUCCESS] Dizustu Bilgisayar algilandi: 'Dengeli' plan + pil dostu uyku sureleri uygulandi."
    } else {
        # Desktop / Workstation / VM: High Performance if the plan exists (Modern Standby systems only ship Balanced)
        if ($available -match $highPerf) {
            Register-Change (Set-TrackedPowerPlan -Guid $highPerf -Description "Guc plani: Yuksek Performans (masaustu)")
            Write-Output "[SUCCESS] Masaustu / Is Istasyonu algilandi: 'Yuksek Performans' plani aktif."
        } else {
            Write-Output "[NOTE] Yuksek Performans plani bu sistemde yok (Modern Standby). Dengeli plan korunuyor."
        }
        Register-Change (Set-TrackedPowerTimeout -Setting standby -Source ac -Minutes 0)
        Register-Change (Set-TrackedPowerTimeout -Setting monitor -Source ac -Minutes 30)
        Register-Change (Set-TrackedPowerTimeout -Setting hibernate -Source ac -Minutes 0)
        Write-Output "[SUCCESS] Prizde uyku devre disi, ekran 30 dk sonra kapanir."
    }
} catch {
    Write-Output "[WARN] Guc plani degistirilirken uyari: $_"
}
#endregion

#region === 2. SSD TRIM VERIFICATION ===
Write-Output "[INFO] SSD TRIM durumu kontrol ediliyor..."
try {
    $trim = Set-TrackedTrim
    Register-Change $trim
    if ($trim) { Write-Output "[SUCCESS] SSD TRIM basariyla etkinlestirildi." }
    else       { Write-Output "[SUCCESS] SSD TRIM aktif (DisableDeleteNotify = 0)." }
} catch {
    Write-Output "[WARN] TRIM sorgulama hatasi: $_"
}
#endregion

#region === 3. WINDOWS EXPLORER PRODUCTIVITY TWEAKS ===
Write-Output "[INFO] Gelistirici & Sistem Yoneticisi Dosya Gezgini ayarlari uygulaniyor..."
try {
    $advKey = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced"
    if (Test-Path $advKey) {
        Register-Change (Set-TrackedRegistryValue -Path $advKey -Name "HideFileExt" -Value 0 -Description "Dosya uzantilarini goster")
        Register-Change (Set-TrackedRegistryValue -Path $advKey -Name "Hidden" -Value 1 -Description "Gizli dosyalari goster")
        Register-Change (Set-TrackedRegistryValue -Path $advKey -Name "LaunchTo" -Value 1 -Description "Gezgin 'Bu Bilgisayar' ile acilsin")
        Write-Output "[SUCCESS] Dosya Gezgini ayarlari uygulandi: Dosya uzantilari gorunur, Bu Bilgisayar acilisi aktif."
    }
} catch {
    Write-Output "[WARN] Dosya Gezgini ayarlari uygulanamadi: $_"
}
#endregion

#region === 3b. PRIVACY & CONSUMER BLOATWARE PREVENTIONS (WINUTIL / SOPHIA PRACTICES) ===
Write-Output "[INFO] Gizlilik ve Tuketici Bloatware onleme politikalari uygulaniyor..."
try {
    # 1. Disable Bing web results in Start menu (speeds up local file and app search)
    Register-Change (Set-TrackedRegistryValue -Path "HKCU:\Software\Policies\Microsoft\Windows\Explorer" -Name "DisableSearchBoxSuggestions" -Value 1 -Description "Baslat menusu web onerilerini kapat")

    $searchUserKey = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Search"
    if (Test-Path $searchUserKey) {
        Register-Change (Set-TrackedRegistryValue -Path $searchUserKey -Name "BingSearchEnabled" -Value 0 -Description "Bing aramasini kapat")
    }

    # 2. Prevent automatic installation of suggested sponsored consumer apps (TikTok, CandyCrush etc.)
    $cdmKey = "HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager"
    if (Test-Path $cdmKey) {
        foreach ($n in @("SilentInstalledAppsEnabled", "SystemPaneSuggestionsEnabled", "SubscribedContent-338388Enabled", "SubscribedContent-338389Enabled")) {
            Register-Change (Set-TrackedRegistryValue -Path $cdmKey -Name $n -Value 0 -Description "Sponsorlu uygulama/oneri kapat: $n")
        }
    }

    # 3. Disable advertising identifier
    $adKey = "HKCU:\Software\Microsoft\Windows\CurrentVersion\AdvertisingInfo"
    if (Test-Path $adKey) {
        Register-Change (Set-TrackedRegistryValue -Path $adKey -Name "Enabled" -Value 0 -Description "Reklam kimligini kapat")
    }

    Write-Output "[SUCCESS] Sistem gizlilik & arama optimizasyonu tamamlandi (Bing arama reklamlari ve sponsorlu appx'ler engellendi)."
} catch {
    Write-Output "[WARN] Gizlilik ayarlari yapilandirilirken uyari: $_"
}
#endregion

#region === 4. WINDOWS DEFENDER ANTIVIRUS SIGNATURE UPDATE ===
Write-Output "[INFO] Windows Defender guvenlik imza guncellemesi tetikleniyor..."
try {
    $mpCmd = "$env:ProgramFiles\Windows Defender\MpCmdRun.exe"
    if (Test-Path $mpCmd) {
        $proc = Start-Process -FilePath $mpCmd -ArgumentList "-SignatureUpdate" -Wait -PassThru -NoNewWindow
        if ($proc.ExitCode -eq 0) {
            Write-Output "[SUCCESS] Windows Defender virus tanim dosyalari guncellendi."
        } else {
            Write-Output "[INFO] Windows Defender imza kontrolu yapildi (Exit: $($proc.ExitCode))."
        }
    } else {
        Update-MpSignature -ErrorAction SilentlyContinue
        Write-Output "[SUCCESS] Windows Defender imza guncellemesi tamamlandi."
    }
} catch {
    Write-Output "[WARN] Defender imza guncellemesi atlandi: $_"
}
#endregion

#region === 5. CORE SYSTEM SERVICES & NTP TIME SYNC ===
Write-Output "[INFO] Temel Windows servisleri yapilandiriliyor..."
$services = @(
    @{ Name = "W32Time";  Start = "Automatic"; StartNow = $true },
    @{ Name = "wuauserv"; Start = "Manual";    StartNow = $false },
    @{ Name = "BITS";     Start = "Manual";    StartNow = $false }
)

foreach ($s in $services) {
    try {
        Register-Change (Set-TrackedServiceStartType -Name $s.Name -StartType $s.Start -Description "Servis $($s.Name) -> $($s.Start)")
        if ($s.StartNow) { Start-Service -Name $s.Name -ErrorAction SilentlyContinue }
        Write-Output "[SUCCESS] Servis $($s.Name) -> $($s.Start)"
    } catch {
        Write-Output "[WARN] Servis $($s.Name) yapilandirma uyarisi: $_"
    }
}

try {
    w32tm /resync /nowait 2>&1 | Out-Null
    Write-Output "[SUCCESS] Windows Zaman Sunucusu (NTP) senkronizasyonu tetiklendi."
} catch {
    Write-Output "[WARN] NTP senkronizasyon uyarisi: $_"
}
#endregion

Write-Output "[INFO] $Script:ChangeCount ayar degisikligi kaydedildi (Sistem Bakimi > Degisiklikleri Geri Al ile geri alinabilir)."
Write-Output "[SUCCESS] 01_SystemBaseline adimi basariyla tamamlandi."
exit 0
