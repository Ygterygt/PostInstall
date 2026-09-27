#Requires -Version 5.1
<#
.SYNOPSIS
    UpdateEngine.ps1 - Installed application update discovery & upgrade (WinGet)
.DESCRIPTION
    - Get-AvailableAppUpdates : runs `winget upgrade` and parses its table into objects
    - Update-AppPackage       : upgrades one package by exact id, classifying WinGet return codes
    The winget CLI has no JSON output for `upgrade`, so the table is parsed by COLUMN POSITIONS
    taken from the header line. Header texts are localized (Name/Ad, Id/Kimlik...) and are never
    matched by name, which keeps the parser language independent.
.NOTES
    Inspired by UniGetUI and Winget-AutoUpdate (see docs/ROADMAP.md, CMP-28).
#>

. (Join-Path $PSScriptRoot "PackageEngine.ps1")

function ConvertFrom-WingetTable {
    <#
    .SYNOPSIS
        Pure parser: turns the first table of `winget upgrade` output into objects.
    .OUTPUTS
        PSCustomObject with Name, Id, Version, Available, Source
    #>
    param([string[]]$Lines)

    $Lines = @($Lines | ForEach-Object { $_ -split "`r?`n" })

    # Header is the line right above the first dashed separator
    $sepIndex = -1
    for ($i = 1; $i -lt $Lines.Count; $i++) {
        if ($Lines[$i] -match '^-{10,}\s*$') { $sepIndex = $i; break }
    }
    if ($sepIndex -lt 1) { return @() }

    # Progress spinners can share the header line after a carriage return: keep the last segment
    $header = ($Lines[$sepIndex - 1] -split "`r")[-1]
    $starts = @([regex]::Matches($header, '\S+') | ForEach-Object { $_.Index })
    if ($starts.Count -lt 5) { return @() }
    $starts = $starts[0..4]

    $items = @()
    for ($i = $sepIndex + 1; $i -lt $Lines.Count; $i++) {
        $line = $Lines[$i]
        # The table ends at the first blank line or at the summary line ("4 upgrades available.")
        if ([string]::IsNullOrWhiteSpace($line) -or $line.Length -le $starts[2]) { break }

        $cols = @()
        for ($c = 0; $c -lt 5; $c++) {
            $from = $starts[$c]
            $to   = if ($c -lt 4) { $starts[$c + 1] } else { $line.Length }
            $cols += if ($from -lt $line.Length) { $line.Substring($from, [Math]::Min($to, $line.Length) - $from).Trim() } else { "" }
        }
        if (-not $cols[1]) { continue }
        $items += [PSCustomObject]@{
            Name      = $cols[0].TrimEnd([char]0x2026)   # winget truncates long names with '…'
            Id        = $cols[1]
            Version   = $cols[2]
            Available = $cols[3]
            Source    = $cols[4]
        }
    }
    return $items
}

function Invoke-WingetCapture {
    <#
    .SYNOPSIS
        Runs winget and returns its output as UTF-8 text lines plus the exit code.
    #>
    param([Parameter(Mandatory)][string[]]$Arguments)

    $winget = Get-WingetExe
    if (-not $winget) { throw "winget bulunamadi (App Installer yuklu degil)." }

    $prev = $null
    try { $prev = [Console]::OutputEncoding; [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch {}
    try {
        $out = & $winget @Arguments 2>&1 | ForEach-Object { "$_" }
        return [PSCustomObject]@{ Lines = @($out); ExitCode = $LASTEXITCODE }
    } finally {
        if ($prev) { try { [Console]::OutputEncoding = $prev } catch {} }
    }
}

function Get-AvailableAppUpdates {
    <#
    .SYNOPSIS
        Lists installed packages that have a newer version in the winget/msstore sources.
    .PARAMETER ExcludeIds
        Package ids the user never wants upgraded (config.json -> Updates.ExcludeIds).
    #>
    param([string[]]$ExcludeIds = @())

    $res = Invoke-WingetCapture -Arguments @("upgrade", "--accept-source-agreements", "--disable-interactivity")
    $items = ConvertFrom-WingetTable -Lines $res.Lines
    foreach ($item in $items) {
        $item | Add-Member -NotePropertyName Excluded -NotePropertyValue ($ExcludeIds -contains $item.Id) -Force
    }
    return $items
}

function Update-AppPackage {
    <#
    .SYNOPSIS
        Upgrades a single package by exact id. Returns Success / RebootRequired / ExitCode / Details.
    #>
    param(
        [Parameter(Mandatory)][string]$Id,
        [string]$Source = "winget"
    )

    $wgArgs = @("upgrade", "--id", $Id, "--exact", "--silent", "--accept-package-agreements",
              "--accept-source-agreements", "--disable-interactivity")
    if ($Source) { $wgArgs += @("--source", $Source) }

    $res  = Invoke-WingetCapture -Arguments $wgArgs
    $code = $res.ExitCode
    $ok   = ($code -in $Script:WingetSuccessCodes) -or ($code -in $Script:WingetRebootCodes)
    $last = @($res.Lines | Where-Object { $_.Trim() -and $_ -notmatch '^[\s\-\\|/█▒]+$' }) | Select-Object -Last 1

    return [PSCustomObject]@{
        Id             = $Id
        Success        = $ok
        RebootRequired = ($code -in $Script:WingetRebootCodes)
        ExitCode       = $code
        Details        = if ($ok) { "Guncellendi (Kod: $code)" } else { "Kod: $code (0x$('{0:X8}' -f $code)) $last" }
    }
}
