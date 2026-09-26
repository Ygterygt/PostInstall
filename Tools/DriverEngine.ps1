#Requires -Version 5.1
<#
.SYNOPSIS
    DriverEngine.ps1 - Enterprise Hardware Driver Backup & Offline Injection Engine
.DESCRIPTION
    Inspired by pnputil and Export-WindowsDriver best practices:
    1. Export-SystemDrivers: Exports all third-party drivers (OEM INF packages) to a backup directory.
    2. Install-SystemDrivers: Scans a designated folder for .inf drivers and silently injects/installs them.
#>

function Export-SystemDrivers {
    [CmdletBinding()]
    param(
        [string]$Destination = (Join-Path $env:ProgramData "ComputerMaintenancePro\Backups\Drivers")
    )

    $result = [PSCustomObject]@{
        Success        = $false
        Destination    = $Destination
        ExportedCount  = 0
        DurationSec    = 0
        Method         = "PnPUtil"
        ErrorMessage   = $null
    }

    $sw = [System.Diagnostics.Stopwatch]::StartNew()

    try {
        if (-not (Test-Path $Destination)) {
            New-Item -Path $Destination -ItemType Directory -Force | Out-Null
        }

        # Try native Export-WindowsDriver first (PS 5.1+)
        $cmdExport = Get-Command "Export-WindowsDriver" -ErrorAction SilentlyContinue
        if ($cmdExport) {
            $result.Method = "Export-WindowsDriver"
            $drvList = Export-WindowsDriver -Online -Destination $Destination -ErrorAction Stop
            $result.ExportedCount = if ($drvList) { $drvList.Count } else { 0 }
            $result.Success = $true
        } else {
            # Fallback to pnputil /export-driver
            $result.Method = "pnputil.exe"
            $pnpOut = & pnputil.exe /export-driver * $Destination 2>&1
            $exportedInfs = Get-ChildItem -Path $Destination -Filter "*.inf" -Recurse -ErrorAction SilentlyContinue
            $result.ExportedCount = if ($exportedInfs) { $exportedInfs.Count } else { 0 }
            $result.Success = ($LASTEXITCODE -eq 0 -or $result.ExportedCount -gt 0)
        }
    } catch {
        $result.ErrorMessage = $_.Exception.Message
        $result.Success = $false
    } finally {
        $sw.Stop()
        $result.DurationSec = [Math]::Round($sw.Elapsed.TotalSeconds, 2)
    }

    return $result
}

function Install-SystemDrivers {
    [CmdletBinding()]
    param(
        [string]$DriverSourceDir = (Join-Path (Split-Path -Parent $PSScriptRoot) "Drivers")
    )

    $result = [PSCustomObject]@{
        Success        = $false
        SourceDir      = $DriverSourceDir
        DiscoveredInfs = 0
        InstalledCount = 0
        DurationSec    = 0
        ErrorMessage   = $null
    }

    if (-not (Test-Path $DriverSourceDir)) {
        $result.ErrorMessage = "Dizin bulunamadi: $DriverSourceDir"
        return $result
    }

    $sw = [System.Diagnostics.Stopwatch]::StartNew()

    try {
        $infFiles = Get-ChildItem -Path $DriverSourceDir -Filter "*.inf" -Recurse -ErrorAction SilentlyContinue
        $result.DiscoveredInfs = if ($infFiles) { $infFiles.Count } else { 0 }

        if ($result.DiscoveredInfs -eq 0) {
            $result.Success = $true
            $sw.Stop()
            $result.DurationSec = [Math]::Round($sw.Elapsed.TotalSeconds, 2)
            return $result
        }

        # Use pnputil /add-driver to inject all INF packages
        $targetInfPattern = Join-Path $DriverSourceDir "*.inf"
        $pnpOut = & pnputil.exe /add-driver $targetInfPattern /subdirs /install 2>&1
        $result.Success = ($LASTEXITCODE -in @(0, 259, 3010))
        $result.InstalledCount = $result.DiscoveredInfs
    } catch {
        $result.ErrorMessage = $_.Exception.Message
        $result.Success = $false
    } finally {
        $sw.Stop()
        $result.DurationSec = [Math]::Round($sw.Elapsed.TotalSeconds, 2)
    }

    return $result
}
