#Requires -Version 5.1
<#
.SYNOPSIS
    SchedulerEngine.ps1 - Scheduled (unattended) maintenance via Windows Task Scheduler
.DESCRIPTION
    - Settings: defaults from config.json -> ScheduledMaintenance, user choices persisted in
      %ProgramData%\ComputerMaintenancePro\State\ScheduledMaintenance.json (the repo file stays untouched)
    - Register-MaintenanceTask / Unregister-MaintenanceTask / Get-MaintenanceTaskStatus
    The task runs Tools\Invoke-ScheduledMaintenance.ps1 as the signed-in user with highest privileges:
    winget and the user's %TEMP% do not work correctly under the SYSTEM account.
.NOTES
    Inspired by Winget-AutoUpdate (see docs/ROADMAP.md, CMP-23).
#>

. (Join-Path $PSScriptRoot "Common.ps1")

$Script:MaintenanceTaskPath = "\ComputerMaintenancePro\"
$Script:ValidDays = @("Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Sunday")

function Get-ScheduledMaintenanceSettingsPath {
    return (Join-Path (Get-SuiteDataDir "State") "ScheduledMaintenance.json")
}

function Get-ScheduledMaintenanceSettings {
    <#
    .SYNOPSIS
        Effective settings = built-in defaults <- config.json ScheduledMaintenance <- saved user choices.
    #>
    param([string]$Path = (Get-ScheduledMaintenanceSettingsPath))

    $settings = [ordered]@{
        TaskName   = "ComputerMaintenancePro_Weekly"
        DayOfWeek  = "Sunday"
        Time       = "12:00"
        CleanTemp  = $true
        FlushDns   = $true
        ReTrim     = $true
        UpdateApps = $false
    }

    $layers = @()
    try { $layers += (Get-SuiteConfig).ScheduledMaintenance } catch {}
    if (Test-Path -LiteralPath $Path) {
        try { $layers += (Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json) } catch {}
    }
    foreach ($layer in $layers) {
        if (-not $layer) { continue }
        foreach ($key in @($settings.Keys)) {
            if ($layer.PSObject.Properties.Name -contains $key -and $null -ne $layer.$key) { $settings[$key] = $layer.$key }
        }
    }
    return [PSCustomObject]$settings
}

function Save-ScheduledMaintenanceSettings {
    param(
        [Parameter(Mandatory)]$Settings,
        [string]$Path = (Get-ScheduledMaintenanceSettingsPath)
    )
    Assert-ScheduledMaintenanceSettings -Settings $Settings
    $dir = Split-Path -Parent $Path
    if (-not (Test-Path $dir)) { New-Item -Path $dir -ItemType Directory -Force | Out-Null }
    $Settings | ConvertTo-Json -Depth 3 | Set-Content -LiteralPath $Path -Encoding UTF8
}

function Assert-ScheduledMaintenanceSettings {
    param([Parameter(Mandatory)]$Settings)
    if ($Script:ValidDays -notcontains $Settings.DayOfWeek) { throw "Gecersiz gun: $($Settings.DayOfWeek)" }
    if ($Settings.Time -notmatch '^([01]\d|2[0-3]):[0-5]\d$') { throw "Gecersiz saat (SS:dd bekleniyor): $($Settings.Time)" }
    if (-not ($Settings.CleanTemp -or $Settings.FlushDns -or $Settings.ReTrim -or $Settings.UpdateApps)) {
        throw "En az bir bakim islemi secilmelidir."
    }
}

function New-MaintenanceTaskDefinition {
    <#
    .SYNOPSIS
        Builds (does not register) the task pieces. Pure enough to unit test without admin rights.
    #>
    param([Parameter(Mandatory)]$Settings)

    Assert-ScheduledMaintenanceSettings -Settings $Settings
    $runner = Join-Path (Get-SuiteRoot) "Tools\Invoke-ScheduledMaintenance.ps1"
    $ps     = Join-Path $env:SystemRoot "System32\WindowsPowerShell\v1.0\powershell.exe"

    $action  = New-ScheduledTaskAction -Execute $ps -Argument "-NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$runner`""
    # New-ScheduledTaskTrigger (PS 5.1) always stores StartBoundary as UTC ("...Z"), which drifts by an
    # hour across daylight-saving changes. A boundary WITHOUT offset is interpreted as local time.
    $hm = $Settings.Time -split ":"
    $at = (Get-Date).Date.AddHours([int]$hm[0]).AddMinutes([int]$hm[1])
    $trigger = New-ScheduledTaskTrigger -Weekly -DaysOfWeek $Settings.DayOfWeek -At $at
    $trigger.StartBoundary = $at.ToString("yyyy-MM-dd'T'HH:mm:ss")
    # Defaults keep laptops safe: no start on battery, stop when unplugged. StartWhenAvailable catches up
    # after the PC was off at the scheduled time; IgnoreNew prevents overlapping runs.
    $taskSettings = New-ScheduledTaskSettingsSet -StartWhenAvailable -MultipleInstances IgnoreNew `
                        -ExecutionTimeLimit (New-TimeSpan -Hours 2)
    $principal = New-ScheduledTaskPrincipal -UserId ([System.Security.Principal.WindowsIdentity]::GetCurrent().Name) `
                        -LogonType Interactive -RunLevel Highest

    return [PSCustomObject]@{
        Action    = $action
        Trigger   = $trigger
        Settings  = $taskSettings
        Principal = $principal
        Runner    = $runner
    }
}

function Register-MaintenanceTask {
    param([Parameter(Mandatory)]$Settings)
    $def = New-MaintenanceTaskDefinition -Settings $Settings
    $task = Register-ScheduledTask -TaskName $Settings.TaskName -TaskPath $Script:MaintenanceTaskPath `
                -Action $def.Action -Trigger $def.Trigger -Settings $def.Settings -Principal $def.Principal `
                -Description "Computer Maintenance Pro - zamanlanmis bakim (temp, DNS, TRIM, uygulama guncellemeleri)" -Force
    return $task
}

function Unregister-MaintenanceTask {
    param([string]$TaskName = (Get-ScheduledMaintenanceSettings).TaskName)
    if (Get-ScheduledTask -TaskName $TaskName -TaskPath $Script:MaintenanceTaskPath -ErrorAction SilentlyContinue) {
        Unregister-ScheduledTask -TaskName $TaskName -TaskPath $Script:MaintenanceTaskPath -Confirm:$false
        return $true
    }
    return $false
}

function Start-MaintenanceTaskNow {
    param([string]$TaskName = (Get-ScheduledMaintenanceSettings).TaskName)
    Start-ScheduledTask -TaskName $TaskName -TaskPath $Script:MaintenanceTaskPath
}

function Get-MaintenanceTaskStatus {
    param([string]$TaskName = (Get-ScheduledMaintenanceSettings).TaskName)

    $task = Get-ScheduledTask -TaskName $TaskName -TaskPath $Script:MaintenanceTaskPath -ErrorAction SilentlyContinue
    if (-not $task) { return [PSCustomObject]@{ Registered = $false } }
    $info = Get-ScheduledTaskInfo -TaskName $TaskName -TaskPath $Script:MaintenanceTaskPath -ErrorAction SilentlyContinue

    $lastSummary = $null
    $summaryPath = Join-Path (Get-SuiteDataDir "Reports") "LastScheduledMaintenance.json"
    if (Test-Path $summaryPath) { try { $lastSummary = Get-Content $summaryPath -Raw -Encoding UTF8 | ConvertFrom-Json } catch {} }

    # 267011 = SCHED_S_TASK_HAS_NOT_RUN
    $neverRun = (-not $info) -or ($info.LastTaskResult -eq 267011) -or ($info.LastRunTime -lt [datetime]"2000-01-01")
    return [PSCustomObject]@{
        Registered     = $true
        State          = [string]$task.State
        NextRunTime    = if ($info) { $info.NextRunTime } else { $null }
        LastRunTime    = if ($neverRun) { $null } else { $info.LastRunTime }
        LastTaskResult = if ($neverRun) { $null } else { $info.LastTaskResult }
        LastSummary    = $lastSummary
    }
}
