#Requires -Version 5.1
#Requires -RunAsAdministrator
<#
.SYNOPSIS
    New-TestVM.ps1 - Creates a Windows 11 compatible Hyper-V test VM for end-to-end wizard tests
.DESCRIPTION
    Developer tool (not shipped to end users). Creates a Generation 2 VM with everything Windows 11 setup
    requires: Secure Boot (Microsoft Windows template), a virtual TPM, >= 4 GB RAM, 2+ vCPUs.
    Also enables Guest Services (needed by Copy-SuiteToVM.ps1) and switches checkpoints to "Standard"
    so a checkpoint restores the exact running state, including memory.
.PARAMETER IsoPath
    Windows 11 ISO from https://www.microsoft.com/software-download/windows11
.EXAMPLE
    # From an elevated PowerShell:
    powershell -ExecutionPolicy Bypass -File dev\New-TestVM.ps1 -IsoPath "$env:USERPROFILE\Downloads\Win11_TR_x64.iso"
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$IsoPath,
    [string]$VmName   = "CMP-Test-Win11",
    [string]$Path     = "E:\Hyper-V",
    [int]$MemoryGB    = 4,
    [int]$MaxMemoryGB = 6,
    [int]$CpuCount    = 4,
    [int]$DiskGB      = 80,
    [string]$SwitchName = "Default Switch"
)

$ErrorActionPreference = "Stop"

if (-not (Test-Path -LiteralPath $IsoPath)) { throw "ISO bulunamadi: $IsoPath" }
if (Get-VM -Name $VmName -ErrorAction SilentlyContinue) { throw "'$VmName' adli sanal makine zaten var. Farkli -VmName verin veya once silin." }
if (-not (Get-VMSwitch -Name $SwitchName -ErrorAction SilentlyContinue)) {
    throw "'$SwitchName' sanal anahtari yok. Hyper-V Yoneticisi > Sanal Anahtar Yoneticisi'nden bir 'Harici' veya 'NAT' anahtari olusturup -SwitchName ile verin."
}

$vmDir   = Join-Path $Path $VmName
$vhdPath = Join-Path $vmDir "$VmName.vhdx"
New-Item -Path $vmDir -ItemType Directory -Force | Out-Null

Write-Host "[INFO] Sanal makine olusturuluyor: $VmName ($CpuCount vCPU, $MemoryGB-$MaxMemoryGB GB RAM, $DiskGB GB disk) -> $vmDir"
New-VM -Name $VmName -Generation 2 -Path $Path -MemoryStartupBytes ($MemoryGB * 1GB) `
       -NewVHDPath $vhdPath -NewVHDSizeBytes ($DiskGB * 1GB) -SwitchName $SwitchName | Out-Null

Set-VMProcessor -VMName $VmName -Count $CpuCount
# Windows 11 setup checks for 4 GB: keep the startup value at 4 GB, allow growth for heavy installers
Set-VMMemory -VMName $VmName -DynamicMemoryEnabled $true -MinimumBytes ($MemoryGB * 1GB) `
             -StartupBytes ($MemoryGB * 1GB) -MaximumBytes ($MaxMemoryGB * 1GB)

# Windows 11 requirements: Secure Boot with the Microsoft Windows template + TPM 2.0
Set-VMFirmware -VMName $VmName -EnableSecureBoot On -SecureBootTemplate "MicrosoftWindows"
Set-VMKeyProtector -VMName $VmName -NewLocalKeyProtector
Enable-VMTPM -VMName $VmName

$dvd = Add-VMDvdDrive -VMName $VmName -Path $IsoPath -Passthru
Set-VMFirmware -VMName $VmName -FirstBootDevice $dvd

# Copy-VMFile needs Guest Services; Standard checkpoints capture memory (exact "before test" state)
# Service names are localized ("Konuk Hizmeti Arabirimi" on Turkish Windows): match by the fixed component id
Get-VMIntegrationService -VMName $VmName |
    Where-Object { $_.Id -like "*6C09BB55-D683-4DA0-8931-C9BF705F6480" } |
    Enable-VMIntegrationService
Set-VM -Name $VmName -CheckpointType Standard -AutomaticCheckpointsEnabled $false -EnhancedSessionTransportType HvSocket

Write-Host "[SUCCESS] '$VmName' hazir." -ForegroundColor Green
Write-Host @"

Sonraki adimlar:
  1. Hyper-V Yoneticisi'nde '$VmName' > Baglan > Baslat.
     'Press any key to boot from CD or DVD' yazisi cikinca hemen bir tusa basin.
  2. Windows 11'i kurun (urun anahtari: 'Urun anahtarim yok'; surum: Windows 11 Pro).
     Yerel hesapla kurmak isterseniz ag adiminda 'Internetim yok' secenegini kullanabilirsiniz.
  3. Kurulum bitince VM icinde Windows Update'i bir kez calistirmaniz ONERILMEZ; test 'ilk kurulum' durumunu hedefler.
  4. Temiz durumu kaydedin (VM acikken, masaustundayken):
       Checkpoint-VM -Name '$VmName' -SnapshotName 'Temiz Windows'
  5. Paketi VM'e kopyalayin:
       powershell -ExecutionPolicy Bypass -File dev\Copy-SuiteToVM.ps1 -VmName '$VmName'
"@
