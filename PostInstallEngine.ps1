#Requires -Version 5.1
<#
.SYNOPSIS
    Antigravity Enterprise Post-Installation Engine
.DESCRIPTION
    State-machine driven, reboot-resilient post-installation engine.
    Designed for corporate imaging workflows (MDT/SCCM/Intune/standalone).
    Orchestrates installation modules sequentially, persists state across reboots,
    and manages RunOnce registry keys for automatic resume.
.NOTES
    Author  : Antigravity Enterprise
    Version : 2.0.0
    Requires: PowerShell 5.1+, .NET Framework 4.6+, Windows 10+
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [switch]$Resume,
    [switch]$Reset,
    [switch]$Headless
)

Set-StrictMode -Off  # Compatibility with PS 5.1 quirks in enterprise environments
$ErrorActionPreference = "Stop"

#region --- Constants & Bootstrap ---

# Resolve script root robustly — works in dot-source, direct-run, and runspace contexts
$Script:EngineRoot = if ($PSScriptRoot -and (Test-Path $PSScriptRoot)) {
    $PSScriptRoot
} elseif ($MyInvocation.MyCommand.Path) {
    Split-Path -Parent $MyInvocation.MyCommand.Path
} else {
    "C:\PostInstall"
}

$Script:ConfigFile = Join-Path $Script:EngineRoot "config.json"
$Script:StepsFile  = Join-Path $Script:EngineRoot "steps.json"

if (-not (Test-Path $Script:ConfigFile)) {
    Write-Error "FATAL: config.json bulunamadi: $Script:ConfigFile"
    exit 1
}
if (-not (Test-Path $Script:StepsFile)) {
    Write-Error "FATAL: steps.json bulunamadi: $Script:StepsFile"
    exit 1
}

$Script:Config = [System.IO.File]::ReadAllText($Script:ConfigFile, [System.Text.Encoding]::UTF8) | ConvertFrom-Json
$Script:Steps  = [System.IO.File]::ReadAllText($Script:StepsFile,  [System.Text.Encoding]::UTF8) | ConvertFrom-Json

# Resolve paths from config with universal environment variable expansion
$Script:LogFile      = [System.Environment]::ExpandEnvironmentVariables($Script:Config.LogFile)
$Script:ErrorLogFile = [System.Environment]::ExpandEnvironmentVariables($Script:Config.ErrorLogFile)
$Script:StateFile    = [System.Environment]::ExpandEnvironmentVariables($Script:Config.StateFile)
$Script:SummaryReport= if ($Script:Config.SummaryReport) { [System.Environment]::ExpandEnvironmentVariables($Script:Config.SummaryReport) } else { "C:\Windows\Temp\PostInstall_Summary.md" }
$Script:DocsSyncPath = if ($Script:Config.DocsSyncPath) { [System.Environment]::ExpandEnvironmentVariables($Script:Config.DocsSyncPath) } else { "$env:USERPROFILE\Desktop\Antigravity\Docs" }

# Create log directories if they don't exist
foreach ($dir in @((Split-Path $Script:LogFile), (Split-Path $Script:ErrorLogFile), (Split-Path $Script:StateFile), $Script:DocsSyncPath)) {
    if ($dir -and -not (Test-Path $dir)) {
        try { New-Item -Path $dir -ItemType Directory -Force | Out-Null } catch {}
    }
}

#endregion

#region --- Logging ---

# Log writer using StreamWriter for thread-safe, BOM-free UTF-8 output
function Write-EngineLog {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Message,
        [ValidateSet("INFO","SUCCESS","WARN","ERROR","DEBUG")][string]$Level = "INFO",
        [System.Collections.Concurrent.ConcurrentQueue[string]]$Queue = $null
    )

    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $line = "[$timestamp] [$Level] $Message"

    # Console color output
    $color = switch ($Level) {
        "SUCCESS" { "Green"    }
        "WARN"    { "Yellow"   }
        "ERROR"   { "Red"      }
        "DEBUG"   { "DarkGray" }
        default   { "Cyan"     }
    }
    try { Write-Host $line -ForegroundColor $color } catch {}

    # Thread-safe, BOM-free UTF-8 file write
    try {
        $encoding = New-Object System.Text.UTF8Encoding($false)  # $false = no BOM
        $writer = New-Object System.IO.StreamWriter($Script:LogFile, $true, $encoding)
        $writer.WriteLine($line)
        $writer.Close()

        if ($Level -eq "ERROR") {
            $errWriter = New-Object System.IO.StreamWriter($Script:ErrorLogFile, $true, $encoding)
            $errWriter.WriteLine($line)
            $errWriter.Close()
        }
    } catch {
        # Log write failure is non-fatal
    }

    # Push to UI message queue (thread-safe)
    if ($null -ne $Queue) {
        $Queue.Enqueue($line)
    }
}

function Write-EngineEventLog {
    param(
        [Parameter(Mandatory)][string]$Message,
        [ValidateSet("Information","Warning","Error")][string]$EntryType = "Information",
        [int]$EventId = 1000
    )
    try {
        $source = "AntigravityPostInstall"
        if (-not [System.Diagnostics.EventLog]::SourceExists($source)) {
            [System.Diagnostics.EventLog]::CreateEventSource($source, "Application")
        }
        [System.Diagnostics.EventLog]::WriteEntry($source, $Message, $EntryType, $EventId)
    } catch {}
}

#endregion

#region --- State Management ---

function Get-EngineState {
    if (Test-Path $Script:StateFile) {
        try {
            $raw = Get-Content $Script:StateFile -Raw -ErrorAction Stop
            $state = $raw | ConvertFrom-Json
            # Validate structure integrity
            if ($null -ne $state.SessionId -and $null -ne $state.StepResults) {
                return $state
            }
            Write-EngineLog "State dosyasi gecersiz yapida, yeniden olusturuluyor." "WARN"
        } catch {
            Write-EngineLog "State dosyasi okunamadi ($_), yeniden olusturuluyor." "WARN"
        }
    }
    return New-EngineState
}

function New-EngineState {
    $stepStates = foreach ($step in $Script:Steps) {
        [PSCustomObject]@{
            Id           = $step.Id
            Order        = $step.Order
            Title        = $step.Title
            Status       = "Pending"   # Pending | Running | Success | Warning | Failed | Skipped
            ExitCode     = $null
            StartTime    = $null
            EndTime      = $null
            DurationSec  = $null
            ErrorMessage = $null
        }
    }

    return [PSCustomObject]@{
        SchemaVersion    = "2.0"
        SessionId        = [System.Guid]::NewGuid().ToString()
        HostName         = $env:COMPUTERNAME
        EngineRoot       = $Script:EngineRoot
        StartedAt        = (Get-Date -Format "o")
        LastUpdatedAt    = (Get-Date -Format "o")
        CurrentStepIndex = 0
        Status           = "Initialized"   # Initialized | Running | RebootPending | Completed | Failed
        RebootPending    = $false
        TotalSteps       = $Script:Steps.Count
        CompletedSteps   = 0
        FailedSteps      = 0
        StepResults      = @($stepStates)
    }
}

function Save-EngineState {
    param([Parameter(Mandatory)]$State)

    $State.LastUpdatedAt = (Get-Date -Format "o")
    $State.CompletedSteps = @($State.StepResults | Where-Object { $_.Status -in @("Success","Warning") }).Count
    $State.FailedSteps    = @($State.StepResults | Where-Object { $_.Status -eq "Failed" }).Count

    try {
        $json = $State | ConvertTo-Json -Depth 8
        # Write atomically: write to temp, then move (prevents corruption on crash)
        $tempPath = "$Script:StateFile.tmp"
        $encoding = New-Object System.Text.UTF8Encoding($false)
        [System.IO.File]::WriteAllText($tempPath, $json, $encoding)
        Move-Item -Path $tempPath -Destination $Script:StateFile -Force
    } catch {
        Write-EngineLog "State kayit hatasi: $_" "ERROR"
    }
}

#endregion

#region --- Registry RunOnce (Reboot Persistence) ---

$Script:RunOnceKeyHKCU = "HKCU:\Software\Microsoft\Windows\CurrentVersion\RunOnce"
$Script:RunOnceKeyHKLM = "HKLM:\Software\Microsoft\Windows\CurrentVersion\RunOnce"
$Script:RunOnceName    = $Script:Config.RunOnceKeyName

function Register-RunOnceResume {
    # Use the .exe launcher so UAC elevation happens automatically on resume
    $exePath = Join-Path $Script:EngineRoot "PostInstall.exe"
    if (-not (Test-Path $exePath)) {
        # Fallback to batch launcher
        $exePath = Join-Path $Script:EngineRoot "Launch-PostInstall.bat"
    }

    $cmd = "`"$exePath`" -Resume"
    Write-EngineLog "RunOnce kayit ediliyor: $cmd" "INFO"

    # HKCU: runs when current user logs in
    try {
        Set-ItemProperty -Path $Script:RunOnceKeyHKCU -Name $Script:RunOnceName -Value $cmd -Force -ErrorAction Stop
        Write-EngineLog "RunOnce HKCU kaydedildi." "SUCCESS"
    } catch {
        Write-EngineLog "HKCU RunOnce yazma hatasi: $_" "WARN"
    }

    # HKLM: requires elevation, but fires for all users (more reliable in enterprise)
    try {
        Set-ItemProperty -Path $Script:RunOnceKeyHKLM -Name $Script:RunOnceName -Value $cmd -Force -ErrorAction Stop
        Write-EngineLog "RunOnce HKLM kaydedildi." "SUCCESS"
    } catch {
        Write-EngineLog "HKLM RunOnce yazma hatasi: $_" "WARN"
    }
}

function Unregister-RunOnceResume {
    Write-EngineLog "RunOnce kayitlari temizleniyor..." "INFO"
    foreach ($path in @($Script:RunOnceKeyHKCU, $Script:RunOnceKeyHKLM)) {
        try {
            Remove-ItemProperty -Path $path -Name $Script:RunOnceName -ErrorAction SilentlyContinue
        } catch { }
    }
    Write-EngineLog "RunOnce kayitlari temizlendi." "SUCCESS"
}

#endregion

#region --- Step Execution ---

function Invoke-EngineStep {
    param(
        [Parameter(Mandatory)]$Step,
        [Parameter(Mandatory)]$State,
        [Parameter(Mandatory)][int]$StepIndex,
        [System.Collections.Concurrent.ConcurrentQueue[string]]$Queue = $null
    )

    $stepRecord = $State.StepResults[$StepIndex]
    $stepRecord.Status    = "Running"
    $stepRecord.StartTime = (Get-Date -Format "o")
    Save-EngineState -State $State

    $separator = ("=" * 60)
    Write-EngineLog $separator "INFO" $Queue
    Write-EngineLog "ADIM [$($Step.Order)/$($Script:Steps.Count)]: $($Step.Title)" "INFO" $Queue
    Write-EngineLog "Tanim: $($Step.Description)" "INFO" $Queue
    Write-EngineLog $separator "INFO" $Queue

    $scriptPath = Join-Path $Script:EngineRoot $Step.Script
    if (-not (Test-Path $scriptPath)) {
        $stepRecord.Status       = "Failed"
        $stepRecord.ErrorMessage = "Script bulunamadi: $scriptPath"
        $stepRecord.EndTime      = (Get-Date -Format "o")
        Save-EngineState -State $State
        Write-EngineLog "Script dosyasi bulunamadi: $scriptPath" "ERROR" $Queue
        return $false
    }

    $startTime = Get-Date
    $exitCode  = -1
    $proc      = $null
    $stdoutEvent = $null
    $stderrEvent = $null

    try {
        # Refresh current session PATH before launching child process
        try {
            $mPath = [Environment]::GetEnvironmentVariable("Path", [EnvironmentVariableTarget]::Machine)
            $uPath = [Environment]::GetEnvironmentVariable("Path", [EnvironmentVariableTarget]::User)
            $env:Path = "$mPath;$uPath"
        } catch {}

        # Launch child PowerShell process — inherits elevation from parent
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName               = (Get-Process -Id $PID).MainModule.FileName
        $psi.Arguments              = "-NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"$scriptPath`""
        $psi.UseShellExecute        = $false
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError  = $true
        $psi.CreateNoWindow         = $true
        $psi.WorkingDirectory       = $Script:EngineRoot

        $proc = New-Object System.Diagnostics.Process
        $proc.StartInfo = $psi

        $stdoutSB = New-Object System.Text.StringBuilder
        $stderrSB  = New-Object System.Text.StringBuilder

        $stdoutEvent = Register-ObjectEvent -InputObject $proc -EventName "OutputDataReceived" -Action {
            if ($EventArgs.Data) {
                [void]$Event.MessageData.Append($EventArgs.Data + "`n")
            }
        } -MessageData $stdoutSB

        $stderrEvent = Register-ObjectEvent -InputObject $proc -EventName "ErrorDataReceived" -Action {
            if ($EventArgs.Data) {
                [void]$Event.MessageData.Append($EventArgs.Data + "`n")
            }
        } -MessageData $stderrSB

        $timeoutSec = if ($Step.TimeoutSeconds) { [int]$Step.TimeoutSeconds } elseif ($Script:Config.StepTimeoutSeconds) { [int]$Script:Config.StepTimeoutSeconds } else { 1800 }
        $timeoutMs  = $timeoutSec * 1000

        $proc.Start() | Out-Null
        $proc.BeginOutputReadLine()
        $proc.BeginErrorReadLine()

        $completedInTime = $proc.WaitForExit($timeoutMs)
        if (-not $completedInTime) {
            Write-EngineLog "ZAMAN ASIMI: Adim [$($Step.Order)] $timeoutSec saniye icinde yanit vermedi. Surec zorla sonlandiriliyor..." "ERROR" $Queue
            try { $proc.Kill() } catch {}
            $exitCode = 1460 # ERROR_TIMEOUT
        } else {
            Start-Sleep -Milliseconds 100
            $exitCode = $proc.ExitCode
        }

        # Parse and relay output lines
        $outputLines = $stdoutSB.ToString() -split "`n" | Where-Object { $_.Trim() -ne "" }
        foreach ($line in $outputLines) {
            $logLevel = "INFO"
            if ($line -match "\[SUCCESS\]") { $logLevel = "SUCCESS" }
            elseif ($line -match "\[WARN\]")    { $logLevel = "WARN"    }
            elseif ($line -match "\[ERROR\]")   { $logLevel = "ERROR"   }
            elseif ($line -match "\[NOTE\]")    { $logLevel = "INFO"    }
            Write-EngineLog $line.Trim() $logLevel $Queue
        }

        # Relay stderr if present
        $errOutput = $stderrSB.ToString().Trim()
        if ($errOutput) {
            Write-EngineLog "[STDERR] $errOutput" "WARN" $Queue
        }

    } catch {
        Write-EngineLog "Script surec istisnasi: $_" "ERROR" $Queue
        $exitCode = -999
    } finally {
        if ($stdoutEvent) {
            Unregister-Event -SourceIdentifier $stdoutEvent.Name -ErrorAction SilentlyContinue
            Remove-Job -Job $stdoutEvent -Force -ErrorAction SilentlyContinue
        }
        if ($stderrEvent) {
            Unregister-Event -SourceIdentifier $stderrEvent.Name -ErrorAction SilentlyContinue
            Remove-Job -Job $stderrEvent -Force -ErrorAction SilentlyContinue
        }
        if ($proc) {
            try { $proc.Dispose() } catch {}
        }
        # Post-step session PATH refresh
        try {
            $m = [Environment]::GetEnvironmentVariable("Path", [EnvironmentVariableTarget]::Machine)
            $u = [Environment]::GetEnvironmentVariable("Path", [EnvironmentVariableTarget]::User)
            $env:Path = "$m;$u"
        } catch {}
    }

    $endTime = Get-Date
    $stepRecord.ExitCode    = $exitCode
    $stepRecord.EndTime     = ($endTime | Get-Date -Format "o")
    $stepRecord.DurationSec = [math]::Round(($endTime - $startTime).TotalSeconds, 1)

    Write-EngineLog "Adim suresi: $($stepRecord.DurationSec)s | Cikis kodu: $exitCode" "INFO" $Queue

    # --- Exit code interpretation ---
    # 0    = Success
    # 1638 = Already installed (MSI standard) -> treat as Success
    # 3010 = Success but reboot required
    # -1   = Script file not found or launch error
    # other = Error (critical or warning based on step config)

    if ($exitCode -eq 3010) {
        $stepRecord.Status      = "Success"
        $State.RebootPending    = $true
        $State.CurrentStepIndex = $StepIndex + 1
        Save-EngineState -State $State
        Register-RunOnceResume
        Write-EngineLog "Adim basarili - YENIDEN BASLAMA gerekiyor (Exit 3010)." "WARN" $Queue
        return "REBOOT"

    } elseif ($exitCode -in @(0, 1638)) {
        $stepRecord.Status = "Success"
        Save-EngineState -State $State
        Write-EngineLog "Adim [$($Step.Order)] BASARILI tamamlandi." "SUCCESS" $Queue
        return $true

    } elseif ($exitCode -eq 1618) {
        $errMsg = "MSI Kilit Hatasi (Exit 1618: Baska bir kurulum/guncelleme arka planda devam ediyor)."
        $stepRecord.ErrorMessage = $errMsg
        $stepRecord.Status = if ($Step.Critical) { "Failed" } else { "Warning" }
        Save-EngineState -State $State
        Write-EngineLog "$errMsg" "ERROR" $Queue
        return (-not $Step.Critical)

    } elseif ($exitCode -eq 1460) {
        $errMsg = "Adim zaman asimina ugradi (Exit 1460: Watchdog Timeout - $timeoutSec saniye asildi)."
        $stepRecord.ErrorMessage = $errMsg
        $stepRecord.Status = if ($Step.Critical) { "Failed" } else { "Warning" }
        Save-EngineState -State $State
        Write-EngineLog "$errMsg" "ERROR" $Queue
        return (-not $Step.Critical)

    } else {
        $errMsg = "Adim hata koduyla bitti: $exitCode"
        $stepRecord.ErrorMessage = $errMsg

        if ($Step.Critical) {
            $stepRecord.Status = "Failed"
            Save-EngineState -State $State
            Write-EngineLog "KRITIK HATA: $errMsg - Kurulum durduruluyor!" "ERROR" $Queue
            return $false
        } else {
            $stepRecord.Status = "Warning"
            Save-EngineState -State $State
            Write-EngineLog "Kritik olmayan hata: $errMsg - Devam ediliyor." "WARN" $Queue
            return $true
        }
    }
}

#endregion

#region --- Main Orchestrator ---

function Start-PostInstallProcess {
    param(
        [System.Collections.Concurrent.ConcurrentQueue[string]]$Queue = $null,
        [scriptblock]$StepStatusCallback = $null,
        [string[]]$SelectedStepIds = @()
    )

    $banner = @"
============================================================
  Antigravity Enterprise Post-Installation Engine v2.0.0
  Host    : $($env:COMPUTERNAME)
  Root    : $Script:EngineRoot
  Log     : $Script:LogFile
  Started : $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
============================================================
"@
    Write-EngineLog $banner "INFO" $Queue
    Write-EngineEventLog -Message "Antigravity Post-Installation baslatildi. Host: $env:COMPUTERNAME, Adim Sayisi: $($Script:Steps.Count)" -EntryType "Information" -EventId 1000

    $state = Get-EngineState
    $state.Status = "Running"
    Save-EngineState -State $state

    $startIndex = $state.CurrentStepIndex
    if ($startIndex -gt 0) {
        Write-EngineLog "RESUME MODU: Adim $($startIndex + 1) / $($Script:Steps.Count) noktasindan devam ediliyor." "WARN" $Queue
    }

    for ($i = $startIndex; $i -lt $Script:Steps.Count; $i++) {
        $step = $Script:Steps[$i]
        $state.CurrentStepIndex = $i
        Save-EngineState -State $state

        # Skip step if user customized the selection
        if ($SelectedStepIds.Count -gt 0 -and $SelectedStepIds -notcontains $step.Id) {
            Write-EngineLog "Adim [$($step.Order)] $($step.Title) ATLANDI (Kullanici tarafindan secilmedi)." "INFO" $Queue
            if ($null -ne $StepStatusCallback) {
                try { & $StepStatusCallback $i "Skipped" } catch {}
            }
            continue
        }

        if ($null -ne $StepStatusCallback) {
            try { & $StepStatusCallback $i "Running" } catch {}
        }

        $result = Invoke-EngineStep -Step $step -State $state -StepIndex $i -Queue $Queue

        switch ($result) {
            "REBOOT" {
                if ($null -ne $StepStatusCallback) { try { & $StepStatusCallback $i "Warning" } catch {} }
                Write-EngineLog "Kurulum duraklatildi. Yeniden baslama sonrasi otomatik devam edilecek." "WARN" $Queue
                return "REBOOT"
            }
            $true {
                if ($null -ne $StepStatusCallback) { try { & $StepStatusCallback $i "Success" } catch {} }
            }
            $false {
                if ($null -ne $StepStatusCallback) { try { & $StepStatusCallback $i "Failed" } catch {} }
                if ($step.Critical) {
                    $state.Status = "Failed"
                    Save-EngineState -State $state
                    Write-EngineLog "Kritik adim basarisiz oldu. Kurulum sonlandiriliyor." "ERROR" $Queue
                    return "FAILED"
                }
                # Non-critical: log and continue
            }
        }
    }

    # All done
    $state.Status       = "Completed"
    $state.RebootPending = $false
    $state.CurrentStepIndex = $Script:Steps.Count
    Save-EngineState -State $state
    Unregister-RunOnceResume

    $summary = @"
============================================================
  KURULUM TAMAMLANDI
  Toplam Adim     : $($Script:Steps.Count)
  Basarili        : $($state.CompletedSteps)
  Hatali          : $($state.FailedSteps)
  Tamamlanma      : $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
  Ozet Rapor      : $($Script:Config.SummaryReport)
============================================================
"@
    Write-EngineLog $summary "SUCCESS" $Queue
    Write-EngineEventLog -Message "Antigravity Post-Installation tamamlandi. Basarili: $($state.CompletedSteps), Hatali: $($state.FailedSteps)" -EntryType "Information" -EventId 1003
    return "COMPLETED"
}

#endregion

#region --- CLI Entry Point ---

# Only execute as entry point when run directly (not dot-sourced by UI)
$isDotSourced = ($MyInvocation.InvocationName -eq '.') -or
                ($MyInvocation.Line -like "*. *PostInstallEngine*") -or
                ($MyInvocation.Line -like "*. `"*PostInstallEngine*")

if (-not $isDotSourced) {
    if ($Reset) {
        if (Test-Path $Script:StateFile) {
            Remove-Item $Script:StateFile -Force -ErrorAction SilentlyContinue
            Write-EngineLog "State dosyasi sifirlandi." "SUCCESS"
        }
        Unregister-RunOnceResume
        Write-EngineLog "Engine sifirlandi. Tekrar baslatilabilir." "SUCCESS"
        exit 0
    }

    $outcome = Start-PostInstallProcess

    if ($outcome -eq "REBOOT") {
        Write-Host "`n[!] Sistem 30 saniye icinde yeniden baslatilacak. Iptal: shutdown /a" -ForegroundColor Yellow
        Start-Sleep -Seconds 2
        shutdown.exe /r /t 30 /c "Antigravity Post-Installation: Kurulum devam icin yeniden baslama."
        exit 0
    } elseif ($outcome -eq "FAILED") {
        Write-Host "`n[!] Kritik hata nedeniyle kurulum durdu. Log: $Script:LogFile" -ForegroundColor Red
        exit 1
    } else {
        Write-Host "`n[OK] Post-installation tamamlandi." -ForegroundColor Green
        exit 0
    }
}

#endregion
