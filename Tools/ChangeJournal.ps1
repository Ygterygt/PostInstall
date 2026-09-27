#Requires -Version 5.1
<#
.SYNOPSIS
    ChangeJournal.ps1 - Records every system setting the suite changes, so it can be undone (CMP-25)
.DESCRIPTION
    Modules call Set-Tracked* helpers instead of writing settings directly. Each helper reads the
    PREVIOUS value, applies the new one and appends an entry to State\ChangeJournal.json - but only
    when the value really changed. Undo-ChangeJournalEntry restores the previous value per kind.

    Kinds: Registry, Service, PowerPlan, PowerSetting, Trim, NetTcp, Dns, MpPreference, Feature
    Entries created with -NotUndoable (e.g. re-disabling UAC, re-enabling SMBv1) are listed but never
    reverted, because the undo would lower the security baseline.
.NOTES
    Inspired by Win11Debloat / Sophia Script (each tweak has a revert). Journal path can be redirected
    with $env:CMP_CHANGE_JOURNAL (used by tests).
#>

. (Join-Path $PSScriptRoot "Common.ps1")

function Get-ChangeJournalPath {
    if ($env:CMP_CHANGE_JOURNAL) { return $env:CMP_CHANGE_JOURNAL }
    return (Join-Path (Get-SuiteDataDir "State") "ChangeJournal.json")
}

function Get-ChangeJournal {
    $path = Get-ChangeJournalPath
    if (-not (Test-Path -LiteralPath $path)) { return @() }
    try {
        $raw = Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json
        return @($raw)   # PS 5.1: assign first, then wrap (AGENTS.md pitfall 2)
    } catch {
        return @()
    }
}

function Save-ChangeJournal {
    param([object[]]$Entries)
    $path = Get-ChangeJournalPath
    $dir = Split-Path -Parent $path
    if (-not (Test-Path $dir)) { New-Item -Path $dir -ItemType Directory -Force | Out-Null }
    $json = ConvertTo-Json -InputObject @($Entries) -Depth 6
    $tmp = "$path.tmp"
    [System.IO.File]::WriteAllText($tmp, $json, (New-Object System.Text.UTF8Encoding($false)))
    Move-Item -LiteralPath $tmp -Destination $path -Force
}

function Add-ChangeJournalEntry {
    param(
        [Parameter(Mandatory)][string]$Kind,
        [Parameter(Mandatory)][string]$Target,
        [string]$Name = "",
        $PreviousValue = $null,
        [bool]$PreviousExists = $true,
        [string]$PreviousType = "",
        $NewValue = $null,
        [string]$Module = $(if ($MyInvocation.PSCommandPath) { [System.IO.Path]::GetFileNameWithoutExtension($MyInvocation.PSCommandPath) } else { "Manual" }),
        [string]$Description = "",
        [switch]$NotUndoable,
        [string]$Note = ""
    )
    $entry = [PSCustomObject]@{
        Id             = [guid]::NewGuid().ToString()
        Timestamp      = (Get-Date -Format "o")
        Module         = $Module
        Kind           = $Kind
        Target         = $Target
        Name           = $Name
        PreviousValue  = $PreviousValue
        PreviousExists = $PreviousExists
        PreviousType   = $PreviousType
        NewValue       = $NewValue
        Description    = $Description
        Undoable       = (-not $NotUndoable)
        Note           = $Note
        Reverted       = $false
        RevertedAt     = $null
    }
    $all = @(Get-ChangeJournal) + $entry
    Save-ChangeJournal -Entries $all
    return $entry
}

function Test-ValueEqual {
    param($A, $B)
    if ($null -eq $A -and $null -eq $B) { return $true }
    if ($null -eq $A -or $null -eq $B) { return $false }
    return ("$A" -eq "$B")
}

#region --- Tracked setters ---

function Set-TrackedRegistryValue {
    <#
    .SYNOPSIS
        Writes a registry value and journals the previous value (or its absence).
    #>
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)]$Value,
        [ValidateSet("DWord", "QWord", "String", "ExpandString", "MultiString", "Binary")][string]$Type = "DWord",
        [string]$Description = "",
        [switch]$NotUndoable,
        [string]$Note = "",
        [string]$Module = $(if ($MyInvocation.PSCommandPath) { [System.IO.Path]::GetFileNameWithoutExtension($MyInvocation.PSCommandPath) } else { "Manual" })
    )

    $prevExists = $false; $prev = $null; $prevType = ""
    if (Test-Path -LiteralPath $Path) {
        $key = Get-Item -LiteralPath $Path
        if ($key.GetValueNames() -contains $Name) {
            $prevExists = $true
            $prev = $key.GetValue($Name, $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
            $prevType = [string]$key.GetValueKind($Name)
        }
    } else {
        New-Item -Path $Path -Force | Out-Null
    }

    if ($prevExists -and (Test-ValueEqual $prev $Value)) { return $null }   # already in the desired state

    Set-ItemProperty -LiteralPath $Path -Name $Name -Value $Value -Type $Type -Force
    return (Add-ChangeJournalEntry -Kind "Registry" -Target $Path -Name $Name -PreviousValue $prev -PreviousExists $prevExists `
                -PreviousType $prevType -NewValue $Value -Module $Module -Description $Description -NotUndoable:$NotUndoable -Note $Note)
}

function Set-TrackedServiceStartType {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][ValidateSet("Automatic", "Manual", "Disabled")][string]$StartType,
        [string]$Description = "",
        [string]$Module = $(if ($MyInvocation.PSCommandPath) { [System.IO.Path]::GetFileNameWithoutExtension($MyInvocation.PSCommandPath) } else { "Manual" })
    )
    $svc = Get-Service -Name $Name -ErrorAction Stop
    $prev = [string]$svc.StartType
    if ($prev -eq $StartType) { return $null }
    Set-Service -Name $Name -StartupType $StartType -ErrorAction Stop
    return (Add-ChangeJournalEntry -Kind "Service" -Target $Name -PreviousValue $prev -NewValue $StartType -Module $Module -Description $Description)
}

function Get-ActivePowerPlanGuid {
    $out = (powercfg /getactivescheme 2>&1) -join " "
    if ($out -match '([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})') { return $Matches[1] }
    return $null
}

function Set-TrackedPowerPlan {
    param(
        [Parameter(Mandatory)][string]$Guid,
        [string]$Description = "",
        [string]$Module = $(if ($MyInvocation.PSCommandPath) { [System.IO.Path]::GetFileNameWithoutExtension($MyInvocation.PSCommandPath) } else { "Manual" })
    )
    $prev = Get-ActivePowerPlanGuid
    if ($prev -eq $Guid) { return $null }
    powercfg /setactive $Guid 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "powercfg /setactive $Guid basarisiz (kod $LASTEXITCODE)" }
    return (Add-ChangeJournalEntry -Kind "PowerPlan" -Target "ActiveScheme" -PreviousValue $prev -NewValue $Guid -Module $Module -Description $Description)
}

$Script:PowerSettingMap = @{
    "monitor"   = @{ Sub = "SUB_VIDEO"; Setting = "VIDEOIDLE" }
    "standby"   = @{ Sub = "SUB_SLEEP"; Setting = "STANDBYIDLE" }
    "hibernate" = @{ Sub = "SUB_SLEEP"; Setting = "HIBERNATEIDLE" }
}

function Get-PowerSettingSeconds {
    <#
    .SYNOPSIS
        Current AC/DC index (seconds) of a power setting on the active scheme. Output labels are
        localized, so only the two hex values (AC first, then DC) are parsed.
    #>
    param([Parameter(Mandatory)][ValidateSet("monitor", "standby", "hibernate")][string]$Setting)
    $m = $Script:PowerSettingMap[$Setting]
    $text = (powercfg /query SCHEME_CURRENT $m.Sub $m.Setting 2>&1) -join "`n"
    $hex = @([regex]::Matches($text, '0x[0-9a-fA-F]{8}') | ForEach-Object { $_.Value })
    # The first hex values belong to min/max/increment lines; the last two are the AC and DC indexes
    if ($hex.Count -lt 2) { return $null }
    return [PSCustomObject]@{ AC = [Convert]::ToInt32($hex[-2], 16); DC = [Convert]::ToInt32($hex[-1], 16) }
}

function Set-TrackedPowerTimeout {
    param(
        [Parameter(Mandatory)][ValidateSet("monitor", "standby", "hibernate")][string]$Setting,
        [Parameter(Mandatory)][ValidateSet("ac", "dc")][string]$Source,
        [Parameter(Mandatory)][int]$Minutes,
        [string]$Module = $(if ($MyInvocation.PSCommandPath) { [System.IO.Path]::GetFileNameWithoutExtension($MyInvocation.PSCommandPath) } else { "Manual" })
    )
    $prev = Get-PowerSettingSeconds -Setting $Setting
    $prevSec = if ($prev) { if ($Source -eq "ac") { $prev.AC } else { $prev.DC } } else { $null }
    if ($null -ne $prevSec -and $prevSec -eq ($Minutes * 60)) { return $null }
    powercfg /change "$Setting-timeout-$Source" $Minutes 2>&1 | Out-Null
    return (Add-ChangeJournalEntry -Kind "PowerSetting" -Target "$Setting-$Source" -PreviousValue $prevSec -NewValue ($Minutes * 60) `
                -Module $Module -Description "Guc zaman asimi $Setting ($($Source.ToUpper())): $Minutes dk")
}

function Set-TrackedTrim {
    param(
        [string]$Module = $(if ($MyInvocation.PSCommandPath) { [System.IO.Path]::GetFileNameWithoutExtension($MyInvocation.PSCommandPath) } else { "Manual" })
    )
    $out = (fsutil behavior query DisableDeleteNotify 2>&1) -join " "
    $prev = if ($out -match 'NTFS\s+DisableDeleteNotify\s*=\s*(\d)') { [int]$Matches[1] } elseif ($out -match '=\s*(\d)') { [int]$Matches[1] } else { $null }
    if ($prev -eq 0) { return $null }
    fsutil behavior set DisableDeleteNotify 0 2>&1 | Out-Null
    return (Add-ChangeJournalEntry -Kind "Trim" -Target "DisableDeleteNotify" -PreviousValue $prev -NewValue 0 -Module $Module -Description "SSD TRIM etkinlestirildi")
}

function Set-TrackedTcpGlobal {
    <#
    .SYNOPSIS
        TCP receive-window auto-tuning level and RSS, journaled from the structured cmdlets.
    #>
    param(
        [ValidateSet("normal", "disabled", "restricted", "highlyrestricted", "experimental")][string]$AutoTuning = "",
        [ValidateSet("enabled", "disabled")][string]$Rss = "",
        [string]$Module = $(if ($MyInvocation.PSCommandPath) { [System.IO.Path]::GetFileNameWithoutExtension($MyInvocation.PSCommandPath) } else { "Manual" })
    )
    $entries = @()
    if ($AutoTuning) {
        $prev = "$((Get-NetTCPSetting -SettingName Internet -ErrorAction SilentlyContinue).AutoTuningLevelLocal)".ToLowerInvariant()
        if ($prev -ne $AutoTuning) {
            & netsh.exe int tcp set global "autotuninglevel=$AutoTuning" 2>&1 | Out-Null
            $entries += Add-ChangeJournalEntry -Kind "NetTcp" -Target "autotuninglevel" -PreviousValue $prev -NewValue $AutoTuning -Module $Module -Description "TCP Auto-Tuning: $AutoTuning"
        }
    }
    if ($Rss) {
        $prev = "$((Get-NetOffloadGlobalSetting -ErrorAction SilentlyContinue).ReceiveSideScaling)".ToLowerInvariant()
        if ($prev -ne $Rss) {
            & netsh.exe int tcp set global "rss=$Rss" 2>&1 | Out-Null
            $entries += Add-ChangeJournalEntry -Kind "NetTcp" -Target "rss" -PreviousValue $prev -NewValue $Rss -Module $Module -Description "TCP RSS: $Rss"
        }
    }
    return $entries
}

function Set-TrackedDnsServers {
    param(
        [Parameter(Mandatory)][string]$InterfaceAlias,
        [Parameter(Mandatory)][string[]]$Servers,
        [string[]]$PreviousServers = @(),
        [string]$Module = $(if ($MyInvocation.PSCommandPath) { [System.IO.Path]::GetFileNameWithoutExtension($MyInvocation.PSCommandPath) } else { "Manual" })
    )
    Set-DnsClientServerAddress -InterfaceAlias $InterfaceAlias -ServerAddresses $Servers -ErrorAction Stop
    # Only DHCP adapters are changed by module 11, so undo = back to DHCP-provided DNS
    return (Add-ChangeJournalEntry -Kind "Dns" -Target $InterfaceAlias -PreviousValue "DHCP" -NewValue ($Servers -join ",") `
                -Module $Module -Description "DNS: $($Servers -join ' / ') (onceki DHCP: $($PreviousServers -join ', '))")
}

function Set-TrackedMpPreference {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)]$Value,
        [string]$Description = "",
        [string]$Module = $(if ($MyInvocation.PSCommandPath) { [System.IO.Path]::GetFileNameWithoutExtension($MyInvocation.PSCommandPath) } else { "Manual" })
    )
    $prefs = Get-MpPreference -ErrorAction Stop
    $prev = $prefs.$Name
    $params = @{ $Name = $Value; ErrorAction = "Stop" }
    Set-MpPreference @params
    $now = (Get-MpPreference -ErrorAction SilentlyContinue).$Name
    if (Test-ValueEqual $prev $now) { return $null }
    return (Add-ChangeJournalEntry -Kind "MpPreference" -Target $Name -PreviousValue ([int]$prev) -NewValue ([int]$now) -Module $Module -Description $Description)
}

#endregion

#region --- Undo ---

function Undo-ChangeJournalEntry {
    <#
    .SYNOPSIS
        Restores the previous value of one journal entry and marks it as reverted.
    #>
    param([Parameter(Mandatory)][string]$Id)

    $all = @(Get-ChangeJournal)
    $e = $all | Where-Object { $_.Id -eq $Id } | Select-Object -First 1
    if (-not $e) { throw "Kayit bulunamadi: $Id" }
    if ($e.Reverted) { return [PSCustomObject]@{ Id = $Id; Success = $true; Message = "Zaten geri alinmis." } }
    if (-not $e.Undoable) { return [PSCustomObject]@{ Id = $Id; Success = $false; Message = "Guvenlik nedeniyle geri alinmaz. $($e.Note)" } }

    switch ($e.Kind) {
        "Registry" {
            if ($e.PreviousExists) {
                $type = if ($e.PreviousType) { $e.PreviousType } else { "DWord" }
                $val = $e.PreviousValue
                if ($type -in @("DWord", "QWord")) { $val = [long]$val }
                Set-ItemProperty -LiteralPath $e.Target -Name $e.Name -Value $val -Type $type -Force
            } else {
                Remove-ItemProperty -LiteralPath $e.Target -Name $e.Name -Force -ErrorAction SilentlyContinue
            }
        }
        "Service"      { Set-Service -Name $e.Target -StartupType $e.PreviousValue -ErrorAction Stop }
        "PowerPlan"    { if ($e.PreviousValue) { powercfg /setactive $e.PreviousValue 2>&1 | Out-Null } }
        "PowerSetting" {
            if ($null -ne $e.PreviousValue) {
                $parts = $e.Target -split "-"
                $m = $Script:PowerSettingMap[$parts[0]]
                $verb = if ($parts[1] -eq "ac") { "/setacvalueindex" } else { "/setdcvalueindex" }
                powercfg $verb SCHEME_CURRENT $m.Sub $m.Setting ([int]$e.PreviousValue) 2>&1 | Out-Null
                powercfg /setactive SCHEME_CURRENT 2>&1 | Out-Null
            }
        }
        "Trim"         { if ($null -ne $e.PreviousValue) { fsutil behavior set DisableDeleteNotify ([int]$e.PreviousValue) 2>&1 | Out-Null } }
        "NetTcp"       { if ($e.PreviousValue) { & netsh.exe int tcp set global "$($e.Target)=$($e.PreviousValue)" 2>&1 | Out-Null } }
        "Dns"          { Set-DnsClientServerAddress -InterfaceAlias $e.Target -ResetServerAddresses -ErrorAction Stop }
        "MpPreference" { $params = @{ $e.Target = $e.PreviousValue; ErrorAction = "Stop" }; Set-MpPreference @params }
        default        { throw "Bu tur geri alinamaz: $($e.Kind)" }
    }

    foreach ($x in $all) {
        if ($x.Id -eq $Id) { $x.Reverted = $true; $x.RevertedAt = (Get-Date -Format "o") }
    }
    Save-ChangeJournal -Entries $all
    return [PSCustomObject]@{ Id = $Id; Success = $true; Message = "Geri alindi: $($e.Description)" }
}

function Undo-ChangeJournal {
    <#
    .SYNOPSIS
        Reverts the given (or all undoable, not yet reverted) entries, newest first.
    #>
    param([string[]]$Ids = @())
    $all = @(Get-ChangeJournal)
    $targets = $all | Where-Object { -not $_.Reverted -and $_.Undoable -and ($Ids.Count -eq 0 -or $Ids -contains $_.Id) } |
               Sort-Object { $_.Timestamp } -Descending
    $results = @()
    foreach ($t in $targets) {
        try { $results += Undo-ChangeJournalEntry -Id $t.Id }
        catch { $results += [PSCustomObject]@{ Id = $t.Id; Success = $false; Message = "$($t.Description): $($_.Exception.Message)" } }
    }
    return $results
}

#endregion
