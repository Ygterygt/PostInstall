#Requires -Version 5.1
<#
.SYNOPSIS
    05_HardwareAndDrivers.ps1 - Universal Hardware & Device Driver Health Audit v3.0
.DESCRIPTION
    Comprehensive hardware and driver diagnostics for ANY PC (Desktop, Laptop, VM):
    1. Multi-GPU Inventory (NVIDIA / AMD / Intel, Discrete vs Integrated, Driver version & date)
    2. Network & Wireless Interfaces (Ethernet, Wi-Fi link speed & status)
    3. Audio & Sound Controller Inventory (Realtek, High Definition Audio, USB/Bluetooth Audio)
    4. Chassis & Battery Health (AC/DC state, battery level)
    5. Device Manager yellow-bang error scan (ConfigManagerErrorCode != 0)
    6. Memory XMP/DOCP/EXPO frequency validation
#>
[CmdletBinding()]
param()

$ErrorActionPreference = "Continue"

Write-Output "[INFO] 05_HardwareAndDrivers: Evrensel donanim ve surucu saglik taramasi baslatiliyor..."
Write-Output "[INFO] Hedef Sistem: $env:COMPUTERNAME | Kullanici: $env:USERNAME"

#region === 1. GRAPHICS CONTROLLERS (MULTI-GPU) ===
Write-Output "[INFO] --- Grafik Bagdastirici Envanteri (Multi-GPU) ---"
try {
    $gpus = Get-CimInstance Win32_VideoController -ErrorAction SilentlyContinue
    foreach ($gpu in $gpus) {
        $driverDate = "Bilinmiyor"
        if ($gpu.DriverDate) {
            try { $driverDate = ([datetime]$gpu.DriverDate).ToString('yyyy-MM-dd') } catch {}
        }
        $isDiscrete = ($gpu.Name -like "*NVIDIA*" -or $gpu.Name -match "(RX|XT|Arc|Pro|Vega 56|Vega 64)")
        $typeTag = if ($isDiscrete) { "[Harici dGPU]" } else { "[Dahili iGPU / Standart]" }
        Write-Output "[INFO]   GPU: $($gpu.Name) $typeTag | Surucu: $($gpu.DriverVersion) ($driverDate) | Durum: $($gpu.Status)"
    }
} catch {
    Write-Output "[WARN] GPU bilgisi alinamadi: $_"
}
#endregion

#region === 2. NETWORK & WIRELESS ADAPTERS ===
Write-Output "[INFO] --- Ag & Kablosuz Bagdastirici Durumu ---"
try {
    $netAdapters = Get-NetAdapter -ErrorAction SilentlyContinue | Sort-Object Status -Descending
    if ($netAdapters) {
        foreach ($nic in $netAdapters) {
            $speed = if ($nic.LinkSpeed) { $nic.LinkSpeed } else { "Baglanti Yok" }
            Write-Output "[INFO]   NIC: $($nic.InterfaceAlias) ($($nic.InterfaceDescription)) | Durum: $($nic.Status) | Hiz: $speed"
        }
    } else {
        Get-CimInstance Win32_NetworkAdapter -Filter "NetConnectionStatus = 2" -ErrorAction SilentlyContinue | ForEach-Object {
            Write-Output "[INFO]   NIC: $($_.Name) | Bagli"
        }
    }
} catch {
    Write-Output "[WARN] Ag bagdastirici sorgulama hatasi: $_"
}
#endregion

#region === 3. AUDIO & SOUND CONTROLLERS ===
Write-Output "[INFO] --- Ses Donanimlari (Audio Controllers) ---"
try {
    $soundDevices = Get-CimInstance Win32_SoundDevice -ErrorAction SilentlyContinue
    if ($soundDevices) {
        foreach ($snd in $soundDevices) {
            Write-Output "[INFO]   Ses: $($snd.Name) | Uretici: $($snd.Manufacturer) | Durum: $($snd.Status)"
        }
    } else {
        Write-Output "[INFO] Ses aygiti bilgisi alinamadi."
    }
} catch {
    Write-Output "[WARN] Ses aygiti sorgulama hatasi: $_"
}
#endregion

#region === 4. CHASSIS & BATTERY HEALTH ===
try {
    $battery = Get-CimInstance Win32_Battery -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($battery) {
        $statusStr = switch ($battery.BatteryStatus) {
            1 { "Desarj Oluyor (Pilde)" }
            2 { "Sarj Oluyor (Prizde)" }
            default { "Prizde / Beklemede" }
        }
        Write-Output "[INFO]   Pil Durumu: %$($battery.EstimatedChargeRemaining) | $statusStr | Saglik Kodu: $($battery.Status)"
    } else {
        Write-Output "[INFO]   Guc Kaynagi: Masaustu AC Sebeke Gucu (Batarya yok)."
    }
} catch {}
#endregion

#region === 5. DEVICE MANAGER ERROR & MISSING DRIVER SCAN ===
Write-Output "[INFO] --- Aygit Yoneticisi Hata & Eksik Surucu Taramasi ---"
try {
    $problemDevices = Get-CimInstance Win32_PnPEntity -Filter "ConfigManagerErrorCode != 0" -ErrorAction SilentlyContinue

    if ($problemDevices -and $problemDevices.Count -gt 0) {
        Write-Output "[WARN] $($problemDevices.Count) adet aygitta surucu veya donanim sorunu tespit edildi:"
        foreach ($dev in $problemDevices) {
            $hwId = ($dev.HardwareID | Select-Object -First 1)
            Write-Output "[WARN]   - Aygit: $($dev.Name) (Hata Kodu: $($dev.ConfigManagerErrorCode), Donanim ID: $hwId)"
        }
    } else {
        Write-Output "[SUCCESS] Aygit Yoneticisi temiz: Hatali veya surucusu eksik donanim bulunamadi."
    }
} catch {
    Write-Output "[WARN] PnP Aygit taramasi sirasinda hata: $_"
}
#endregion

#region === 6. MEMORY & XMP NOTIFICATION ===
try {
    $rams = Get-CimInstance Win32_PhysicalMemory -ErrorAction SilentlyContinue
    if ($rams) {
        $r1 = $rams | Select-Object -First 1
        $actualSpeed = if ($r1.ConfiguredClockSpeed) { $r1.ConfiguredClockSpeed * 2 } else { $r1.Speed }
        $ratedSpeed  = $r1.Speed
        if ($ratedSpeed -gt $actualSpeed -and $actualSpeed -lt 2933) {
            Write-Output "[NOTE] Donanim Uyarisi: RAM bellekleriniz $ratedSpeed MHz desteklemesine ragmen su an $actualSpeed MHz hizinda calisiyor. BIOS'tan XMP/DOCP/EXPO acilmasi tavsiye edilir."
        } else {
            Write-Output "[SUCCESS] RAM calisma frekansi: $actualSpeed MHz."
        }
    }
} catch {}
#region === 7. OFFLINE DRIVER INJECTION (PnP INF PACKAGES) ===
$driverDir = "C:\PostInstall\Drivers"
$driverEnginePath = "C:\PostInstall\Tools\DriverEngine.ps1"
if ((Test-Path $driverDir) -and (Test-Path $driverEnginePath)) {
    . $driverEnginePath
    $res = Install-SystemDrivers -DriverSourceDir $driverDir
    if ($res.DiscoveredInfs -gt 0) {
        if ($res.Success) {
            Write-Output "[SUCCESS] '$driverDir' altindaki $($res.InstalledCount) adet INF surucu paketi sisteme enjekte edildi."
        } else {
            Write-Output "[WARN] Surucu enjeksiyonu uyarisi: $($res.ErrorMessage)"
        }
    } else {
        Write-Output "[INFO] '$driverDir' dizininde bekleyen ek cevrimdisi surucu paketi yok."
    }
}
#endregion

Write-Output "[SUCCESS] 05_HardwareAndDrivers adimi tamamlandi."
exit 0
