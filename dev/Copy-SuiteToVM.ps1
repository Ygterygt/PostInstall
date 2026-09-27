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
# Service names are localized ("Konuk Hizmeti Arabirimi" on Turkish Windows): match by the fixed component id
$gs = Get-VMIntegrationService -VMName $VmName | Where-Object { $_.Id -like "*6C09BB55-D683-4DA0-8931-C9BF705F6480" }
if (-not $gs) { throw "Konuk Hizmeti Arabirimi (Guest Services) bulunamadi." }
if (-not $gs.Enabled) { $gs | Enable-VMIntegrationService; Start-Sleep -Seconds 5 }

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
