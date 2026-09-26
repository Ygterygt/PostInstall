#Requires -Version 5.1
<#
.SYNOPSIS
    HardwareMonitorEngine.ps1 - High-Performance Telemetry Engine
.DESCRIPTION
    Caches static hardware specifications and provides low-latency (<100ms)
    telemetry polling for UI dashboard integration.
.NOTES
    Author : Antigravity Systems Team
    Version: 4.0.0
#>

$Script:HardwareStaticCache = $null

function Initialize-HardwareMonitorEngine {
    [CmdletBinding()]
    param()

    $cpu = Get-CimInstance Win32_Processor | Select-Object -First 1
    $os  = Get-CimInstance Win32_OperatingSystem | Select-Object -First 1
    $controllers = Get-CimInstance Win32_VideoController -ErrorAction SilentlyContinue

    $gpus = @()
    foreach ($c in $controllers) {
        $vendor = "Other"
        if ($c.Name -match "NVIDIA|GeForce|RTX|GTX") { $vendor = "NVIDIA" }
        elseif ($c.Name -match "AMD|Radeon") { $vendor = "AMD" }
        elseif ($c.Name -match "Intel") { $vendor = "Intel" }

        $vramMB = 0
        if ($c.AdapterRAM -gt 0) { $vramMB = [Math]::Round($c.AdapterRAM / 1MB, 0) }

        $gpus += [PSCustomObject]@{
            Name          = $c.Name
            Vendor        = $vendor
            DriverVersion = $c.DriverVersion
            VramTotalMB   = $vramMB
            IsDiscrete    = ($vendor -eq "NVIDIA" -or $c.Name -match "RX [0-9]|Arc")
        }
    }

    $Script:HardwareStaticCache = [PSCustomObject]@{
        CpuName           = $cpu.Name.Trim()
        CpuCores          = $cpu.NumberOfCores
        CpuLogicalThreads = $cpu.NumberOfLogicalProcessors
        CpuMaxClockGHz    = [Math]::Round($cpu.MaxClockSpeed / 1000.0, 2)
        TotalRamGB        = [Math]::Round($os.TotalVisibleMemorySize / 1MB, 2)
        Gpus              = $gpus
        NvidiaSmiPath     = (Get-Command "nvidia-smi.exe" -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Source)
        InitializedAt     = Get-Date
    }
    return $Script:HardwareStaticCache
}

function Get-LiveTelemetrySample {
    [CmdletBinding()]
    param()

    if ($null -eq $Script:HardwareStaticCache) {
        Initialize-HardwareMonitorEngine | Out-Null
    }

    $cache = $Script:HardwareStaticCache
    $sw = [System.Diagnostics.Stopwatch]::StartNew()

    # 1. CPU Load & Clock
    $cpu = Get-CimInstance Win32_Processor | Select-Object LoadPercentage, CurrentClockSpeed -First 1
    $cpuLoad = if ($null -ne $cpu.LoadPercentage) { [int]$cpu.LoadPercentage } else { 0 }
    $clockGhz = if ($cpu.CurrentClockSpeed) { [Math]::Round($cpu.CurrentClockSpeed / 1000.0, 2) } else { $cache.CpuMaxClockGHz }

    # CPU Temperature
    $cpuTempC = $null
    try {
        $tz = Get-CimInstance Win32_PerfFormattedData_Counters_ThermalZoneInformation -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($tz -and $tz.Temperature -gt 273) {
            $cpuTempC = [Math]::Round($tz.Temperature - 273.15, 1)
        }
    } catch {}

    # 2. RAM Usage
    $os = Get-CimInstance Win32_OperatingSystem | Select-Object FreePhysicalMemory -First 1
    $ramFreeGB = [Math]::Round($os.FreePhysicalMemory / 1MB, 2)
    $ramUsedGB = [Math]::Max(0, [Math]::Round($cache.TotalRamGB - $ramFreeGB, 2))
    $ramPct = if ($cache.TotalRamGB -gt 0) { [Math]::Round(($ramUsedGB / $cache.TotalRamGB) * 100, 1) } else { 0 }

    # 3. GPU Live Telemetry
    $gpuLive = [System.Collections.Generic.List[PSCustomObject]]::new()
    $nvidiaReported = $false

    if ($cache.NvidiaSmiPath) {
        try {
            $nvOutput = & $cache.NvidiaSmiPath --query-gpu=name,temperature.gpu,utilization.gpu,memory.used,memory.total --format=csv,noheader,nounits 2>$null
            if ($nvOutput) {
                foreach ($line in ($nvOutput -split "`r?`n")) {
                    if ([string]::IsNullOrWhiteSpace($line)) { continue }
                    $parts = $line.Split(',') | ForEach-Object { $_.Trim() }
                    if ($parts.Count -ge 5) {
                        $gpuLive.Add([PSCustomObject]@{
                            Name           = $parts[0]
                            Vendor         = "NVIDIA"
                            TemperatureC   = [int]$parts[1]
                            LoadPercentage = [int]$parts[2]
                            VramUsedMB     = [int]$parts[3]
                            VramTotalMB    = [int]$parts[4]
                            IsDiscrete     = $true
                        })
                        $nvidiaReported = $true
                    }
                }
            }
        } catch {}
    }

    # Add other GPUs from static cache if not covered by nvidia-smi
    foreach ($g in $cache.Gpus) {
        if ($g.Vendor -eq "NVIDIA" -and $nvidiaReported) { continue }
        $gpuLive.Add([PSCustomObject]@{
            Name           = $g.Name
            Vendor         = $g.Vendor
            TemperatureC   = $null
            LoadPercentage = 0
            VramUsedMB     = 0
            VramTotalMB    = $g.VramTotalMB
            IsDiscrete     = $g.IsDiscrete
        })
    }

    # 4. Storage Live Telemetry
    $diskLive = [System.Collections.Generic.List[PSCustomObject]]::new()
    $volumes = Get-Volume -ErrorAction SilentlyContinue | Where-Object { 
        $_.DriveLetter -and $_.DriveType -eq 'Fixed' -and $_.Size -gt 0 
    }
    foreach ($vol in $volumes) {
        $dTotalGB = [Math]::Round($vol.Size / 1GB, 1)
        $dFreeGB  = [Math]::Round($vol.SizeRemaining / 1GB, 1)
        $dUsedGB  = [Math]::Round($dTotalGB - $dFreeGB, 1)
        $dPctUsed = if ($dTotalGB -gt 0) { [Math]::Round(($dUsedGB / $dTotalGB) * 100, 1) } else { 0 }
        $diskLive.Add([PSCustomObject]@{
            DriveLetter    = "$($vol.DriveLetter):"
            Label          = $vol.FileSystemLabel
            TotalGB        = $dTotalGB
            FreeGB         = $dFreeGB
            LoadPercentage = $dPctUsed
        })
    }

    # 5. Battery
    $battery = Get-CimInstance Win32_Battery -ErrorAction SilentlyContinue
    $batInfo = if ($battery) {
        @{
            HasBattery = $true
            ChargePct  = $battery.EstimatedChargeRemaining
            Status     = switch ($battery.BatteryStatus) {
                1 { "Pilde" }
                2 { "AC Bagli" }
                3 { "Tam Dolu" }
                default { "Bagli" }
            }
        }
    } else {
        @{ HasBattery = $false; ChargePct = 100; Status = "Masaustu / AC" }
    }

    $sw.Stop()

    return [PSCustomObject]@{
        Timestamp    = (Get-Date -Format "HH:mm:ss")
        DurationMs   = [Math]::Round($sw.Elapsed.TotalMilliseconds, 1)
        CpuName      = $cache.CpuName
        CpuCores     = $cache.CpuCores
        CpuThreads   = $cache.CpuLogicalThreads
        CpuLoadPct   = $cpuLoad
        CpuClockGhz  = $clockGhz
        CpuTempC     = $cpuTempC
        RamTotalGB   = $cache.TotalRamGB
        RamUsedGB    = $ramUsedGB
        RamFreeGB    = $ramFreeGB
        RamLoadPct   = $ramPct
        GPUs         = $gpuLive
        Disks        = $diskLive
        Battery      = $batInfo
    }
}
