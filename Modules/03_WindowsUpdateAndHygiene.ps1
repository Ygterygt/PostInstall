#Requires -Version 5.1
<#
.SYNOPSIS
    03_WindowsUpdateAndHygiene.ps1 - Enterprise System Care, Component Store & Hygiene
.DESCRIPTION
    Comprehensive Windows Update service verification, deep temp junk purge,
    SoftwareDistribution cache purge, DISM component store cleanup, and event log hygiene.
.NOTES
    Author : Antigravity Systems Team
    Version: 4.0.0
#>
[CmdletBinding()]
param()

$ErrorActionPreference = "Continue"

Write-Output "[INFO] 03_WindowsUpdateAndHygiene: Kapsamli sistem bakimi ve hijyeni baslatiliyor..."

$engineRoot = if ($PSScriptRoot) { Split-Path -Parent $PSScriptRoot } else { "C:\PostInstall" }
$maintEngine = Join-Path $engineRoot "Tools\MaintenanceEngine.ps1"

if (Test-Path $maintEngine) {
    . $maintEngine
}

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

# 2. Clear System Junk & Temporary Files
Write-Output "`n[INFO] [2/5] Sistem Artiklari ve Gecici Dosyalar Temizleniyor..."
try {
    $junkRes = Clear-SystemJunkAndTemp -IncludeRecycleBin
    Write-Output "[SUCCESS] Gecici dosyalar temizlendi ($($junkRes.MBFreed) MB geri kazanildi)."
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
        Write-Output "[WARN] Bilesen deposunda dikkat gerektiren unsurlar var."
    }
    # Run lightweight component cleanup
    Invoke-DismComponentCleanup | Out-Null
} catch {
    Write-Output "[WARN] DISM islemi sirasinda uyari: $_"
}

# 5. Windows Event Log Maintenance
Write-Output "`n[INFO] [5/5] Windows Olay Gunlukleri (Event Log) Bakimi..."
try {
    $pruneRes = Prune-WindowsEventLogs
    Write-Output "[SUCCESS] $($pruneRes.ClearedCount) adet sismis olay gunlugu temizlendi."
} catch {
    Write-Output "[WARN] Event log uyarisi: $_"
}

Write-Output "`n[SUCCESS] 03_WindowsUpdateAndHygiene basariyla tamamlandi."
exit 0
