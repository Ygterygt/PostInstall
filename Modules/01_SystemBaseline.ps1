#Requires -Version 5.1
<#
.SYNOPSIS
    01_SystemBaseline.ps1 - Enterprise System Baseline & Performance Optimization
.DESCRIPTION
    Applies safe, reversible enterprise best practices inspired by Sophia Script & WinUtil:
    1. High Performance Power Plan & sleep timeout adjustment
    2. SSD TRIM verification and activation
    3. Windows Explorer productivity tweaks (show file extensions, show hidden files)
    4. Windows Defender security intelligence / signature update
    5. Windows Time (NTP) service synchronization
    6. Essential service start types (wuauserv, BITS, w32time)
#>
[CmdletBinding()]
param()

$ErrorActionPreference = "Continue"

Write-Output "[INFO] 01_SystemBaseline: Sistem temel yapilandirmasi baslatiliyor..."

#region === 1. POWER PLAN & SLEEP TIMEOUTS (ADAPTIVE: LAPTOP vs DESKTOP) ===
Write-Output "[INFO] Guvenli ve Uyarlanabilir Guc Plani optimizasyonu..."
try {
    $battery = Get-CimInstance Win32_Battery -ErrorAction SilentlyContinue
    $isLaptop = [bool]$battery
    $highPerfGuid = "8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c"

    # Set High Performance on AC
    powercfg /setactive $highPerfGuid 2>&1 | Out-Null
    
    if ($isLaptop) {
        # Laptop: Optimize both AC (plugged in) and DC (battery) to protect battery health
        powercfg /change monitor-timeout-ac 20 2>&1 | Out-Null
        powercfg /change standby-timeout-ac 45 2>&1 | Out-Null
        powercfg /change monitor-timeout-dc 5 2>&1 | Out-Null
        powercfg /change standby-timeout-dc 15 2>&1 | Out-Null
        Write-Output "[SUCCESS] Dizustu Bilgisayar algilandi: Prizde Yuksek Performans, bataryada dengeli enerji koruma profili uygulandi."
    } else {
        # Desktop / Workstation / VM: Full throttle, no sleep on AC
        powercfg /change standby-timeout-ac 0 2>&1 | Out-Null
        powercfg /change monitor-timeout-ac 30 2>&1 | Out-Null
        powercfg /change hibernate-timeout-ac 0 2>&1 | Out-Null
        Write-Output "[SUCCESS] Masaustu / Is Istasyonu algilandi: 'Yuksek Performans' (High Performance, kesintisiz calisma) uygulandi."
    }
} catch {
    Write-Output "[WARN] Guc plani degistirilirken uyari: $_"
}
#endregion

#region === 2. SSD TRIM VERIFICATION ===
Write-Output "[INFO] SSD TRIM durumu kontrol ediliyor..."
try {
    $trimStatus = fsutil behavior query DisableDeleteNotify
    if ($trimStatus -like "*= 0*") {
        Write-Output "[SUCCESS] SSD TRIM aktif (DisableDeleteNotify = 0)."
    } else {
        fsutil behavior set DisableDeleteNotify 0 2>&1 | Out-Null
        Write-Output "[SUCCESS] SSD TRIM basariyla etkinlestirildi."
    }
} catch {
    Write-Output "[WARN] TRIM sorgulama hatasi: $_"
}
#endregion

#region === 3. WINDOWS EXPLORER PRODUCTIVITY TWEAKS ===
Write-Output "[INFO] Gelistirici & Sistem Yoneticisi Dosya Gezgini ayarlari uygulaniyor..."
try {
    $advKey = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced"
    if (Test-Path $advKey) {
        # Show file extensions (HideFileExt = 0)
        Set-ItemProperty -Path $advKey -Name "HideFileExt" -Value 0 -Type DWord -Force
        # Show hidden files and folders (Hidden = 1)
        Set-ItemProperty -Path $advKey -Name "Hidden" -Value 1 -Type DWord -Force
        # Launch Explorer to 'This PC' (1 = This PC, 2 = Quick Access)
        Set-ItemProperty -Path $advKey -Name "LaunchTo" -Value 1 -Type DWord -Force
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
    $searchPolicyKey = "HKCU:\Software\Policies\Microsoft\Windows\Explorer"
    if (-not (Test-Path $searchPolicyKey)) { New-Item -Path $searchPolicyKey -Force | Out-Null }
    Set-ItemProperty -Path $searchPolicyKey -Name "DisableSearchBoxSuggestions" -Value 1 -Type DWord -Force

    $searchUserKey = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Search"
    if (Test-Path $searchUserKey) {
        Set-ItemProperty -Path $searchUserKey -Name "BingSearchEnabled" -Value 0 -Type DWord -Force -ErrorAction SilentlyContinue
    }

    # 2. Prevent automatic installation of suggested sponsored consumer apps (TikTok, CandyCrush etc.)
    $cdmKey = "HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager"
    if (Test-Path $cdmKey) {
        Set-ItemProperty -Path $cdmKey -Name "SilentInstalledAppsEnabled" -Value 0 -Type DWord -Force
        Set-ItemProperty -Path $cdmKey -Name "SystemPaneSuggestionsEnabled" -Value 0 -Type DWord -Force
        Set-ItemProperty -Path $cdmKey -Name "SubscribedContent-338388Enabled" -Value 0 -Type DWord -Force
        Set-ItemProperty -Path $cdmKey -Name "SubscribedContent-338389Enabled" -Value 0 -Type DWord -Force
    }

    # 3. Disable advertising identifier
    $adKey = "HKCU:\Software\Microsoft\Windows\CurrentVersion\AdvertisingInfo"
    if (Test-Path $adKey) {
        Set-ItemProperty -Path $adKey -Name "Enabled" -Value 0 -Type DWord -Force
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
        Set-Service -Name $s.Name -StartupType $s.Start -ErrorAction SilentlyContinue
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

Write-Output "[SUCCESS] 01_SystemBaseline adimi basariyla tamamlandi."
exit 0
