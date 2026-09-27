#Requires -Version 5.1
<#
.SYNOPSIS
    08_PostInstallAudit.ps1 - Final Verification, Audit & System Summary Report v3.0
.DESCRIPTION
    Non-destructive. Collects system state, verifies all installed components,
    detects chassis, multi-GPU and memory performance, and generates a comprehensive
    HTML and Markdown audit report.
    Reads DocsSyncPath dynamically from config.json with %USERPROFILE% expansion.
#>
[CmdletBinding()]
param()

$ErrorActionPreference = "Continue"
. (Join-Path (Split-Path -Parent $PSScriptRoot) "Tools\Common.ps1")
$cfg = Get-SuiteConfig

function Test-ExeInPath {
    param([string]$Command)
    return [bool](Get-Command $Command -ErrorAction SilentlyContinue)
}

function Get-InstalledVersion {
    param([string]$Command)
    try {
        $ver = & $Command --version 2>&1 | Select-Object -First 1
        return ($ver -replace "[\r\n]","").Trim()
    } catch { return "Bilinmiyor" }
}

function Test-RegInstalled {
    param([string]$Pattern, [string]$Arch = "")
    $paths = @(
        "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*",
        "HKLM:\SOFTWARE\Wow6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*"
    )
    $found = Get-ItemProperty $paths -ErrorAction SilentlyContinue |
               Where-Object { $_.DisplayName -like "*$Pattern*" -and (!$Arch -or $_.DisplayName -like "*$Arch*") }
    return @($found)
}

Write-Output "[INFO] 08_PostInstallAudit: Sistem denetimi ve saglik dogrulamasi baslatiliyor..."

$auditDate = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
$computer  = $env:COMPUTERNAME
$user      = $env:USERNAME
$osInfo    = Get-CimInstance Win32_OperatingSystem -ErrorAction SilentlyContinue
$cpuInfo   = Get-CimInstance Win32_Processor -ErrorAction SilentlyContinue | Select-Object -First 1
$battery   = Get-CimInstance Win32_Battery -ErrorAction SilentlyContinue | Select-Object -First 1
$cs        = Get-CimInstance Win32_ComputerSystem -ErrorAction SilentlyContinue
$enclosure = Get-CimInstance Win32_SystemEnclosure -ErrorAction SilentlyContinue | Select-Object -First 1

# 1. Form Factor / Chassis
$isVM = ($cs.Model -match "Virtual|VMware|VirtualBox|KVM|QEMU")
$chassisTypes = if ($enclosure.ChassisTypes) { $enclosure.ChassisTypes } else { @(3) }
$isLaptop = [bool]($battery -or ($chassisTypes | Where-Object { $_ -in @(8, 9, 10, 11, 12, 14, 18, 21, 31, 32) }))
$chassisStr = if ($isVM) { "Sanal Makine ($($cs.Model))" }
              elseif ($isLaptop) { "Dizustu Bilgisayar (Laptop)" }
              else { "Masaustu Bilgisayar (Desktop / Workstation)" }

# 2. Multi-GPU Discovery
$gpus = Get-CimInstance Win32_VideoController -ErrorAction SilentlyContinue
$gpuNames = ($gpus | ForEach-Object { "$($_.Name) [Surucu: $($_.DriverVersion)]" }) -join " + "

# 3. Component Checks
Write-Output "[INFO] Kurulu bilesenler kontrol ediliyor..."

$vcX64_2022 = @(Test-RegInstalled -Pattern "Visual C++ 2015-20" -Arch "x64") | Select-Object -First 1
$vcX86_2022 = @(Test-RegInstalled -Pattern "Visual C++ 2015-20" -Arch "x86") | Select-Object -First 1
$vcX64_2013 = @(Test-RegInstalled -Pattern "Visual C++ 2013" -Arch "x64") | Select-Object -First 1

# WebView2
$wv2Reg = Get-ItemProperty "HKLM:\SOFTWARE\WOW6432Node\Microsoft\EdgeUpdate\Clients\{F3017226-F501-47EC-9A48-C250257F37C0}",
                           "HKLM:\SOFTWARE\Microsoft\EdgeUpdate\Clients\{F3017226-F501-47EC-9A48-C250257F37C0}" -ErrorAction SilentlyContinue |
          Where-Object { $_.pv } | Select-Object -First 1

# Dev Tools
$gitOk     = Test-ExeInPath "git"
$pythonOk  = Test-ExeInPath "python"
$nodeOk    = Test-ExeInPath "node"
$codeOk    = Test-ExeInPath "code"
$wingetOk  = Test-ExeInPath "winget"
$sevenZOk  = Test-ExeInPath "7z"

# .NET Framework
$net4Release = (Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\NET Framework Setup\NDP\v4\Full" -ErrorAction SilentlyContinue).Release

# Power plan
$currentPlan = (powercfg /getactivescheme 2>&1) -join ""
# Laptops are expected on Balanced (battery), desktops on High Performance
$isHighPerf  = if ($isLaptop) { $currentPlan -like "*381b4222*" -or $currentPlan -like "*8c5e7fda*" } else { $currentPlan -like "*8c5e7fda*" -or $currentPlan -like "*e9a42b02*" }

# RAM XMP status
$memInfo = Get-MemorySpeedInfo
$ramSpeedActual = $memInfo.ActualMTs
$ramSpeedRated  = $memInfo.RatedMTs

# Storage
$volumes = Get-Volume -ErrorAction SilentlyContinue | Where-Object { $_.DriveLetter } | Sort-Object DriveLetter
$domain  = if ($cs) { $cs.Domain } else { "WORKGROUP" }

$checks = @(
    @{ Label = "VC++ 2015-2022 x64";    OK = ($null -ne $vcX64_2022); Detail = if ($vcX64_2022) { $vcX64_2022.DisplayVersion } else { "Eksik" } },
    @{ Label = "VC++ 2015-2022 x86";    OK = ($null -ne $vcX86_2022); Detail = if ($vcX86_2022) { $vcX86_2022.DisplayVersion } else { "Eksik" } },
    @{ Label = "VC++ 2013 x64";         OK = ($null -ne $vcX64_2013); Detail = if ($vcX64_2013) { $vcX64_2013.DisplayVersion } else { "Mevcut degil" } },
    @{ Label = "Edge WebView2 Runtime"; OK = ($null -ne $wv2Reg);     Detail = if ($wv2Reg) { $wv2Reg.pv } else { "Eksik" } },
    @{ Label = "Git";                   OK = $gitOk;                  Detail = if ($gitOk) { Get-InstalledVersion "git" } else { "Kurulu degil" } },
    @{ Label = "Python";                OK = $pythonOk;               Detail = if ($pythonOk) { Get-InstalledVersion "python" } else { "Kurulu degil" } },
    @{ Label = "Node.js";               OK = $nodeOk;                 Detail = if ($nodeOk) { Get-InstalledVersion "node" } else { "Kurulu degil" } },
    @{ Label = "VS Code";               OK = $codeOk;                 Detail = if ($codeOk) { "Kurulu" } else { "Kurulu degil" } },
    @{ Label = "7-Zip";                 OK = $sevenZOk;               Detail = if ($sevenZOk) { Get-InstalledVersion "7z" } else { "Kurulu degil" } },
    @{ Label = "winget Paket Yoneticisi";OK = $wingetOk;              Detail = if ($wingetOk) { Get-InstalledVersion "winget" } else { "Bulunamadi" } },
    @{ Label = "Guc ve Enerji Profili"; OK = $isHighPerf;             Detail = if ($isLaptop) { "Laptop: Dengeli plan (pil dostu)" } else { "Masaustu: Yuksek Performans" } }
)

Write-Output "[INFO] --- Dogrulama Sonuclari ---"
foreach ($check in $checks) {
    $symbol = if ($check.OK) { "[SUCCESS]" } else { "[WARN]" }
    Write-Output "$symbol   $($check.Label): $($check.Detail)"
}

# Generate Markdown Report
$volumeRows = ($volumes | ForEach-Object {
    $freeGB  = [math]::Round($_.SizeRemaining / 1GB, 1)
    $totalGB = [math]::Round($_.Size / 1GB, 1)
    $pct = if ($_.Size -gt 0) { "$([math]::Round(($_.SizeRemaining / $_.Size) * 100, 0))%" } else { "N/A" }
    "| **$($_.DriveLetter):** | $($_.FileSystemLabel) | $($_.FileSystemType) | $totalGB GB | $freeGB GB ($pct) | $($_.HealthStatus) |"
}) -join "`n"

$componentRows = ($checks | ForEach-Object {
    $icon   = if ($_.OK) { "OK" } else { "!!" }
    $status = if ($_.OK) { "Tamam" } else { "Dikkat" }
    "| $icon | **$($_.Label)** | $($_.Detail) | $status |"
}) -join "`n"

$net4Friendly = switch ($net4Release) {
    { $_ -ge 533320 } { ".NET Framework 4.8.1+" }
    { $_ -ge 528040 } { ".NET Framework 4.8"    }
    { $_ -ge 461808 } { ".NET Framework 4.7.2"  }
    default           { "4.x (Release: $net4Release)" }
}

$cpuName = if ($cpuInfo) { $cpuInfo.Name.Trim() } else { "Bilinmiyor" }
$cores = if ($cpuInfo) { "$($cpuInfo.NumberOfCores) Cekirdek / $($cpuInfo.NumberOfLogicalProcessors) Is Parcacigi" } else { "N/A" }
$osCaption = if ($osInfo) { "$($osInfo.Caption) Build $($osInfo.BuildNumber) ($($osInfo.OSArchitecture))" } else { "Windows 10+" }

$reportContent = @"
# Evrensel Post-Installation Denetim Raporu v3.0

**Tarih:** $auditDate
**Bilgisayar:** ``$computer`` | **Kullanici:** ``$user``
**Platform:** $chassisStr | **Framework:** Antigravity Universal Post-Installation v3.0.0

---

## 1. Donanim ve Sistem Profili

| Bilesen | Deger |
| :--- | :--- |
| **Isletim Sistemi** | $osCaption |
| **Kasa Tipi / Form Factor** | $chassisStr |
| **Islemci (CPU)** | $cpuName ($cores) |
| **RAM Calisma Hizi** | $ramSpeedActual MT/s (Nominal: $ramSpeedRated MT/s) |
| **Grafik Birimleri (GPU)** | $gpuNames |
| **.NET Framework** | $net4Friendly |
| **Ag / Etki Alani** | $domain |

---

## 2. Bilesen Dogrulama

| Durum | Bilesen | Detay | Sonuc |
| :---: | :--- | :--- | :--- |
$componentRows

---

## 3. Depolama Birimleri

| Surucu | Etiket | Dosya Sistemi | Toplam | Bos Alan | Saglik |
| :---: | :--- | :--- | ---: | ---: | :--- |
$volumeRows

---

## 4. Log ve Durum Dosyalari

| Dosya | Yer |
| :--- | :--- |
| Ana Kurulum Gunlugu | ``$($cfg.LogFile)`` |
| Hata Gunlugu | ``$($cfg.ErrorLogFile)`` |
| Durum Dosyasi (JSON) | ``$($cfg.StateFile)`` |

---

> Bu rapor Antigravity Universal Post-Installation Framework v3.0 tarafindan otomatik uretilmistir.
> Her marka, model, donanim konfigürasyonu ve sanal makineye tam uyumludur.
"@

# Write report - BOM-free UTF-8
$reportEncoding = New-Object System.Text.UTF8Encoding($false)
$summaryPath = $cfg.SummaryReport
$summaryDir = Split-Path -Parent $summaryPath
if (-not (Test-Path $summaryDir)) { New-Item -Path $summaryDir -ItemType Directory -Force | Out-Null }
[System.IO.File]::WriteAllText($summaryPath, $reportContent, $reportEncoding)
Write-Output "[SUCCESS] Ozet rapor olusturuldu: $summaryPath"

# Sync to Docs directory from config or fallback
$docsDir = $cfg.DocsSyncPath
if (-not $docsDir) {
    $docsDir = Join-Path $env:USERPROFILE "Desktop\Antigravity\Docs"
}

if (-not (Test-Path $docsDir)) {
    try { New-Item -Path $docsDir -ItemType Directory -Force | Out-Null } catch {}
}
if (Test-Path $docsDir) {
    $docsReport = Join-Path $docsDir "PostInstall_Audit.md"
    [System.IO.File]::WriteAllText($docsReport, $reportContent, $reportEncoding)
    Write-Output "[SUCCESS] Rapor Docs klasorune senkronize edildi: $docsReport"
}

# Generate Standalone HTML5 Executive Dashboard
$reportingEngine = Join-Path (Get-SuiteRoot) "Tools\ReportingEngine.ps1"
if (Test-Path $reportingEngine) {
    try {
        . $reportingEngine
        $htmlSpecs = [PSCustomObject]@{
            ComputerName   = $computer
            UserName       = $user
            ChassisType    = $chassisStr
            OSName         = $osCaption
            CPU            = $cpuName
            CPUCores       = $cores
            RAMTotal       = "$ramSpeedActual MT/s"
            RAMSpeedActual = "Nominal: $ramSpeedRated MT/s"
            IsXmpActive    = (-not $memInfo.BelowRatedSpeed)
            GPU            = $gpuNames
            GPUVendor      = "Multi-GPU"
        }
        $htmlTemp = Join-Path $summaryDir "PostInstall_Report.html"
        New-PostInstallHtmlReport -Specs $htmlSpecs -Checks $checks -Volumes $volumes -OutputFile $htmlTemp | Out-Null
        Write-Output "[SUCCESS] HTML5 Yonetici Paneli olusturuldu: $htmlTemp"

        if (Test-Path $docsDir) {
            $htmlDocs = Join-Path $docsDir "PostInstall_Report.html"
            New-PostInstallHtmlReport -Specs $htmlSpecs -Checks $checks -Volumes $volumes -OutputFile $htmlDocs | Out-Null
            Write-Output "[SUCCESS] HTML5 Paneli Docs klasorune senkronize edildi: $htmlDocs"
        }
    } catch {
        Write-Output "[WARN] HTML5 rapor olusturma uyarisi: $_"
    }
}

Write-Output "[SUCCESS] 08_PostInstallAudit tamamlandi."
exit 0
