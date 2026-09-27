#Requires -Version 5.1
#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Copy-SuiteToVM.ps1 - Copies the suite from this repo into a running Hyper-V test VM
.DESCRIPTION
    Developer tool (not shipped). Uses Copy-VMFile (Guest Services, enabled by New-TestVM.ps1), so no
    network share or credentials are needed. The VM must be running and signed in.
    Skipped: .git, dev\, TestResults.json and - unless -IncludeInstallers - the (large) Installers\ binaries.
.EXAMPLE
    powershell -ExecutionPolicy Bypass -File dev\Copy-SuiteToVM.ps1 -VmName CMP-Test-Win11 -IncludeInstallers
#>
[CmdletBinding()]
param(
    [string]$VmName = "CMP-Test-Win11",
    [string]$Destination = "C:\PostInstall",
    [switch]$IncludeInstallers
)

$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSScriptRoot

$vm = Get-VM -Name $VmName -ErrorAction Stop
if ($vm.State -ne "Running") { throw "'$VmName' calismiyor. Once VM'i baslatip Windows'a giris yapin." }
$gs = Get-VMIntegrationService -VMName $VmName -Name "Guest Service Interface"
if (-not $gs.Enabled) { Enable-VMIntegrationService -VMName $VmName -Name "Guest Service Interface" }

$files = Get-ChildItem -LiteralPath $root -Recurse -File | Where-Object {
    $rel = $_.FullName.Substring($root.Length).TrimStart('\')
    -not ($rel -match '^(\.git|dev)\\' -or $rel -eq 'TestResults.json' -or
          (-not $IncludeInstallers -and $rel -match '^Installers\\' -and $_.Name -notin @('README.md', '.gitkeep')))
}

$total = ($files | Measure-Object Length -Sum).Sum
Write-Host ("[INFO] {0} dosya ({1:N1} MB) '{2}' icindeki {3} klasorune kopyalaniyor..." -f $files.Count, ($total / 1MB), $VmName, $Destination)

$i = 0
foreach ($f in $files) {
    $i++
    $rel = $f.FullName.Substring($root.Length).TrimStart('\')
    Write-Progress -Activity "VM'e kopyalaniyor" -Status $rel -PercentComplete ([int](100 * $i / $files.Count))
    Copy-VMFile -Name $VmName -SourcePath $f.FullName -DestinationPath (Join-Path $Destination $rel) `
                -CreateFullPath -FileSource Host -Force
}
Write-Progress -Activity "VM'e kopyalaniyor" -Completed
Write-Host "[SUCCESS] Kopyalama tamamlandi. VM icinde calistirin: $Destination\PostInstall.exe" -ForegroundColor Green
