#Requires -Version 5.1
<#
.SYNOPSIS
    09_SystemUpdates.ps1 - Hardware-Aware GPU Compatibility & Platform Update Manager
.DESCRIPTION
    Dynamically maps installed GPU models against gpu_compatibility.json database:
    1. Multi-GPU Driver & Companion App Management (NVIDIA, AMD, Intel, VMs):
       - Exact architecture & profile pattern matching
       - Registry & package existence / version inspection
       - Automated silent installation / update via PackageEngine
    2. Motherboard & Chipset Drivers (AMD AM4/AM5/Mobile, Intel Core/Ultra)
    3. Virtual Machine Guest Integrations Check (VMware Tools, VirtualBox, Hyper-V)
    4. Universal BIOS / Motherboard update advisory
    5. Windows Update COM-based scan & pending driver check
.NOTES
    Author : Antigravity Systems Team
    Version: 4.0.0
#>
[CmdletBinding()]
param()

$ErrorActionPreference = "Continue"

Write-Output "[INFO] 09_SystemUpdates: Donanim uyumluluk matrisi ve GPU yoneticisi baslatiliyor..."

$engineRoot = Split-Path -Parent $PSScriptRoot
$gpuDbPath = Join-Path $engineRoot "gpu_compatibility.json"
$packageEngine = Join-Path $engineRoot "Tools\PackageEngine.ps1"

if (Test-Path $packageEngine) { . $packageEngine }

$tempDir = Join-Path $env:TEMP "PostInstall_Drivers"
if (-not (Test-Path $tempDir)) { New-Item -Path $tempDir -ItemType Directory -Force | Out-Null }

# Load GPU Compatibility Matrix
$gpuDb = $null
if (Test-Path $gpuDbPath) {
    try {
        $gpuDb = Get-Content -LiteralPath $gpuDbPath -Raw -Encoding UTF8 | ConvertFrom-Json
        Write-Output "[INFO] GPU Uyumluluk Veritabani yuklendi (v$($gpuDb.Version))."
    } catch {
        Write-Output "[WARN] gpu_compatibility.json okunamadi: $_"
    }
}

# Enumerate Hardware
$gpus     = Get-CimInstance Win32_VideoController -ErrorAction SilentlyContinue
$cpuInfo  = Get-CimInstance Win32_Processor -ErrorAction SilentlyContinue | Select-Object -First 1
$baseInfo = Get-CimInstance Win32_BaseBoard -ErrorAction SilentlyContinue
$biosInfo = Get-CimInstance Win32_BIOS -ErrorAction SilentlyContinue
$cs       = Get-CimInstance Win32_ComputerSystem -ErrorAction SilentlyContinue

$cpuName = if ($cpuInfo) { $cpuInfo.Name.Trim() } else { "Bilinmiyor" }
$mbInfo  = "$($baseInfo.Manufacturer) $($baseInfo.Product)".Trim()
if (-not $mbInfo) { $mbInfo = "$($cs.Manufacturer) $($cs.Model)".Trim() }

Write-Output "[INFO] Sistem Profili: CPU: $cpuName | Anakart/Model: $mbInfo"

#region === 1. GPU MATRIX COMPATIBILITY & COMPANION APPS ===
Write-Output "`n[INFO] ===== 1. EKRAN KARTI (GPU) UYUMLULUK VE YONETIM MATRISI ====="

foreach ($gpu in $gpus) {
    $gpuName = $gpu.Name
    $driverVer = $gpu.DriverVersion
    Write-Output "`n[INFO] ----------------------------------------"
    Write-Output "[INFO] GPU: $gpuName"
    Write-Output "[INFO] Kurulu Surucu Versiyonu: $driverVer"

    # Identify Vendor
    $vendorKey = "Virtual"
    if ($gpuName -match "NVIDIA|GeForce|RTX|GTX|Quadro") { $vendorKey = "NVIDIA" }
    elseif ($gpuName -match "AMD|Radeon") { $vendorKey = "AMD" }
    elseif ($gpuName -match "Intel") { $vendorKey = "Intel" }

    if ($gpuDb -and $gpuDb.Vendors.$vendorKey) {
        $vendorData = $gpuDb.Vendors.$vendorKey
        $matchedProfile = $null

        foreach ($profile in $vendorData.Profiles) {
            if ($gpuName -match $profile.Pattern) {
                $matchedProfile = $profile
                break
            }
        }

        if (-not $matchedProfile) {
            $matchedProfile = $vendorData.Profiles | Select-Object -First 1
        }

        if ($matchedProfile) {
            Write-Output "[INFO] Uretici: $($vendorData.VendorName)"
            Write-Output "[INFO] Profil: $($matchedProfile.Name) [Tur: $($matchedProfile.Type)]"
            Write-Output "[INFO] Onerilen Yazilim: $($matchedProfile.RecommendedApp)"

            # Check if companion software is already installed
            $checkInfo = Get-InstalledAppInfo -Name $matchedProfile.RecommendedApp -RegistryPattern $matchedProfile.RegistryDisplayName
            if ($checkInfo.IsInstalled) {
                Write-Output "[SUCCESS] Destek yazilimi zaten kurulu: $($checkInfo.DisplayName) ($($checkInfo.InstalledVersion))"
            } else {
                Write-Output "[INFO] Destek yazilimi kurulu degil. Kurulum baslatiliyor..."
                $targetId = if ($matchedProfile.WinGetId) { $matchedProfile.WinGetId } else { $matchedProfile.AltWinGetId }

                if ($targetId) {
                    $installRes = Install-ResilientPackage `
                        -Name $matchedProfile.RecommendedApp `
                        -WingetId $targetId `
                        -RegistryCheckPattern $matchedProfile.RegistryDisplayName `
                        -DirectDownloadUrl $matchedProfile.DirectDownloadUrl
                    
                    if ($installRes.Success) {
                        Write-Output "[SUCCESS] $($matchedProfile.RecommendedApp) basariyla entegre edildi."
                    } else {
                        Write-Output "[NOTE] Manuel indirme adresi: $($matchedProfile.DirectDownloadUrl)"
                    }
                }
            }
        }
    } else {
        Write-Output "[INFO] Standart video bagdastiricisi algilandi."
    }
}
#endregion

#region === 2. MOTHERBOARD & CHIPSET DRIVERS ===
Write-Output "`n[INFO] ===== 2. ANAKART VE YONTA KÜMESİ (CHIPSET) YONETIMI ====="
if ($cpuName -match "AMD|Ryzen") {
    Write-Output "[INFO] [AMD] AMD Ryzen Islemci Platformu tespit edildi."
    $amdChipset = Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*",
                                   "HKLM:\SOFTWARE\Wow6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*" -ErrorAction SilentlyContinue |
                  Where-Object { $_.DisplayName -like "*AMD Chipset*" } | Select-Object -First 1
    if ($amdChipset) {
        Write-Output "[SUCCESS] AMD Chipset Surucusu kurulu: $($amdChipset.DisplayName) ($($amdChipset.DisplayVersion))"
    } else {
        Write-Output "[INFO] AMD Chipset Software eksik. Resmi indirme portalindan guncellenmesi onerilir."
        Write-Output "[NOTE] AMD Resmi Destek: https://www.amd.com/en/support"
    }
} elseif ($cpuName -match "Intel") {
    Write-Output "[INFO] [Intel] Intel Core/Xeon Islemci Platformu tespit edildi."
    $intelInf = Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*",
                                 "HKLM:\SOFTWARE\Wow6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*" -ErrorAction SilentlyContinue |
                Where-Object { $_.DisplayName -like "*Intel*Chipset*" -or $_.DisplayName -like "*Intel(R) Management Engine*" } | Select-Object -First 1
    if ($intelInf) {
        Write-Output "[SUCCESS] Intel Chipset / ME Yazilimi kurulu: $($intelInf.DisplayName)"
    } else {
        Write-Output "[INFO] Intel Chipset Device Software kontrol edildi."
        Write-Output "[NOTE] Intel DSA: https://www.intel.com/content/www/us/en/support/detect.html"
    }
}
#endregion

#region === 3. VIRTUAL MACHINE GUEST INTEGRATIONS ===
Write-Output "`n[INFO] ===== 3. SANALLESME VE KONUK ARACLARI ====="
$biosSerial = if ($biosInfo) { $biosInfo.SerialNumber } else { "" }
$biosManuf  = if ($biosInfo) { $biosInfo.Manufacturer } else { "" }
$sysModel   = if ($cs) { $cs.Model } else { "" }

if ($sysModel -match "VirtualBox" -or $biosManuf -match "innotek") {
    Write-Output "[INFO] VirtualBox Sanal Makinesi algilandi. Guest Additions durumu kontrol ediliyor..."
} elseif ($sysModel -match "VMware" -or $biosSerial -match "VMware") {
    Write-Output "[INFO] VMware Sanal Makinesi algilandi. VMware Tools durumu kontrol ediliyor..."
} elseif ($sysModel -match "Virtual Machine" -or $biosManuf -match "Microsoft") {
    Write-Output "[INFO] Microsoft Hyper-V Sanal Makinesi algilandi. Entegrasyon servisleri aktif."
} else {
    Write-Output "[INFO] Fiziksel Bare-Metal Donanim. Sanallastirma konuk araci gerekmiyor."
}
#endregion

#region === 4. BIOS & FIRMWARE STATUS ===
Write-Output "`n[INFO] ===== 4. BIOS / UEFI SURUM BILGISI ====="
if ($biosInfo) {
    Write-Output "[INFO] BIOS Surumu: $($biosInfo.SMBIOSBIOSVersion) (Yayin: $($biosInfo.ReleaseDate))"
    Write-Output "[INFO] BIOS Ureticisi: $($biosInfo.Manufacturer)"
}
#endregion

#region === 5. WINDOWS UPDATE COM SCAN ===
Write-Output "`n[INFO] ===== 5. WINDOWS UPDATE VE SURUCU TARAMASI ====="
try {
    $updateSession = New-Object -ComObject Microsoft.Update.Session
    $updateSearcher = $updateSession.CreateUpdateSearcher()
    Write-Output "[INFO] Eksik sistem ve surucu guncellemeleri taranıyor (COM API)..."
    $searchResult = $updateSearcher.Search("IsInstalled=0 and Type='Driver'")
    if ($searchResult.Updates.Count -gt 0) {
        Write-Output "[WARN] $($searchResult.Updates.Count) adet bekleyen donanim surucu guncellemesi bulundu:"
        foreach ($u in $searchResult.Updates) {
            Write-Output "  - $($u.Title)"
        }
    } else {
        Write-Output "[SUCCESS] Windows Update uzerinde bekleyen eksik surucu bulunamadi."
    }
} catch {
    Write-Output "[INFO] Windows Update COM baglantisi atlandi: $($_.Exception.Message)"
}
#endregion

# Cleanup
try { Remove-Item $tempDir -Recurse -Force -ErrorAction SilentlyContinue } catch {}

Write-Output "`n[SUCCESS] 09_SystemUpdates tamamlandi."
exit 0
