#Requires -Version 5.1
<#
.SYNOPSIS
    Computer Maintenance Pro - Enterprise System Maintenance Engine
.DESCRIPTION
    Provides automated system hygiene, component store (DISM) cleanup,
    Windows Update cache purge, temp/junk file wiping, network stack refresh,
    SSD ReTrim, and battery health reporting.
.NOTES
    Author : Antigravity Systems Team
    Version: 4.0.0
#>

[CmdletBinding()]
param()

function Write-MaintenanceLog {
    param(
        [string]$Message,
        [ValidateSet("INFO", "WARN", "ERROR", "SUCCESS")]
        [string]$Level = "INFO"
    )
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $color = switch ($Level) {
        "SUCCESS" { "Green" }
        "WARN"    { "Yellow" }
        "ERROR"   { "Red" }
        Default   { "Cyan" }
    }
    Write-Host "[$timestamp] [$Level] $Message" -ForegroundColor $color
}

function Clear-SystemJunkAndTemp {
    <#
    .SYNOPSIS
        Safely clears user temp, system temp, crash dumps and WER queues.
    .PARAMETER MinAgeDays
        Only files older than this are removed (0 = everything). Protects files of running installers.
    .PARAMETER ExcludePattern
        File/folder name wildcards that are never deleted (suite logs, state, reports).
    .PARAMETER Paths
        Override target folders (used by tests); defaults to the standard junk locations.
    #>
    [CmdletBinding()]
    param(
        [switch]$IncludeRecycleBin,
        [int]$MinAgeDays = 1,
        [string[]]$ExcludePattern = @("PostInstall*", "ComputerMaintenancePro*", "CMP_*"),
        [string[]]$Paths = @()
    )

    Write-MaintenanceLog "Gecici dosya ve sistem artiklari temizligi baslatiliyor (Esik: $MinAgeDays gun)..." "INFO"
    $bytesCleaned = [long]0
    $filesRemoved = 0
    $cutoff = (Get-Date).AddDays(-$MinAgeDays)

    if ($Paths.Count -eq 0) {
        $Paths = @(
            $env:TEMP,
            "$env:LOCALAPPDATA\Temp",
            "$env:windir\Temp",
            "$env:windir\Minidump",
            "$env:ProgramData\Microsoft\Windows\WER\ReportQueue",
            "$env:ProgramData\Microsoft\Windows\WER\ReportArchive",
            "$env:windir\SoftwareDistribution\DeliveryOptimization"
        )
    }
    $targetPaths = $Paths | Where-Object { $_ -and (Test-Path $_) } | Select-Object -Unique

    $isExcluded = {
        param($item, $root)
        # Check every path segment below the root so excluded folders protect their content
        $relative = $item.FullName.Substring($root.Length).TrimStart('\')
        foreach ($segment in ($relative -split '\\')) {
            foreach ($pattern in $ExcludePattern) {
                if ($segment -like $pattern) { return $true }
            }
        }
        return $false
    }

    foreach ($path in $targetPaths) {
        $root = (Resolve-Path -LiteralPath $path).Path.TrimEnd('\')
        try {
            $files = Get-ChildItem -LiteralPath $root -Recurse -Force -File -ErrorAction SilentlyContinue |
                     Where-Object { $_.LastWriteTime -lt $cutoff }
            foreach ($file in $files) {
                if (& $isExcluded $file $root) { continue }
                $size = $file.Length
                try {
                    Remove-Item -LiteralPath $file.FullName -Force -ErrorAction Stop
                    $bytesCleaned += $size
                    $filesRemoved++
                } catch {}  # In use / access denied: normal for temp folders
            }
            # Clean empty directories (deepest first)
            Get-ChildItem -LiteralPath $root -Recurse -Directory -Force -ErrorAction SilentlyContinue |
                Sort-Object { $_.FullName.Length } -Descending |
                ForEach-Object {
                    if (-not (& $isExcluded $_ $root) -and
                        @(Get-ChildItem -LiteralPath $_.FullName -Force -ErrorAction SilentlyContinue).Count -eq 0) {
                        Remove-Item -LiteralPath $_.FullName -Force -ErrorAction SilentlyContinue
                    }
                }
        } catch {
            Write-MaintenanceLog "Yol temizlenirken erisim engeli (normal): $path" "WARN"
        }
    }

    if ($IncludeRecycleBin) {
        try {
            Clear-RecycleBin -Force -ErrorAction SilentlyContinue
            Write-MaintenanceLog "Geri Donusum Kutusu bosaltildi." "SUCCESS"
        } catch {}
    }

    $mbReclaimed = [Math]::Round($bytesCleaned / 1MB, 2)
    Write-MaintenanceLog "Sistem artiklari temizligi tamamlandi. $filesRemoved dosya, $mbReclaimed MB geri kazanildi." "SUCCESS"
    return @{
        Success      = $true
        BytesFreed   = $bytesCleaned
        MBFreed      = $mbReclaimed
        FilesRemoved = $filesRemoved
    }
}

function Clear-WindowsUpdateCache {
    <#
    .SYNOPSIS
        Stops update services, clears SoftwareDistribution\Download cache, and restarts services.
    #>
    [CmdletBinding()]
    param()

    Write-MaintenanceLog "Windows Update onbellek temizligi baslatiliyor..." "INFO"
    $services = @("wuauserv", "bits", "cryptsvc")

    foreach ($svc in $services) {
        try {
            Stop-Service -Name $svc -Force -ErrorAction SilentlyContinue
        } catch {}
    }

    $cachePath = "$env:windir\SoftwareDistribution\Download"
    $bytesCleaned = 0
    if (Test-Path $cachePath) {
        $files = Get-ChildItem -Path $cachePath -Recurse -Force -ErrorAction SilentlyContinue | Where-Object { -not $_.PSIsContainer }
        foreach ($file in $files) {
            try {
                $bytesCleaned += $file.Length
                Remove-Item -LiteralPath $file.FullName -Force -ErrorAction SilentlyContinue
            } catch {}
        }
    }

    foreach ($svc in $services) {
        try {
            Start-Service -Name $svc -ErrorAction SilentlyContinue
        } catch {}
    }

    $mbReclaimed = [Math]::Round($bytesCleaned / 1MB, 2)
    Write-MaintenanceLog "Windows Update indirme onbellegi temizlendi: $mbReclaimed MB geri kazanildi." "SUCCESS"
    return @{
        Success    = $true
        MBFreed    = $mbReclaimed
    }
}

function Invoke-DismComponentCleanup {
    <#
    .SYNOPSIS
        Executes DISM Component Store cleanup (/StartComponentCleanup /ResetBase).
    #>
    [CmdletBinding()]
    param(
        [switch]$ResetBase
    )

    Write-MaintenanceLog "DISM Bilesen Deposu (WinSxS) temizligi baslatiliyor..." "INFO"
    $dismArgs = "/Online /Cleanup-Image /StartComponentCleanup"
    if ($ResetBase) {
        $dismArgs += " /ResetBase"
    }

    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $p = Start-Process -FilePath "dism.exe" -ArgumentList $dismArgs -NoNewWindow -Wait -PassThru
    $sw.Stop()

    if ($p.ExitCode -eq 0) {
        Write-MaintenanceLog "DISM Bilesen Deposu temizlendi ($([Math]::Round($sw.Elapsed.TotalSeconds, 1)) saniye)." "SUCCESS"
        return @{ Success = $true; ExitCode = 0; DurationSeconds = $sw.Elapsed.TotalSeconds }
    } else {
        Write-MaintenanceLog "DISM Islemi kod $($p.ExitCode) ile bitti." "WARN"
        return @{ Success = $false; ExitCode = $p.ExitCode; DurationSeconds = $sw.Elapsed.TotalSeconds }
    }
}

function Invoke-SystemHealthScan {
    <#
    .SYNOPSIS
        Scans Windows Component Store health with DISM.
    #>
    [CmdletBinding()]
    param()

    Write-MaintenanceLog "Windows Sistem Bilesen Sagligi (DISM CheckHealth) denetleniyor..." "INFO"
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $p = Start-Process -FilePath "dism.exe" -ArgumentList "/Online /Cleanup-Image /CheckHealth" -NoNewWindow -Wait -PassThru
    $sw.Stop()

    $healthy = ($p.ExitCode -eq 0)
    $statusText = if ($healthy) { "Saglam (Bozulma Tespit Edilmedi)" } else { "Onarim Gerekiyor" }
    Write-MaintenanceLog "DISM Saglik Durumu: $statusText" $(if ($healthy) { "SUCCESS" } else { "WARN" })

    return @{
        IsHealthy       = $healthy
        ExitCode        = $p.ExitCode
        DurationSeconds = $sw.Elapsed.TotalSeconds
    }
}

function Reset-NetworkStack {
    <#
    .SYNOPSIS
        Flushes DNS, resets Winsock, and purges ARP table.
    #>
    [CmdletBinding()]
    param()

    Write-MaintenanceLog "Ag ve DNS onbellegi sifirlaniyor..." "INFO"
    try {
        Clear-DnsClientCache -ErrorAction SilentlyContinue
        Start-Process -FilePath "netsh.exe" -ArgumentList "winsock reset" -NoNewWindow -Wait -ErrorAction SilentlyContinue
        Start-Process -FilePath "arp.exe" -ArgumentList "-d *" -NoNewWindow -Wait -ErrorAction SilentlyContinue
        Write-MaintenanceLog "DNS ve Winsock soketleri basariyla tazelendi." "SUCCESS"
        return @{ Success = $true }
    } catch {
        Write-MaintenanceLog "Ag sifirlama uyarisi: $($_.Exception.Message)" "WARN"
        return @{ Success = $false; Error = $_.Exception.Message }
    }
}

function Optimize-StorageDrives {
    <#
    .SYNOPSIS
        Issues ReTrim across all fixed SSD/NVMe volumes.
    #>
    [CmdletBinding()]
    param()

    Write-MaintenanceLog "Sabit suruculer icin SSD TRIM optimizasyonu baslatiliyor..." "INFO"
    $volumes = Get-Volume -ErrorAction SilentlyContinue | Where-Object { 
        $_.DriveLetter -and $_.DriveType -eq 'Fixed' -and $_.FileSystem -in @('NTFS', 'ReFS')
    }

    $results = @()
    foreach ($vol in $volumes) {
        $letter = $vol.DriveLetter
        try {
            Write-MaintenanceLog "Surucu $letter`: ReTrim islemi..." "INFO"
            Optimize-Volume -DriveLetter $letter -ReTrim -Verbose -ErrorAction SilentlyContinue
            Write-MaintenanceLog "Surucu $letter`: TRIM basariyla gonderildi." "SUCCESS"
            $results += [PSCustomObject]@{ Drive = "$letter`: "; Status = "TRIM_OK" }
        } catch {
            Write-MaintenanceLog "Surucu $letter`: TRIM yapilamadi ($($_.Exception.Message))" "WARN"
            $results += [PSCustomObject]@{ Drive = "$letter`: "; Status = "SKIPPED" }
        }
    }
    return $results
}

function Prune-WindowsEventLogs {
    <#
    .SYNOPSIS
        Archives (.evtx) and clears high-churn event logs exceeding the size threshold.
        Logs are never cleared without a backup, so troubleshooting history is preserved.
    #>
    [CmdletBinding()]
    param(
        [long]$MaxSizeBytes = 20971520, # 20MB
        [string]$ArchiveDir = (Join-Path $env:ProgramData "ComputerMaintenancePro\EventLogArchive")
    )

    Write-MaintenanceLog "Windows Olay Gunlukleri (Event Log) bakimi yapiliyor..." "INFO"
    $logsToPrune = @("Application", "System", "Setup")
    $clearedCount = 0
    if (-not (Test-Path $ArchiveDir)) { New-Item -Path $ArchiveDir -ItemType Directory -Force | Out-Null }
    $stamp = Get-Date -Format "yyyyMMdd_HHmmss"

    foreach ($logName in $logsToPrune) {
        try {
            $log = Get-WinEvent -ListLog $logName -ErrorAction SilentlyContinue
            if ($log -and $log.FileSize -gt $MaxSizeBytes) {
                $backup = Join-Path $ArchiveDir "$($logName)_$stamp.evtx"
                wevtutil.exe cl $logName "/bu:$backup"
                if ($LASTEXITCODE -eq 0 -and (Test-Path $backup)) {
                    Write-MaintenanceLog "Olay Gunlugu arsivlendi ve temizlendi: $logName ($([Math]::Round($log.FileSize / 1MB, 1)) MB) -> $backup" "SUCCESS"
                    $clearedCount++
                } else {
                    Write-MaintenanceLog "Olay Gunlugu arsivlenemedi, temizlenmedi: $logName" "WARN"
                }
            }
        } catch {}
    }
    return @{ ClearedCount = $clearedCount; ArchiveDir = $ArchiveDir }
}

function Get-BatteryHealthReport {
    <#
    .SYNOPSIS
        Generates Windows battery report and parses design vs full capacity.
    #>
    [CmdletBinding()]
    param()

    $battery = Get-CimInstance Win32_Battery -ErrorAction SilentlyContinue
    if (-not $battery) {
        return @{ HasBattery = $false; Message = "Pil bulunamadi (Masaustu veya Sanal Makine)" }
    }

    $outputPath = Join-Path $env:TEMP "PostInstall_BatteryReport.html"
    try {
        Start-Process -FilePath "powercfg.exe" -ArgumentList "/batteryreport /output `"$outputPath`"" -NoNewWindow -Wait
        
        $designCap = 0
        $fullCap   = 0
        $cycleCount = 0

        if (Test-Path $outputPath) {
            $content = Get-Content -LiteralPath $outputPath -Raw -ErrorAction SilentlyContinue
            if ($content -match 'DESIGN CAPACITY.*?([\d,]+)\s*mWh') {
                $designCap = [int]($matches[1] -replace '[,.]', '')
            }
            if ($content -match 'FULL CHARGE CAPACITY.*?([\d,]+)\s*mWh') {
                $fullCap = [int]($matches[1] -replace '[,.]', '')
            }
            if ($content -match 'CYCLE COUNT.*?([\d,]+)') {
                $cycleCount = [int]($matches[1] -replace '[,.]', '')
            }
        }

        $healthPct = 100
        if ($designCap -gt 0 -and $fullCap -gt 0) {
            $healthPct = [Math]::Round(($fullCap / $designCap) * 100, 1)
        }

        return @{
            HasBattery         = $true
            DesignCapacityMWh  = $designCap
            FullChargeMWh      = $fullCap
            HealthPercentage   = $healthPct
            CycleCount         = $cycleCount
            WearPercentage     = [Math]::Max(0, [Math]::Round(100 - $healthPct, 1))
            ReportPath         = $outputPath
        }
    } catch {
        return @{ HasBattery = $true; HealthPercentage = 100; Message = $_.Exception.Message }
    }
}

# End of MaintenanceEngine.ps1
