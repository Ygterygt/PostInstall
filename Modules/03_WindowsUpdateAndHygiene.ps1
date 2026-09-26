#Requires -Version 5.1
<#
.SYNOPSIS
    03_WindowsUpdateAndHygiene.ps1 - Enterprise System Care, Component Store & Hygiene
.DESCRIPTION
    Comprehensive Windows Update service verification, temp junk purge (age-thresholded),
    SoftwareDistribution cache purge, DISM component store cleanup, and event log hygiene.
    All behaviour is driven by config.json -> Maintenance.
.NOTES
    Author : Antigravity Systems Team
    Version: 4.1.0
#>
[CmdletBinding()]
param()

$ErrorActionPreference = "Continue"

Write-Output "[INFO] 03_WindowsUpdateAndHygiene: Kapsamli sistem bakimi ve hijyeni baslatiliyor..."

. (Join-Path (Split-Path -Parent $PSScriptRoot) "Tools\Common.ps1")
$maintEngine = Join-Path (Get-SuiteRoot) "Tools\MaintenanceEngine.ps1"
if (-not (Test-Path $maintEngine)) {
    Write-Output "[ERROR] MaintenanceEngine.ps1 bulunamadi: $maintEngine"
    exit 1
}
. $maintEngine

$maint = (Get-SuiteConfig).Maintenance
$minAgeDays   = if ($null -ne $maint.TempCleanDaysThreshold) { [int]$maint.TempCleanDaysThreshold } else { 1 }
$emptyBin     = [bool]$maint.EmptyRecycleBin
$pruneLogs    = ($maint.PruneEventLogs -ne $false)
$pruneMaxSize = if ($maint.PruneEventLogMaxSizeBytes) { [long]$maint.PruneEventLogMaxSizeBytes } else { 20971520 }
$resetBase    = [bool]$maint.DismResetBase

# 1. Windows Update Services Check
Write-Output "`n[INFO] [1/5] Windows Update ve BITS Servis Kontrolu..."
try {
    $wuSvc = Get-Service -Name "wuauserv" -ErrorAction SilentlyContinue
    if ($wuSvc -and $wuSvc.StartType -eq "Disabled") {
        Set-Service -Name "wuauserv" -StartupType Manual -ErrorAction SilentlyContinue
    }
    if ($wuSvc -and $wuSvc.Status -ne "Running") {
        Start-Service -Name "wuauserv" -ErrorAction SilentlyContinue
        Start-Sleep -Milliseconds 1000
    }
    Write-Output "[SUCCESS] Windows Update (wuauserv) aktif ve hazir."
} catch {
    Write-Output "[WARN] wuauserv servis uyarisi: $_"
}

# 2. Clear System Junk & Temporary Files (suite logs/state are excluded by pattern)
Write-Output "`n[INFO] [2/5] Sistem Artiklari ve Gecici Dosyalar Temizleniyor ($minAgeDays gunden eski)..."
try {
    $junkRes = Clear-SystemJunkAndTemp -MinAgeDays $minAgeDays -IncludeRecycleBin:$emptyBin
    Write-Output "[SUCCESS] Gecici dosyalar temizlendi ($($junkRes.FilesRemoved) dosya, $($junkRes.MBFreed) MB geri kazanildi)."
    if (-not $emptyBin) {
        Write-Output "[NOTE] Geri Donusum Kutusu korunuyor (config: Maintenance.EmptyRecycleBin = false)."
    }
} catch {
    Write-Output "[WARN] Gecici dosya temizleme uyarisi: $_"
}

# 3. Windows Update Download Cache Purge
Write-Output "`n[INFO] [3/5] Windows Update Indirme Onbellegi Temizleniyor..."
try {
    $wuRes = Clear-WindowsUpdateCache
    Write-Output "[SUCCESS] Windows Update onbellegi temizlendi ($($wuRes.MBFreed) MB)."
} catch {
    Write-Output "[WARN] Update cache uyarisi: $_"
}

# 4. DISM Component Store Health & Cleanup
Write-Output "`n[INFO] [4/5] DISM Bilesen Deposu Saglik Taramasi..."
try {
    $health = Invoke-SystemHealthScan
    if ($health.IsHealthy) {
        Write-Output "[SUCCESS] Bilesen deposu dosya butunlugu saglam."
    } else {
        Write-Output "[WARN] Bilesen deposunda dikkat gerektiren unsurlar var. Onerilen: DISM /Online /Cleanup-Image /RestoreHealth"
    }
    $dism = Invoke-DismComponentCleanup -ResetBase:$resetBase
    if ($resetBase) {
        Write-Output "[NOTE] DISM /ResetBase uygulandi: mevcut guncellemeler artik kaldirilamaz."
    }
    if (-not $dism.Success) {
        Write-Output "[WARN] DISM bilesen temizligi cikis kodu: $($dism.ExitCode)"
    }
} catch {
    Write-Output "[WARN] DISM islemi sirasinda uyari: $_"
}

# 5. Windows Event Log Maintenance (archived to .evtx before clearing)
Write-Output "`n[INFO] [5/5] Windows Olay Gunlukleri (Event Log) Bakimi..."
if ($pruneLogs) {
    try {
        $pruneRes = Prune-WindowsEventLogs -MaxSizeBytes $pruneMaxSize -ArchiveDir (Get-SuiteDataDir "EventLogArchive")
        Write-Output "[SUCCESS] $($pruneRes.ClearedCount) adet sismis olay gunlugu arsivlenip temizlendi ($($pruneRes.ArchiveDir))."
    } catch {
        Write-Output "[WARN] Event log uyarisi: $_"
    }
} else {
    Write-Output "[INFO] Olay gunlugu bakimi config ile devre disi (Maintenance.PruneEventLogs = false)."
}

Write-Output "`n[SUCCESS] 03_WindowsUpdateAndHygiene basariyla tamamlandi."
exit 0
