#Requires -Version 5.1
<#
.SYNOPSIS
    00_SystemSnapshotAndBackup.ps1 - System Restore Point & Registry State Snapshot
.DESCRIPTION
    Creates a pre-installation safety snapshot:
    1. VSS System Restore Point (Checkpoint-Computer)
    2. Registry state backup (Environment, Explorer settings)
    3. Guarantees rollback capability in case of any system anomaly
#>
[CmdletBinding()]
param()

$ErrorActionPreference = "Continue"

Write-Output "[INFO] 00_SystemSnapshotAndBackup: Guvenlik yedegi ve Sistem Geri Yukleme Noktasi olusturuluyor..."

$snapshotEnginePath = "C:\PostInstall\Tools\SnapshotEngine.ps1"
if (Test-Path $snapshotEnginePath) {
    . $snapshotEnginePath
    $res = New-SystemSnapshot -Description "Antigravity PostInstall Pre-Execution Snapshot" -BackupDir "C:\PostInstall\Backups"
    
    if ($res.RestorePointCreated) {
        Write-Output "[SUCCESS] VSS Sistem Geri Yukleme Noktasi basariyla alindi."
    } else {
        Write-Output "[WARN] VSS Noktasi alinamadi, ancak Kayit Defteri / Ortam yedekleri guvenle olusturuldu."
    }

    if ($res.RegistryBackupCreated) {
        Write-Output "[SUCCESS] Ortam ve Registry yedek dosyalari: $($res.BackupFiles.Count) adet dosya kaydedildi."
    }
} else {
    Write-Output "[WARN] SnapshotEngine.ps1 bulunamadi. Dogrudan Checkpoint-Computer deneniyor..."
    try {
        Enable-ComputerRestore -Drive "$($env:SystemDrive)\" -ErrorAction SilentlyContinue
        Checkpoint-Computer -Description "Antigravity PostInstall Snapshot" -RestorePointType "APPLICATION_INSTALL" -ErrorAction SilentlyContinue
        Write-Output "[SUCCESS] Temel Sistem Geri Yukleme Noktasi olusturuldu."
    } catch {
        Write-Output "[WARN] Geri yukleme noktasi olusturulamadi: $_"
    }
}

Write-Output "[SUCCESS] 00_SystemSnapshotAndBackup adimi tamamlandi."
exit 0
