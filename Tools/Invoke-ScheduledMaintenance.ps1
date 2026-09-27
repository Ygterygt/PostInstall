#Requires -Version 5.1
<#
.SYNOPSIS
    Invoke-ScheduledMaintenance.ps1 - Unattended maintenance run (started by Task Scheduler)
.DESCRIPTION
    Runs the actions enabled in the scheduled-maintenance settings:
      CleanTemp  : temp/WER/crash dumps older than Maintenance.TempCleanDaysThreshold (Recycle Bin untouched)
      FlushDns   : DNS resolver cache
      ReTrim     : SSD/NVMe ReTrim
      UpdateApps : winget upgrades, honouring Updates.ExcludeIds
    Writes Logs\ScheduledMaintenance.log and Reports\LastScheduledMaintenance.json.
    Skips entirely while the installation wizard/engine is running.
.PARAMETER DryRun
    Only reports what would run (used by tests); changes nothing.
#>
[CmdletBinding()]
param(
    [switch]$DryRun,
    [string]$SettingsPath = ""
)

$ErrorActionPreference = "Continue"
$toolsDir = $PSScriptRoot
. (Join-Path $toolsDir "SchedulerEngine.ps1")

if (-not $SettingsPath) { $SettingsPath = Get-ScheduledMaintenanceSettingsPath }
$logFile     = Join-Path (Get-SuiteDataDir "Logs") "ScheduledMaintenance.log"
$summaryFile = Join-Path (Get-SuiteDataDir "Reports") "LastScheduledMaintenance.json"

function Write-SchedLog {
    param([string]$Message)
    $line = "[{0}] {1}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $Message
    Write-Output $line
    if (-not $DryRun) {
        try { [System.IO.File]::AppendAllText($logFile, "$line`r`n", (New-Object System.Text.UTF8Encoding($false))) } catch {}
    }
}

function Invoke-LoggedAction {
    # Runs an action and forwards every stream (incl. Write-Host of the engines) into the log
    param([string]$Name, [scriptblock]$Action)
    Write-SchedLog "[INFO] >> $Name"
    try {
        & $Action *>&1 | ForEach-Object { $t = "$_".Trim(); if ($t) { Write-SchedLog "   $t" } }
        return [PSCustomObject]@{ Action = $Name; Success = $true; Error = $null }
    } catch {
        Write-SchedLog "[ERROR] $Name : $($_.Exception.Message)"
        return [PSCustomObject]@{ Action = $Name; Success = $false; Error = $_.Exception.Message }
    }
}

$settings = Get-ScheduledMaintenanceSettings -Path $SettingsPath
$planned = @()
if ($settings.CleanTemp)  { $planned += "CleanTemp" }
if ($settings.FlushDns)   { $planned += "FlushDns" }
if ($settings.ReTrim)     { $planned += "ReTrim" }
if ($settings.UpdateApps) { $planned += "UpdateApps" }

Write-SchedLog "[INFO] Zamanlanmis bakim basladi (Kullanici: $env:USERNAME, Plan: $($planned -join ', '), DryRun: $([bool]$DryRun))"

if ($DryRun) {
    Write-SchedLog "[INFO] PLAN=$($planned -join ',')"
    exit 0
}

# Never compete with the installation engine (installers, reboots, DISM...)
try {
    $state = Get-Content -LiteralPath (Get-SuiteConfig).StateFile -Raw -ErrorAction Stop | ConvertFrom-Json
    if ($state.Status -in @("Running", "RebootPending")) {
        Write-SchedLog "[WARN] Kurulum sihirbazi calisiyor / reboot bekliyor ($($state.Status)). Bakim atlandi."
        exit 0
    }
} catch {}

$cfg = Get-SuiteConfig
$results = @()

if ($settings.CleanTemp) {
    . (Join-Path $toolsDir "MaintenanceEngine.ps1")
    $minAge = if ($null -ne $cfg.Maintenance.TempCleanDaysThreshold) { [int]$cfg.Maintenance.TempCleanDaysThreshold } else { 1 }
    $results += Invoke-LoggedAction "Gecici dosya temizligi ($minAge gunden eski)" { Clear-SystemJunkAndTemp -MinAgeDays $minAge | Out-Null }
}

if ($settings.FlushDns) {
    $results += Invoke-LoggedAction "DNS onbellegi temizligi" { Clear-DnsClientCache -ErrorAction Stop; "DNS onbellegi temizlendi." }
}

if ($settings.ReTrim) {
    if (-not (Get-Command Optimize-StorageDrives -ErrorAction SilentlyContinue)) { . (Join-Path $toolsDir "MaintenanceEngine.ps1") }
    $results += Invoke-LoggedAction "SSD ReTrim" { Optimize-StorageDrives | ForEach-Object { "$($_.Drive) $($_.Status)" } }
}

if ($settings.UpdateApps) {
    . (Join-Path $toolsDir "UpdateEngine.ps1")
    $exclude = if ($cfg.Updates -and $cfg.Updates.ExcludeIds) { @($cfg.Updates.ExcludeIds) } else { @() }
    $results += Invoke-LoggedAction "Uygulama guncellemeleri (winget)" {
        $updates = @(Get-AvailableAppUpdates -ExcludeIds $exclude | Where-Object { -not $_.Excluded })
        "$($updates.Count) guncelleme bulundu."
        foreach ($u in $updates) {
            $r = Update-AppPackage -Id $u.Id -Source $u.Source
            $tag = if ($r.Success) { "[SUCCESS]" } else { "[WARN]" }
            "$tag $($u.Name) $($u.Version) -> $($u.Available): $($r.Details)"
        }
    }
}

$failed = @($results | Where-Object { -not $_.Success })
[PSCustomObject]@{
    FinishedAt = (Get-Date -Format "o")
    User       = $env:USERNAME
    Actions    = $results
    Success    = ($failed.Count -eq 0)
} | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $summaryFile -Encoding UTF8

Write-SchedLog "[INFO] Zamanlanmis bakim bitti. Basarili: $($results.Count - $failed.Count) / $($results.Count)"
exit $failed.Count
