#Requires -Version 5.1
<#
.SYNOPSIS
    Common.ps1 - Shared helpers for engine, modules, tools and UI
.DESCRIPTION
    Single source of truth for:
      - Suite root resolution (portable: works from C:\, D:\ or USB)
      - config.json loading with environment variable expansion
      - RAM speed normalization (WMI MHz vs MT/s reporting)
      - REG_EXPAND_SZ-safe PATH manipulation
      - WM_SETTINGCHANGE environment broadcast
    Safe to dot-source multiple times.
#>

$Script:SuiteRoot = Split-Path -Parent $PSScriptRoot

function Get-SuiteRoot {
    return $Script:SuiteRoot
}

function Get-SuiteConfig {
    <#
    .SYNOPSIS
        Loads config.json and returns it with runtime paths expanded.
    #>
    [CmdletBinding()]
    param([string]$ConfigPath = (Join-Path $Script:SuiteRoot "config.json"))

    $cfg = [System.IO.File]::ReadAllText($ConfigPath, [System.Text.Encoding]::UTF8) | ConvertFrom-Json
    foreach ($key in @("LogFile", "ErrorLogFile", "StateFile", "SummaryReport", "DocsSyncPath")) {
        if ($cfg.PSObject.Properties.Name -contains $key -and $cfg.$key) {
            $cfg.$key = [System.Environment]::ExpandEnvironmentVariables($cfg.$key)
        }
    }
    return $cfg
}

function Get-SuiteDataDir {
    <#
    .SYNOPSIS
        Returns (and creates) a runtime sub directory next to the state file, e.g. Reports, Backups.
    #>
    param([Parameter(Mandatory)][string]$Name)
    $base = $null
    try { $base = Split-Path -Parent (Split-Path -Parent (Get-SuiteConfig).StateFile) } catch {}
    if (-not $base) { $base = Join-Path $env:ProgramData "ComputerMaintenancePro" }
    $dir = Join-Path $base $Name
    if (-not (Test-Path $dir)) { New-Item -Path $dir -ItemType Directory -Force | Out-Null }
    return $dir
}

function ConvertTo-MemorySpeedInfo {
    <#
    .SYNOPSIS
        Normalizes Win32_PhysicalMemory Speed / ConfiguredClockSpeed into MT/s.
    .DESCRIPTION
        Speed is the module's rated (SPD/JEDEC) data rate in MT/s. Modern Windows reports
        ConfiguredClockSpeed in MT/s as well; some older firmware reports it as the real
        clock (MHz = MT/s / 2). Only in the latter case is the value doubled.
    #>
    param(
        [int]$RatedSpeed,
        [int]$ConfiguredClockSpeed
    )

    $actual = $ConfiguredClockSpeed
    if ($actual -le 0) { $actual = $RatedSpeed }
    elseif ($RatedSpeed -gt 0 -and ($actual * 1.5) -lt $RatedSpeed -and ($actual * 2) -le ($RatedSpeed * 1.1)) {
        $actual = $actual * 2
    }
    $rated = if ($RatedSpeed -gt 0) { $RatedSpeed } else { $actual }

    return [PSCustomObject]@{
        ActualMTs       = [int]$actual
        RatedMTs        = [int]$rated
        BelowRatedSpeed = ($rated -gt 0 -and $actual -gt 0 -and $actual -lt ($rated * 0.95))
    }
}

function Get-MemorySpeedInfo {
    $stick = Get-CimInstance Win32_PhysicalMemory -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $stick) { return (ConvertTo-MemorySpeedInfo -RatedSpeed 0 -ConfiguredClockSpeed 0) }
    return (ConvertTo-MemorySpeedInfo -RatedSpeed ([int]$stick.Speed) -ConfiguredClockSpeed ([int]$stick.ConfiguredClockSpeed))
}

#region --- PATH (REG_EXPAND_SZ safe) ---
$Script:PathRegistryKeys = @{
    Machine = "HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Environment"
    User    = "HKCU:\Environment"
}

function Get-RawPathValue {
    <#
    .SYNOPSIS
        Reads PATH without expanding %VARIABLES% (unlike [Environment]::GetEnvironmentVariable).
    #>
    param([ValidateSet("Machine", "User")][string]$Scope = "Machine")
    $key = Get-Item -LiteralPath $Script:PathRegistryKeys[$Scope] -ErrorAction SilentlyContinue
    if (-not $key) { return "" }
    return [string]$key.GetValue("Path", "", [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
}

function Merge-PathEntries {
    <#
    .SYNOPSIS
        Pure function: appends entries to a raw PATH string, de-duplicating on the expanded,
        case-insensitive, trailing-slash-insensitive form. Existing entries keep their raw form.
    #>
    param(
        [string]$RawPath,
        [string[]]$Entries
    )

    $normalize = { param($p) ([System.Environment]::ExpandEnvironmentVariables($p.Trim())).TrimEnd('\').ToLowerInvariant() }

    $result = New-Object System.Collections.Generic.List[string]
    $seen   = New-Object 'System.Collections.Generic.HashSet[string]'
    foreach ($p in ($RawPath -split ";")) {
        if ([string]::IsNullOrWhiteSpace($p)) { continue }
        if ($seen.Add((& $normalize $p))) { $result.Add($p.Trim()) }
    }

    $added = @()
    foreach ($e in $Entries) {
        if ([string]::IsNullOrWhiteSpace($e)) { continue }
        if ($seen.Add((& $normalize $e))) { $result.Add($e.Trim()); $added += $e.Trim() }
    }

    return [PSCustomObject]@{
        Value = ($result -join ";")
        Added = $added
    }
}

function Set-RawPathValue {
    param(
        [ValidateSet("Machine", "User")][string]$Scope = "Machine",
        [Parameter(Mandatory)][string]$Value
    )
    Set-ItemProperty -LiteralPath $Script:PathRegistryKeys[$Scope] -Name "Path" -Value $Value -Type ExpandString -Force
}

function Send-EnvironmentChange {
    <#
    .SYNOPSIS
        Broadcasts WM_SETTINGCHANGE("Environment") so Explorer and new processes pick up changes.
    #>
    if (-not ("CmpNative.EnvBroadcast" -as [type])) {
        Add-Type -Namespace CmpNative -Name EnvBroadcast -MemberDefinition @"
[System.Runtime.InteropServices.DllImport("user32.dll", SetLastError = true, CharSet = System.Runtime.InteropServices.CharSet.Auto)]
public static extern System.IntPtr SendMessageTimeout(System.IntPtr hWnd, uint Msg, System.UIntPtr wParam, string lParam, uint fuFlags, uint uTimeout, out System.UIntPtr lpdwResult);
"@
    }
    $result = [System.UIntPtr]::Zero
    [void][CmpNative.EnvBroadcast]::SendMessageTimeout([System.IntPtr]0xffff, 0x1a, [System.UIntPtr]::Zero, "Environment", 2, 5000, [ref]$result)
}

function Update-SessionPath {
    $m = [Environment]::GetEnvironmentVariable("Path", [EnvironmentVariableTarget]::Machine)
    $u = [Environment]::GetEnvironmentVariable("Path", [EnvironmentVariableTarget]::User)
    $env:Path = "$m;$u"
}
#endregion
