#Requires -Version 5.1
<#
.SYNOPSIS
    DriverEngine.ps1 - Offline Driver Injection Engine (Drivers\ folder, used by module 05)
.DESCRIPTION
    Inspired by pnputil and Export-WindowsDriver best practices:
    1. Install-SystemDrivers: Scans a designated folder for .inf drivers and silently injects/installs them.
#>

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
        $null = & pnputil.exe /add-driver $targetInfPattern /subdirs /install 2>&1
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
