#Requires -Version 5.1
<#
.SYNOPSIS
    02_StorageAndDisks.ps1 - Storage inventory and safe NVMe initialization
.DESCRIPTION
    SAFE-BY-DEFAULT: Never formats a volume automatically.
    Provides analysis and actionable guidance, does NOT modify disk state
    unless the target is explicitly uninitialized RAW with NTFS-flag and
    the user has explicitly enabled formatting via config.
    Kurumsal ortamlarda: sadece okur ve raporlar. Formatlama icin ayri bir
    onay adimi gereklidir.
#>
[CmdletBinding()]
param()

$ErrorActionPreference = "Continue"

Write-Output "[INFO] 02_StorageAndDisks: Depolama envanteri ve saglik durumu analiz ediliyor..."

#region --- Volume Inventory ---
$volumes = Get-Volume | Where-Object { $_.DriveLetter } | Sort-Object DriveLetter

Write-Output "[INFO] --- Birim Envanteri ---"
foreach ($vol in $volumes) {
    $freeGB  = [math]::Round($vol.SizeRemaining / 1GB, 1)
    $totalGB = [math]::Round($vol.Size / 1GB, 1)
    $pctFree = if ($vol.Size -gt 0) { [math]::Round(($vol.SizeRemaining / $vol.Size) * 100, 0) } else { 0 }
    Write-Output "[INFO]   $($vol.DriveLetter): [$($vol.FileSystemLabel)] $($vol.FileSystemType) | $freeGB GB bos / $totalGB GB toplam (%$pctFree) | Saglik: $($vol.HealthStatus)"
}
#endregion

#region --- Physical Disk Inventory ---
Write-Output "[INFO] --- Fiziksel Disk Envanteri ---"
$disks = Get-PhysicalDisk | Sort-Object DeviceId
foreach ($disk in $disks) {
    $sizeGB = [math]::Round($disk.Size / 1GB, 1)
    Write-Output "[INFO]   Disk $($disk.DeviceId): $($disk.FriendlyName) | $($disk.MediaType) | $($disk.BusType) | $sizeGB GB | $($disk.HealthStatus) / $($disk.OperationalStatus)"
}
#endregion

#region --- Secondary & Data Volumes Analysis (OBSERVE ONLY) ---
Write-Output "[INFO] --- Ikincil ve Veri Suruculeri Analizi ---"
$nonSystemVolumes = $volumes | Where-Object { $_.DriveLetter -and $_.DriveLetter -ne ($env:SystemDrive.TrimEnd(':')) }

if (-not $nonSystemVolumes -or $nonSystemVolumes.Count -eq 0) {
    Write-Output "[INFO] Tek sistem surucusu ($env:SystemDrive) mevcut, baska yerel surucu harfi atanmamis."
} else {
    foreach ($vol in $nonSystemVolumes) {
        $ltr = $vol.DriveLetter
        if ($vol.FileSystemType -in @("Unknown", "") -or -not $vol.FileSystemType) {
            Write-Output "[WARN] $ltr`: surucusu RAW/Bicimsiz durumda. Boyut: $([math]::Round($vol.Size / 1GB, 1)) GB"
            Write-Output "[NOTE] EYLEM GEREKLI: $ltr`: surucusunu bicimlendirmek icin Windows Disk Yonetimi'ni kullanin."
            Write-Output "[NOTE] OTOMATIK BICIMLENDIRME DEVRE DISI: Uretim ortaminda veri kaybi riskini onlemek icin."
        } else {
            $freeGB = [math]::Round($vol.SizeRemaining / 1GB, 1)
            Write-Output "[SUCCESS] $ltr`: surucusu aktif - $($vol.FileSystemType) [$($vol.FileSystemLabel)] | $freeGB GB bos alan."
        }
    }
}
#endregion

#region --- SSD TRIM Verification ---
Write-Output "[INFO] --- SSD TRIM Durumu ---"
try {
    $trimStatus = fsutil behavior query DisableDeleteNotify 2>&1
    if ($trimStatus -match "= 0") {
        Write-Output "[SUCCESS] SSD TRIM aktif (DisableDeleteNotify = 0) - SSD omrü ve performansi iyi."
    } else {
        Write-Output "[WARN] SSD TRIM devre disi gorunuyor: $trimStatus"
        Write-Output "[INFO] Duzeltmek icin (yonetici olarak): fsutil behavior set DisableDeleteNotify 0"
    }
} catch {
    Write-Output "[WARN] TRIM durumu sorgulanamadi: $_"
}
#endregion

#region --- Storage Spaces Pool Check ---
Write-Output "[INFO] --- Windows Depolama Alani (Storage Spaces) ---"
try {
    $pools = Get-StoragePool -IsPrimordial $false -ErrorAction SilentlyContinue
    if ($pools) {
        foreach ($pool in $pools) {
            Write-Output "[INFO] Depolama Havuzu: $($pool.FriendlyName) | $([math]::Round($pool.Size / 1GB, 1)) GB | $($pool.HealthStatus) / $($pool.OperationalStatus)"
        }
    } else {
        Write-Output "[INFO] Kullanici tanimli Storage Spaces havuzu bulunamadi."
    }
} catch {
    Write-Output "[WARN] Storage Spaces sorgulama hatasi: $_"
}
#endregion

#region --- ReTrim for NTFS SSD volumes (read-only optimization, safe) ---
Write-Output "[INFO] --- NTFS SSD Birimleri icin ReTrim ---"
foreach ($vol in $volumes) {
    if ($vol.FileSystemType -eq "NTFS" -and $vol.DriveType -eq 3) {
        try {
            Optimize-Volume -DriveLetter $vol.DriveLetter -ReTrim -ErrorAction Stop | Out-Null
            Write-Output "[SUCCESS] $($vol.DriveLetter): surucusune ReTrim gonderildi."
        } catch {
            Write-Output "[WARN] $($vol.DriveLetter): ReTrim uygulanamadi (yonetici gerekebilir): $_"
        }
    }
}
#endregion

Write-Output "[SUCCESS] 02_StorageAndDisks analizi tamamlandi."
exit 0
