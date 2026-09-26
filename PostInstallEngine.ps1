#Requires -Version 5.1
<#
.SYNOPSIS
    Antigravity Enterprise Post-Installation Engine
.DESCRIPTION
    State-machine driven, reboot-resilient post-installation engine.
    Designed for corporate imaging workflows (MDT/SCCM/Intune/standalone).
    Orchestrates installation modules sequentially, persists state across reboots,
    and manages a single RunOnce registry entry for automatic resume.
.NOTES
    Author  : Antigravity Enterprise
    Version : 2.1.0
    Requires: PowerShell 5.1+, .NET Framework 4.6+, Windows 10+
#>
[CmdletBinding(SupportsShouldProcess)]
# Variable names are deliberately unique: dot-sourcing this file (UI, tests) binds these parameters
# into the CALLER's scope, so a plain $Resume here would silently reset the caller's own $Resume.
param(
    [Alias("Resume")][switch]$CliResume,
    [Alias("Reset")][switch]$CliReset,
    [Alias("Headless")][switch]$CliHeadless
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
# PS 5.1 ConvertFrom-Json emits a JSON array as ONE object: assign first, then normalize to an array
$Script:Steps  = [System.IO.File]::ReadAllText($Script:StepsFile,  [System.Text.Encoding]::UTF8) | ConvertFrom-Json
$Script:Steps  = @($Script:Steps)

# Resolve paths from config with universal environment variable expansion
$Script:DefaultDataDir = Join-Path $env:ProgramData "ComputerMaintenancePro"
$Script:LogFile      = [System.Environment]::ExpandEnvironmentVariables($Script:Config.LogFile)
$Script:ErrorLogFile = [System.Environment]::ExpandEnvironmentVariables($Script:Config.ErrorLogFile)
$Script:StateFile    = [System.Environment]::ExpandEnvironmentVariables($Script:Config.StateFile)
$Script:SummaryReport= if ($Script:Config.SummaryReport) { [System.Environment]::ExpandEnvironmentVariables($Script:Config.SummaryReport) } else { Join-Path $Script:DefaultDataDir "Reports\PostInstall_Summary.md" }
$Script:DocsSyncPath = if ($Script:Config.DocsSyncPath) { [System.Environment]::ExpandEnvironmentVariables($Script:Config.DocsSyncPath) } else { "$env:USERPROFILE\Desktop\Antigravity\Docs" }

# Create runtime directories if they don't exist
foreach ($dir in @((Split-Path $Script:LogFile), (Split-Path $Script:ErrorLogFile), (Split-Path $Script:StateFile), (Split-Path $Script:SummaryReport), $Script:DocsSyncPath)) {
    if ($dir -and -not (Test-Path $dir)) {
        try { New-Item -Path $dir -ItemType Directory -Force | Out-Null } catch {}
    }
}

# Exit codes treated as success by the engine
$Script:SuccessExitCodes = @(0, 1638)
$Script:RebootExitCodes  = @(3010, 1641)

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

function Test-EngineStateMatchesSteps {
    <#
    .SYNOPSIS
        A persisted state is only reusable if it was built from the current steps.json.
    #>
    param($State)
    $stateIds = @($State.StepResults | ForEach-Object { $_.Id })
    $stepIds  = @($Script:Steps | ForEach-Object { $_.Id })
    if ($stateIds.Count -ne $stepIds.Count) { return $false }
    for ($i = 0; $i -lt $stepIds.Count; $i++) {
        if ($stateIds[$i] -ne $stepIds[$i]) { return $false }
    }
    return $true
}

function Get-EngineState {
    if (Test-Path $Script:StateFile) {
        try {
            $raw = Get-Content $Script:StateFile -Raw -ErrorAction Stop
            $state = $raw | ConvertFrom-Json
            # Validate structure integrity
            if ($null -ne $state.SessionId -and $null -ne $state.StepResults) {
                if (Test-EngineStateMatchesSteps -State $state) {
                    if ($state.PSObject.Properties.Name -notcontains "SelectedStepIds") {
                        $state | Add-Member -NotePropertyName SelectedStepIds -NotePropertyValue @() -Force
                    }
                    return $state
                }
                Write-EngineLog "State dosyasi guncel steps.json ile uyusmuyor, yeni oturum olusturuluyor." "WARN"
            } else {
                Write-EngineLog "State dosyasi gecersiz yapida, yeniden olusturuluyor." "WARN"
            }
        } catch {
            Write-EngineLog "State dosyasi okunamadi ($_), yeniden olusturuluyor." "WARN"
        }
    }
    return New-EngineState
}

function New-EngineState {
    param([string[]]$SelectedStepIds = @())

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
            Attempts     = 0
            ErrorMessage = $null
        }
    }

    return [PSCustomObject]@{
        SchemaVersion    = "2.1"
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
        SelectedStepIds  = @($SelectedStepIds)
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

    # Exactly ONE entry: registering both hives launches two concurrent resumes after reboot.
    # HKLM is preferred (survives profile issues); HKCU is only the fallback.
    try {
        Set-ItemProperty -Path $Script:RunOnceKeyHKLM -Name $Script:RunOnceName -Value $cmd -Force -ErrorAction Stop
        Remove-ItemProperty -Path $Script:RunOnceKeyHKCU -Name $Script:RunOnceName -ErrorAction SilentlyContinue
        Write-EngineLog "RunOnce HKLM kaydedildi." "SUCCESS"
    } catch {
        Write-EngineLog "HKLM RunOnce yazilamadi ($_), HKCU deneniyor." "WARN"
        try {
            Set-ItemProperty -Path $Script:RunOnceKeyHKCU -Name $Script:RunOnceName -Value $cmd -Force -ErrorAction Stop
            Write-EngineLog "RunOnce HKCU kaydedildi." "SUCCESS"
        } catch {
            Write-EngineLog "HKCU RunOnce yazma hatasi: $_ - Reboot sonrasi elle baslatin." "ERROR"
        }
    }
}

function Unregister-RunOnceResume {
    foreach ($path in @($Script:RunOnceKeyHKCU, $Script:RunOnceKeyHKLM)) {
        try {
            Remove-ItemProperty -Path $path -Name $Script:RunOnceName -ErrorAction SilentlyContinue
        } catch { }
    }
    Write-EngineLog "RunOnce kayitlari temizlendi." "INFO"
}

#endregion

#region --- Step Execution ---

function Stop-ProcessTree {
    param([int]$ProcessId)
    # Kill installers spawned by the module too (msiexec, setup.exe...), not only powershell.exe
    try { & taskkill.exe /PID $ProcessId /T /F 2>&1 | Out-Null } catch {}
}

function Write-StepOutputLine {
    param(
        [string]$Line,
        [System.Collections.Concurrent.ConcurrentQueue[string]]$Queue
    )
    if ([string]::IsNullOrWhiteSpace($Line)) { return }
    $logLevel = "INFO"
    if ($Line -match "\[SUCCESS\]|\[SKIP\]") { $logLevel = "SUCCESS" }
    elseif ($Line -match "\[WARN\]|\[UPGRADE\]") { $logLevel = "WARN" }
    elseif ($Line -match "\[ERROR\]") { $logLevel = "ERROR" }
    Write-EngineLog $Line.Trim() $logLevel $Queue
}

function Invoke-StepProcess {
    <#
    .SYNOPSIS
        Runs one module in a child PowerShell and streams its stdout line by line (live log).
        Returns the exit code; 1460 on watchdog timeout.
    #>
    param(
        [Parameter(Mandatory)][string]$ScriptPath,
        [Parameter(Mandatory)][int]$TimeoutSec,
        [System.Collections.Concurrent.ConcurrentQueue[string]]$Queue = $null
    )

    $proc = $null
    try {
        Update-EngineSessionPath

        # Force UTF-8 in the child so Turkish characters survive the pipe
        $escaped = $ScriptPath.Replace("'", "''")
        $command = "[Console]::OutputEncoding = [System.Text.Encoding]::UTF8; & '$escaped'; exit `$LASTEXITCODE"

        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName               = Join-Path $env:SystemRoot "System32\WindowsPowerShell\v1.0\powershell.exe"
        $psi.Arguments              = "-NoProfile -NonInteractive -ExecutionPolicy Bypass -Command `"$command`""
        $psi.UseShellExecute        = $false
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError  = $true
        $psi.StandardOutputEncoding = [System.Text.Encoding]::UTF8
        $psi.StandardErrorEncoding  = [System.Text.Encoding]::UTF8
        $psi.CreateNoWindow         = $true
        $psi.WorkingDirectory       = $Script:EngineRoot

        $proc = [System.Diagnostics.Process]::Start($psi)
        $stderrTask = $proc.StandardError.ReadToEndAsync()
        $lineTask   = $proc.StandardOutput.ReadLineAsync()
        $deadline   = (Get-Date).AddSeconds($TimeoutSec)
        $timedOut   = $false

        while ($true) {
            if ($lineTask.Wait(250)) {
                $line = $lineTask.Result
                if ($null -eq $line) { break }   # EOF: child closed stdout
                Write-StepOutputLine -Line $line -Queue $Queue
                $lineTask = $proc.StandardOutput.ReadLineAsync()
            } elseif ((Get-Date) -gt $deadline) {
                $timedOut = $true
                break
            }
        }

        if ($timedOut) {
            Write-EngineLog "ZAMAN ASIMI: $TimeoutSec saniye asildi. Surec agaci sonlandiriliyor..." "ERROR" $Queue
            Stop-ProcessTree -ProcessId $proc.Id
            return 1460  # ERROR_TIMEOUT
        }

        [void]$proc.WaitForExit(30000)
        $errOutput = ""
        if ($stderrTask.Wait(5000)) { $errOutput = $stderrTask.Result.Trim() }
        if ($errOutput) {
            Write-EngineLog "[STDERR] $errOutput" "WARN" $Queue
        }
        return $proc.ExitCode
    } catch {
        Write-EngineLog "Script surec istisnasi: $_" "ERROR" $Queue
        return -999
    } finally {
        if ($proc) { try { $proc.Dispose() } catch {} }
        Update-EngineSessionPath
    }
}

function Update-EngineSessionPath {
    try {
        $m = [Environment]::GetEnvironmentVariable("Path", [EnvironmentVariableTarget]::Machine)
        $u = [Environment]::GetEnvironmentVariable("Path", [EnvironmentVariableTarget]::User)
        $env:Path = "$m;$u"
    } catch {}
}

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
        return $(if ($Step.Critical) { "FAILED" } else { "WARNING" })
    }

    $timeoutSec = if ($Step.TimeoutSeconds) { [int]$Step.TimeoutSeconds } elseif ($Script:Config.StepTimeoutSeconds) { [int]$Script:Config.StepTimeoutSeconds } else { 1800 }
    $maxRetries = if ($null -ne $Script:Config.MaxRetriesPerStep) { [int]$Script:Config.MaxRetriesPerStep } else { 0 }

    $startTime = Get-Date
    $exitCode  = -1
    $attempt   = 0
    do {
        $attempt++
        if ($attempt -gt 1) {
            Write-EngineLog "Adim [$($Step.Order)] yeniden deneniyor (Deneme $attempt / $($maxRetries + 1))..." "WARN" $Queue
            Start-Sleep -Seconds 5
        }
        $exitCode = Invoke-StepProcess -ScriptPath $scriptPath -TimeoutSec $timeoutSec -Queue $Queue
        $retryable = ($exitCode -notin ($Script:SuccessExitCodes + $Script:RebootExitCodes)) -and
                     ($exitCode -ne 1460) -and ($Step.Retryable -ne $false)
    } while ($retryable -and $attempt -le $maxRetries)

    $endTime = Get-Date
    $stepRecord.ExitCode    = $exitCode
    $stepRecord.Attempts    = $attempt
    $stepRecord.EndTime     = ($endTime | Get-Date -Format "o")
    $stepRecord.DurationSec = [math]::Round(($endTime - $startTime).TotalSeconds, 1)

    Write-EngineLog "Adim suresi: $($stepRecord.DurationSec)s | Cikis kodu: $exitCode | Deneme: $attempt" "INFO" $Queue

    # --- Exit code interpretation ---
    # 0 / 1638      = Success (1638: already installed, MSI standard)
    # 3010 / 1641   = Success but reboot required
    # 1618          = MSI mutex busy
    # 1460          = Watchdog timeout
    # other         = Error (critical or warning based on step config)

    if ($exitCode -in $Script:RebootExitCodes) {
        $stepRecord.Status   = "Success"
        $State.RebootPending = $true

        if ($Step.AllowRebootIfTriggered -eq $false) {
            Save-EngineState -State $State
            Write-EngineLog "Adim basarili - yeniden baslatma gerekiyor, ancak bu adim icin kurulum sonuna ertelendi." "WARN" $Queue
            return "SUCCESS"
        }

        $State.CurrentStepIndex = $StepIndex + 1
        $State.Status           = "RebootPending"
        Save-EngineState -State $State
        Register-RunOnceResume
        Write-EngineLog "Adim basarili - YENIDEN BASLAMA gerekiyor (Exit $exitCode)." "WARN" $Queue
        return "REBOOT"

    } elseif ($exitCode -in $Script:SuccessExitCodes) {
        $stepRecord.Status = "Success"
        Save-EngineState -State $State
        Write-EngineLog "Adim [$($Step.Order)] BASARILI tamamlandi." "SUCCESS" $Queue
        return "SUCCESS"
    }

    $errMsg = switch ($exitCode) {
        1618    { "MSI Kilit Hatasi (Exit 1618: Baska bir kurulum/guncelleme arka planda devam ediyor)." }
        1460    { "Adim zaman asimina ugradi (Exit 1460: Watchdog Timeout - $timeoutSec saniye asildi)." }
        default { "Adim hata koduyla bitti: $exitCode" }
    }
    $stepRecord.ErrorMessage = $errMsg

    if ($Step.Critical) {
        $stepRecord.Status = "Failed"
        Save-EngineState -State $State
        Write-EngineLog "KRITIK HATA: $errMsg - Kurulum durduruluyor!" "ERROR" $Queue
        return "FAILED"
    }

    $stepRecord.Status = "Warning"
    Save-EngineState -State $State
    Write-EngineLog "Kritik olmayan hata: $errMsg - Devam ediliyor." "WARN" $Queue
    return "WARNING"
}

#endregion

#region --- Main Orchestrator ---

function Start-PostInstallProcess {
    param(
        [System.Collections.Concurrent.ConcurrentQueue[string]]$Queue = $null,
        [scriptblock]$StepStatusCallback = $null,
        [string[]]$SelectedStepIds = @(),
        [switch]$Resume
    )

    $banner = @"
============================================================
  Antigravity Enterprise Post-Installation Engine v2.1.0
  Host    : $($env:COMPUTERNAME)
  Root    : $Script:EngineRoot
  Log     : $Script:LogFile
  Started : $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
============================================================
"@
    Write-EngineLog $banner "INFO" $Queue
    Write-EngineEventLog -Message "Antigravity Post-Installation baslatildi. Host: $env:COMPUTERNAME, Adim Sayisi: $($Script:Steps.Count)" -EntryType "Information" -EventId 1000

    # Only an explicit resume (RunOnce after reboot) continues a previous session.
    # Every other run is a fresh session, so a finished/failed state can never swallow a new run.
    if ($Resume) {
        $state = Get-EngineState
        if ($state.Status -eq "Completed") {
            Write-EngineLog "Devam edilecek yarim oturum yok (onceki oturum tamamlanmis)." "INFO" $Queue
            Unregister-RunOnceResume
            return "COMPLETED"
        }
        # Selection made before the reboot wins over the (all-checked) resume selection
        if (@($state.SelectedStepIds).Count -gt 0) {
            $SelectedStepIds = @($state.SelectedStepIds)
        } else {
            $state.SelectedStepIds = @($SelectedStepIds)
        }
        $state.RebootPending = $false
    } else {
        Unregister-RunOnceResume
        $state = New-EngineState -SelectedStepIds $SelectedStepIds
    }

    $state.Status = "Running"
    Save-EngineState -State $state

    $startIndex = [int]$state.CurrentStepIndex
    if ($startIndex -gt 0) {
        Write-EngineLog "RESUME MODU: Adim $($startIndex + 1) / $($Script:Steps.Count) noktasindan devam ediliyor." "WARN" $Queue
        if ($null -ne $StepStatusCallback) {
            for ($j = 0; $j -lt $startIndex; $j++) {
                try { & $StepStatusCallback $j $state.StepResults[$j].Status } catch {}
            }
        }
    }

    for ($i = $startIndex; $i -lt $Script:Steps.Count; $i++) {
        $step = $Script:Steps[$i]
        $state.CurrentStepIndex = $i

        # Skip step if user customized the selection
        if ($SelectedStepIds.Count -gt 0 -and $SelectedStepIds -notcontains $step.Id) {
            $state.StepResults[$i].Status = "Skipped"
            Save-EngineState -State $state
            Write-EngineLog "Adim [$($step.Order)] $($step.Title) ATLANDI (Kullanici tarafindan secilmedi)." "INFO" $Queue
            if ($null -ne $StepStatusCallback) {
                try { & $StepStatusCallback $i "Skipped" } catch {}
            }
            continue
        }
        Save-EngineState -State $state

        if ($null -ne $StepStatusCallback) {
            try { & $StepStatusCallback $i "Running" } catch {}
        }

        $result = Invoke-EngineStep -Step $step -State $state -StepIndex $i -Queue $Queue

        if ($result -eq "REBOOT") {
            if ($null -ne $StepStatusCallback) { try { & $StepStatusCallback $i "Success" } catch {} }
            Write-EngineLog "Kurulum duraklatildi. Yeniden baslama sonrasi otomatik devam edilecek." "WARN" $Queue
            return "REBOOT"
        } elseif ($result -eq "WARNING") {
            if ($null -ne $StepStatusCallback) { try { & $StepStatusCallback $i "Warning" } catch {} }
        } elseif ($result -eq "SUCCESS") {
            if ($null -ne $StepStatusCallback) { try { & $StepStatusCallback $i "Success" } catch {} }
        } else {
            if ($null -ne $StepStatusCallback) { try { & $StepStatusCallback $i "Failed" } catch {} }
            $state.Status = "Failed"
            Save-EngineState -State $state
            Write-EngineLog "Kritik adim basarisiz oldu. Kurulum sonlandiriliyor." "ERROR" $Queue
            Write-EngineEventLog -Message "Antigravity Post-Installation kritik hata: $($step.Id)" -EntryType "Error" -EventId 1002
            return "FAILED"
        }
    }

    # All done
    $state.Status           = "Completed"
    $state.CurrentStepIndex = $Script:Steps.Count
    Save-EngineState -State $state
    Unregister-RunOnceResume

    $rebootNote = if ($state.RebootPending) { "EVET (ertelenmis)" } else { "Hayir" }
    $summary = @"
============================================================
  KURULUM TAMAMLANDI
  Toplam Adim     : $($Script:Steps.Count)
  Basarili        : $($state.CompletedSteps)
  Hatali          : $($state.FailedSteps)
  Reboot Gerekli  : $rebootNote
  Tamamlanma      : $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
  Ozet Rapor      : $Script:SummaryReport
============================================================
"@
    Write-EngineLog $summary "SUCCESS" $Queue
    Write-EngineEventLog -Message "Antigravity Post-Installation tamamlandi. Basarili: $($state.CompletedSteps), Hatali: $($state.FailedSteps)" -EntryType "Information" -EventId 1003
    return "COMPLETED"
}

function Get-RebootCountdownSeconds {
    if ($Script:Config.RebootCountdownSeconds) { return [int]$Script:Config.RebootCountdownSeconds }
    return 30
}

#endregion

#region --- CLI Entry Point ---

# Only execute as entry point when run directly (not dot-sourced by UI)
$isDotSourced = ($MyInvocation.InvocationName -eq '.') -or
                ($MyInvocation.Line -like "*. *PostInstallEngine*") -or
                ($MyInvocation.Line -like "*. `"*PostInstallEngine*")

if (-not $isDotSourced) {
    if ($CliReset) {
        if (Test-Path $Script:StateFile) {
            Remove-Item $Script:StateFile -Force -ErrorAction SilentlyContinue
            Write-EngineLog "State dosyasi sifirlandi." "SUCCESS"
        }
        Unregister-RunOnceResume
        Write-EngineLog "Engine sifirlandi. Tekrar baslatilabilir." "SUCCESS"
        exit 0
    }

    $outcome = Start-PostInstallProcess -Resume:$CliResume

    if ($outcome -eq "REBOOT") {
        $countdown = Get-RebootCountdownSeconds
        if ($Script:Config.AutoReboot -ne $false) {
            Write-Host "`n[!] Sistem $countdown saniye icinde yeniden baslatilacak. Iptal: shutdown /a" -ForegroundColor Yellow
            shutdown.exe /r /t $countdown /c "Computer Maintenance Pro: Kurulum devam icin yeniden baslama."
        } else {
            Write-Host "`n[!] Yeniden baslatma gerekiyor. Reboot sonrasi kurulum otomatik devam edecek." -ForegroundColor Yellow
        }
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
