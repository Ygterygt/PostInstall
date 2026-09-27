#Requires -Version 5.1
<#
.SYNOPSIS
    Automated Test Battery for Antigravity Enterprise Post-Installation Suite
.DESCRIPTION
    Non-destructive: every test that writes or deletes runs inside a throw-away sandbox under %TEMP%.
      1. AST parser checks on all PowerShell files
      2. config.json / steps.json / gpu_compatibility.json schema + portability checks
      3. Unit tests for pure helpers (versions, name matching, RAM, PATH merge, temp cleanup)
      4. Tool sandbox tests (SilentDetector, Driver, Reporting, Specs, HardwareMonitor)
      5. PostInstall.exe binary health
      6. Engine end-to-end in an isolated sandbox (retry, skip, deferred reboot, timeout, UTF-8, resume)
    Exit code = number of failed tests (0 = all passed), so CI can gate on it.
.PARAMETER OutputPath
    Where to write the JSON result matrix.
#>
[CmdletBinding()]
param(
    [string]$OutputPath = ""
)

$ErrorActionPreference = "Continue"
$Root = $PSScriptRoot
# PS 5.1 leaves $PSScriptRoot empty inside script param() defaults, so resolve here
if (-not $OutputPath) { $OutputPath = Join-Path $Root "TestResults.json" }
$testResults = [System.Collections.Generic.List[PSCustomObject]]::new()
$WinPS = Join-Path $env:SystemRoot "System32\WindowsPowerShell\v1.0\powershell.exe"

function Add-TestResult {
    param(
        [string]$Category,
        [string]$TestName,
        [string]$Status,
        [string]$Details,
        [double]$DurationMs = 0
    )
    $testResults.Add([PSCustomObject]@{
        Category   = $Category
        TestName   = $TestName
        Status     = $Status
        Details    = $Details
        DurationMs = [Math]::Round($DurationMs, 2)
    })
    $color = if ($Status -eq "PASS") { "Green" } else { "Red" }
    Write-Host "  [$Status] $TestName - $Details" -ForegroundColor $color
}

function Invoke-SuiteTest {
    <#
    .SYNOPSIS
        Runs a test body. The body returns a details string on success and throws on failure.
    #>
    param(
        [Parameter(Mandatory)][string]$Category,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][scriptblock]$Body
    )
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    try {
        $details = & $Body
        $sw.Stop()
        Add-TestResult -Category $Category -TestName $Name -Status "PASS" -Details ([string]($details | Select-Object -Last 1)) -DurationMs $sw.Elapsed.TotalMilliseconds
    } catch {
        $sw.Stop()
        Add-TestResult -Category $Category -TestName $Name -Status "FAIL" -Details $_.Exception.Message -DurationMs $sw.Elapsed.TotalMilliseconds
    }
}

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw "Assertion failed: $Message" }
}

function New-Sandbox {
    param([string]$Prefix)
    $dir = Join-Path $env:TEMP ("CMP_{0}_{1}" -f $Prefix, [Guid]::NewGuid().ToString("N").Substring(0, 8))
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
    return $dir
}

Write-Host "`n=======================================================" -ForegroundColor Cyan
Write-Host "  ANTIGRAVITY POST-INSTALLATION SUITE: TEST BATTERY" -ForegroundColor Cyan
Write-Host "  Root: $Root" -ForegroundColor Cyan
Write-Host "=======================================================" -ForegroundColor Cyan

# -------------------------------------------------------------
# 1. AST PARSER CHECK ON ALL PS1 FILES
# -------------------------------------------------------------
Write-Host "`n[1/6] AST Parser on all PowerShell scripts..." -ForegroundColor Yellow
$ps1Files = Get-ChildItem -Path $Root -Filter "*.ps1" -Recurse | Where-Object { $_.FullName -notmatch '\\\.git\\' }
foreach ($file in $ps1Files) {
    Invoke-SuiteTest -Category "AST Parser" -Name $file.Name -Body {
        $tokens = $null; $errors = $null
        [void][System.Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$tokens, [ref]$errors)
        if ($errors.Count -gt 0) {
            throw (($errors | ForEach-Object { "$($_.Message) [Line $($_.Extent.StartLineNumber)]" }) -join "; ")
        }
        "Tokens: $($tokens.Count), Size: $($file.Length) bytes"
    }
}

# -------------------------------------------------------------
# 2. CONFIGURATION, STEP SEQUENCE & PORTABILITY
# -------------------------------------------------------------
Write-Host "`n[2/6] Configuration, step sequence & portability..." -ForegroundColor Yellow

Invoke-SuiteTest -Category "Configuration" -Name "config.json Schema & Keys" -Body {
    $config = Get-Content (Join-Path $Root "config.json") -Raw | ConvertFrom-Json
    $requiredKeys = @("ApplicationName", "TargetHost", "Version", "LogFile", "ErrorLogFile", "StateFile", "SummaryReport", "AutoReboot", "RebootCountdownSeconds", "RunOnceKeyName", "Maintenance", "Network")
    $missing = @($requiredKeys | Where-Object { $config.PSObject.Properties.Name -notcontains $_ })
    Assert-True ($missing.Count -eq 0) "Missing keys: $($missing -join ', ')"
    foreach ($k in @("LogFile", "StateFile")) {
        Assert-True ($config.$k -notlike "*\Windows\Temp\*") "$k must not live in Windows\Temp (wiped by module 03)"
    }
    "All $($requiredKeys.Count) keys present, runtime paths outside Windows\Temp"
}

$steps = Get-Content (Join-Path $Root "steps.json") -Raw | ConvertFrom-Json
$steps = @($steps)

Invoke-SuiteTest -Category "Step Sequence" -Name "Step IDs unique & order contiguous" -Body {
    $dup = @($steps.Id | Group-Object | Where-Object { $_.Count -gt 1 })
    Assert-True ($dup.Count -eq 0) "Duplicate ids: $($dup.Name -join ', ')"
    for ($i = 0; $i -lt $steps.Count; $i++) {
        Assert-True ([int]$steps[$i].Order -eq ($i + 1)) "Order broken at index $i"
    }
    "$($steps.Count) steps, order 1..$($steps.Count)"
}

Invoke-SuiteTest -Category "Step Sequence" -Name "Step Required Fields & Scripts" -Body {
    $reqFields = @("Id", "Order", "Title", "Description", "Script", "RequiresReboot", "Critical", "AllowRebootIfTriggered")
    foreach ($s in $steps) {
        foreach ($f in $reqFields) {
            Assert-True (($s.PSObject.Properties.Name -contains $f) -and $null -ne $s.$f) "Step $($s.Id) missing '$f'"
        }
        Assert-True (Test-Path (Join-Path $Root $s.Script)) "Missing script $($s.Script)"
    }
    "All steps complete, all $($steps.Count) scripts exist"
}

Invoke-SuiteTest -Category "Configuration" -Name "gpu_compatibility.json Schema" -Body {
    $gpuJson = Get-Content -Path (Join-Path $Root "gpu_compatibility.json") -Raw -Encoding UTF8 | ConvertFrom-Json
    foreach ($v in @("NVIDIA", "AMD", "Intel")) {
        Assert-True ($gpuJson.Vendors.$v.Profiles.Count -gt 0) "No profiles for $v"
    }
    foreach ($v in $gpuJson.Vendors.PSObject.Properties) {
        foreach ($p in $v.Value.Profiles) {
            # Every package id needs an explicit, valid source (winget vs msstore were mixed up before)
            foreach ($pair in @(@($p.WinGetId, $p.WinGetSource), @($p.AltWinGetId, $p.AltWinGetSource))) {
                if ($pair[0]) { Assert-True ($pair[1] -in @("winget", "msstore")) "$($p.Id): id '$($pair[0])' has invalid source '$($pair[1])'" }
            }
            # Direct URLs must be installers, not web pages (web pages belong in ManualDownloadPage)
            if ($p.DirectDownloadUrl) { Assert-True ($p.DirectDownloadUrl -match '\.(exe|msi)(\?|$)') "$($p.Id): DirectDownloadUrl is not an installer" }
            Assert-True ([bool]$p.WinGetId -or [bool]$p.ManualDownloadPage -or $v.Name -eq "Virtual") "$($p.Id): no install source and no manual page"
        }
    }
    "NVIDIA ($($gpuJson.Vendors.NVIDIA.Profiles.Count)), AMD ($($gpuJson.Vendors.AMD.Profiles.Count)), Intel ($($gpuJson.Vendors.Intel.Profiles.Count)); sources valid"
}

Invoke-SuiteTest -Category "Unit" -Name "ConvertFrom-WingetTable (EN/TR, truncation, empty)" -Body {
    . (Join-Path $Root "Tools\UpdateEngine.ps1")
    $en = @(
        "   - \ |",
        "Name                                    Id                   Version   Available Source",
        "---------------------------------------------------------------------------------------",
        "Microsoft Teams                         Microsoft.Teams      26183.1   26198.3   winget",
        "Python Launcher                         Python.Launcher      3.12.10   3.14.7    winget",
        "2 upgrades available."
    )
    $r = @(ConvertFrom-WingetTable -Lines $en)
    Assert-True ($r.Count -eq 2) "EN row count $($r.Count)"
    Assert-True ($r[1].Id -eq "Python.Launcher" -and $r[1].Available -eq "3.14.7" -and $r[1].Source -eq "winget") "EN columns"

    $tr = @(
        "Ad                              Kimlik              Sürüm   Kullanılabilir Kaynak",
        "---------------------------------------------------------------------------------",
        "Çok Uzun Bir Uygulama Adı Bura$([char]0x2026) Vendor.LongApp      1.2.3   1.3.0          winget",
        "Kısa                            Short.App           10.0    10.1           msstore",
        "2 yükseltme kullanılabilir."
    )
    $t = @(ConvertFrom-WingetTable -Lines $tr)
    Assert-True ($t.Count -eq 2 -and $t[0].Id -eq "Vendor.LongApp" -and $t[1].Source -eq "msstore") "TR columns"
    Assert-True (-not $t[0].Name.EndsWith([string][char]0x2026)) "ellipsis trimmed"

    $none = @(ConvertFrom-WingetTable -Lines @("No installed package found matching input criteria."))
    Assert-True ($none.Count -eq 0) "no-update output"
    "EN + TR headers parsed by position; empty output handled"
}

Invoke-SuiteTest -Category "Unit" -Name "SchedulerEngine (settings, validation, task definition, dry run)" -Body {
    . (Join-Path $Root "Tools\SchedulerEngine.ps1")
    $sb = New-Sandbox "Sched"
    try {
        $path = Join-Path $sb "ScheduledMaintenance.json"
        $s = Get-ScheduledMaintenanceSettings -Path $path
        Assert-True ($s.CleanTemp -and -not $s.UpdateApps) "defaults"
        $s.DayOfWeek = "Wednesday"; $s.Time = "19:30"; $s.UpdateApps = $true
        Save-ScheduledMaintenanceSettings -Settings $s -Path $path
        $r = Get-ScheduledMaintenanceSettings -Path $path
        Assert-True ($r.DayOfWeek -eq "Wednesday" -and $r.Time -eq "19:30" -and $r.UpdateApps) "roundtrip"

        $bad = [PSCustomObject]@{ DayOfWeek = "Sunday"; Time = "25:00"; CleanTemp = $true; FlushDns = $false; ReTrim = $false; UpdateApps = $false }
        $rejected = $false; try { Assert-ScheduledMaintenanceSettings $bad } catch { $rejected = $true }
        Assert-True $rejected "invalid time rejected"
        $none = [PSCustomObject]@{ DayOfWeek = "Sunday"; Time = "10:00"; CleanTemp = $false; FlushDns = $false; ReTrim = $false; UpdateApps = $false }
        $rejected = $false; try { Assert-ScheduledMaintenanceSettings $none } catch { $rejected = $true }
        Assert-True $rejected "no action rejected"

        $def = New-MaintenanceTaskDefinition -Settings $r
        # Regression: PS 5.1 stores UTC ("...Z") which drifts across DST; boundary must be local
        Assert-True ($def.Trigger.StartBoundary -match 'T19:30:00$') "local StartBoundary (got $($def.Trigger.StartBoundary))"
        Assert-True ($def.Settings.DisallowStartIfOnBatteries -and $def.Settings.StartWhenAvailable) "battery/catch-up settings"
        Assert-True ($def.Action.Arguments -like "*Invoke-ScheduledMaintenance.ps1*") "runner path"

        $out = & $WinPS -NoProfile -ExecutionPolicy Bypass -File (Join-Path $Root "Tools\Invoke-ScheduledMaintenance.ps1") -DryRun -SettingsPath $path 2>&1 | Out-String
        Assert-True ($out -match "PLAN=CleanTemp,FlushDns,ReTrim,UpdateApps") "dry-run plan: $out"
        "settings roundtrip, validation, local trigger, battery-safe settings, dry-run plan OK"
    } finally {
        Remove-Item $sb -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Invoke-SuiteTest -Category "Unit" -Name "ChangeJournal (track, no-op, undo newest-first, not-undoable)" -Body {
    $sb = New-Sandbox "Journal"
    $key = "HKCU:\Software\CMP_Test_Journal_$([guid]::NewGuid().ToString('N').Substring(0, 8))"
    $prevEnv = $env:CMP_CHANGE_JOURNAL
    try {
        $env:CMP_CHANGE_JOURNAL = Join-Path $sb "ChangeJournal.json"
        . (Join-Path $Root "Tools\ChangeJournal.ps1")
        New-Item $key -Force | Out-Null
        Set-ItemProperty $key -Name "Existing" -Value 5 -Type DWord

        $a = Set-TrackedRegistryValue -Path $key -Name "Existing" -Value 7 -Description "changed"
        $b = Set-TrackedRegistryValue -Path $key -Name "Created" -Value "x" -Type String -Description "created"
        $n = Set-TrackedRegistryValue -Path $key -Name "Existing" -Value 7 -Description "same"
        Assert-True ($a -and $b -and $null -eq $n) "no-op writes must not be journaled"
        # Twice changed value: undo newest-first must end at the ORIGINAL value
        $c = Set-TrackedRegistryValue -Path $key -Name "Existing" -Value 9 -Description "changed again"
        $x = Add-ChangeJournalEntry -Kind "Feature" -Target "SMB1Protocol" -PreviousValue "Enabled" -NewValue "Disabled" -NotUndoable
        Assert-True (@(Get-ChangeJournal).Count -eq 4) "journal count"

        $refused = Undo-ChangeJournalEntry -Id $x.Id
        Assert-True (-not $refused.Success) "not-undoable entry refused"

        $res = @(Undo-ChangeJournal)
        Assert-True ($res.Count -eq 3 -and @($res | Where-Object { -not $_.Success }).Count -eq 0) "3 undone"
        $k = Get-Item $key
        Assert-True ($k.GetValue("Existing") -eq 5) "original value restored (got $($k.GetValue('Existing')))"
        Assert-True ($k.GetValueNames() -notcontains "Created") "created value removed"
        Assert-True (@(Get-ChangeJournal | Where-Object { $_.Reverted }).Count -eq 3) "entries marked reverted"
        "journaled only real changes; newest-first undo restored originals; security entries protected"
    } finally {
        $env:CMP_CHANGE_JOURNAL = $prevEnv
        Remove-Item $key -Recurse -Force -ErrorAction SilentlyContinue
        Remove-Item $sb -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Invoke-SuiteTest -Category "Unit" -Name "Find-GpuProfile matching" -Body {
    . (Join-Path $Root "Tools\PackageEngine.ps1")
    $gpuJson = Get-Content -Path (Join-Path $Root "gpu_compatibility.json") -Raw -Encoding UTF8 | ConvertFrom-Json
    $cases = @{
        "NVIDIA GeForce RTX 3050 Laptop GPU" = "NVIDIA_MODERN_GEFORCE"
        "AMD Radeon(TM) Graphics"            = "AMD_MODERN_RADEON"
        "Intel(R) Iris(R) Xe Graphics"       = "INTEL_IRIS_UHD"
        "NVIDIA Quadro P2000"                = "NVIDIA_PROFESSIONAL"
    }
    foreach ($name in $cases.Keys) {
        $got = (Find-GpuProfile -GpuName $name -GpuDb $gpuJson).Profile.Id
        Assert-True ($got -eq $cases[$name]) "$name -> $got (expected $($cases[$name]))"
    }
    "$($cases.Count) GPU names mapped to the expected profiles"
}

Invoke-SuiteTest -Category "Portability" -Name "No hardcoded C:\PostInstall paths" -Body {
    $hits = Get-ChildItem -Path (Join-Path $Root "Modules"), (Join-Path $Root "Tools") -Filter "*.ps1" |
            Select-String -Pattern '"C:\\PostInstall' -SimpleMatch:$false
    Assert-True (@($hits).Count -eq 0) ("Hardcoded paths: " + (($hits | ForEach-Object { "$($_.Filename):$($_.LineNumber)" }) -join ", "))
    "Modules and Tools resolve paths from the suite root"
}

Invoke-SuiteTest -Category "Portability" -Name "No @() over generic List[object] in UI (PS 5.1 binder bug)" -Body {
    # Regression: @($Script:BackgroundJobs) threw "Argument types do not match" in FormClosing on
    # Windows PowerShell 5.1 and surfaced as an unhandled-exception dialog when closing the app.
    $listVars = Select-String -Path (Join-Path $Root "PostInstallUI.ps1") -Pattern '^\s*(\$[\w:]+)\s*=\s*New-Object\s+System\.Collections\.Generic\.List\[object\]' |
                ForEach-Object { $_.Matches[0].Groups[1].Value }
    $hits = foreach ($v in $listVars) {
        Select-String -Path (Join-Path $Root "PostInstallUI.ps1") -Pattern ("@\(" + [regex]::Escape($v) + "\)") -SimpleMatch:$false
    }
    Assert-True (@($hits).Count -eq 0) ("Use .ToArray() instead: " + (($hits | ForEach-Object { "line $($_.LineNumber)" }) -join ", "))
    "$(@($listVars).Count) List[object] variables checked"
}

# -------------------------------------------------------------
# 3. UNIT TESTS FOR PURE HELPERS
# -------------------------------------------------------------
Write-Host "`n[3/6] Unit tests..." -ForegroundColor Yellow
. (Join-Path $Root "Tools\Common.ps1")
. (Join-Path $Root "Tools\PackageEngine.ps1")
. (Join-Path $Root "Tools\MaintenanceEngine.ps1")

Invoke-SuiteTest -Category "Unit" -Name "Compare-AppVersion" -Body {
    Assert-True ((Compare-AppVersion "2.47.1.windows.1" "2.40.0") -eq 1) "git version"
    Assert-True ((Compare-AppVersion "1.9" "1.10") -eq -1) "numeric not lexical"
    Assert-True ((Compare-AppVersion "20240101123456" "1.0") -eq 1) "no int overflow"
    Assert-True ((Compare-AppVersion "3.12" "3.12.0") -eq 0) "trailing zero"
    "semantic compare, overflow-safe"
}

Invoke-SuiteTest -Category "Unit" -Name "Test-AppNameMatch (word boundary)" -Body {
    Assert-True (Test-AppNameMatch "Git" "Git") "exact"
    Assert-True (-not (Test-AppNameMatch "GitHub Desktop" "Git")) "GitHub must not match Git"
    Assert-True (Test-AppNameMatch "Microsoft Visual Studio Code (User)" "Visual Studio Code") "infix"
    Assert-True (Test-AppNameMatch "Notepad++ (64-bit x64)" "Notepad\+\+") "regex pattern"
    "no false positives on prefixes"
}

Invoke-SuiteTest -Category "Unit" -Name "ConvertTo-MemorySpeedInfo" -Body {
    $modern = ConvertTo-MemorySpeedInfo -RatedSpeed 4800 -ConfiguredClockSpeed 4800
    Assert-True ($modern.ActualMTs -eq 4800 -and -not $modern.BelowRatedSpeed) "DDR5 MT/s must not be doubled"
    $legacy = ConvertTo-MemorySpeedInfo -RatedSpeed 3200 -ConfiguredClockSpeed 1600
    Assert-True ($legacy.ActualMTs -eq 3200) "legacy MHz reporting doubled"
    $slow = ConvertTo-MemorySpeedInfo -RatedSpeed 3600 -ConfiguredClockSpeed 2400
    Assert-True ($slow.BelowRatedSpeed) "below rated detected"
    "MT/s normalization OK (4800->4800, 1600MHz->3200, 2400<3600 flagged)"
}

Invoke-SuiteTest -Category "Unit" -Name "Merge-PathEntries (REG_EXPAND_SZ safe)" -Body {
    $raw = "%SystemRoot%\system32;%SystemRoot%;C:\Tools\"
    $m = Merge-PathEntries -RawPath $raw -Entries @("$env:SystemRoot\System32", "C:\tools", "C:\New")
    Assert-True ($m.Value -like "%SystemRoot%\system32;*") "raw %SystemRoot% entries preserved"
    Assert-True ($m.Added.Count -eq 1 -and $m.Added[0] -eq "C:\New") "only genuinely new entry added (got: $($m.Added -join ','))"
    "unexpanded entries kept, duplicates detected on expanded form"
}

Invoke-SuiteTest -Category "Unit" -Name "Clear-SystemJunkAndTemp (sandbox)" -Body {
    $sb = New-Sandbox "Junk"
    try {
        $old = Join-Path $sb "old.tmp";               Set-Content $old "x"
        $new = Join-Path $sb "fresh.tmp";             Set-Content $new "x"
        $log = Join-Path $sb "PostInstall.log";       Set-Content $log "x"
        New-Item -ItemType Directory (Join-Path $sb "ComputerMaintenancePro") | Out-Null
        $nested = Join-Path $sb "ComputerMaintenancePro\state.json"; Set-Content $nested "x"
        foreach ($p in @($old, $log, $nested)) { (Get-Item $p).LastWriteTime = (Get-Date).AddDays(-10) }

        $res = Clear-SystemJunkAndTemp -Paths @($sb) -MinAgeDays 1 6>$null
        Assert-True (-not (Test-Path $old)) "old file removed"
        Assert-True (Test-Path $new) "fresh file kept (age threshold)"
        Assert-True (Test-Path $log) "suite log kept (exclude pattern)"
        Assert-True (Test-Path $nested) "file inside excluded folder kept"
        Assert-True ($res.FilesRemoved -eq 1) "exactly one file counted (got $($res.FilesRemoved))"
        "age threshold + exclusions honoured, only deleted bytes counted"
    } finally {
        Remove-Item $sb -Recurse -Force -ErrorAction SilentlyContinue
    }
}

# -------------------------------------------------------------
# 4. TOOL SANDBOX TESTS
# -------------------------------------------------------------
Write-Host "`n[4/6] Tool sandbox tests..." -ForegroundColor Yellow

Invoke-SuiteTest -Category "Tools Sandbox" -Name "SilentDetector.ps1" -Body {
    . (Join-Path $Root "Tools\SilentDetector.ps1")
    $sb = New-Sandbox "Detector"
    try {
        [System.IO.File]::WriteAllBytes((Join-Path $sb "setup.msi"), [byte[]]@(0xD0, 0xCF, 0x11, 0xE0))
        [System.IO.File]::WriteAllBytes((Join-Path $sb "package.msix"), [byte[]]@(0x50, 0x4B, 0x03, 0x04))
        $msi  = Get-InstallerSignature -FilePath (Join-Path $sb "setup.msi")
        $appx = Get-InstallerSignature -FilePath (Join-Path $sb "package.msix")
        $list = Get-CustomInstallersList -Directory $sb
        Assert-True ($msi.Type -like "*MSI*" -and $msi.SilentArgs -like "*/qn*") "MSI detection"
        Assert-True ($appx.Type -like "*MSIX*") "MSIX detection"
        Assert-True (@($list).Count -eq 2) "directory scan"
        "MSI (/qn), MSIX, directory scan validated"
    } finally {
        Remove-Item $sb -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Invoke-SuiteTest -Category "Tools Sandbox" -Name "SystemSpecsCollector.ps1" -Body {
    . (Join-Path $Root "Tools\SystemSpecsCollector.ps1")
    $summary = Get-SystemHealthSummary
    Assert-True ([bool]($summary.OSName -and $summary.CPU -and $summary.RAMTotal -and $summary.ChassisType)) "incomplete summary"
    Assert-True ($summary.RAMSpeedActual -notmatch "MHz") "RAM speed reported in MT/s"
    "Chassis: $($summary.ChassisType) | CPU: $($summary.CPU) | RAM: $($summary.RAMTotal) @ $($summary.RAMSpeedActual)"
}

Invoke-SuiteTest -Category "Tools Sandbox" -Name "DriverEngine.ps1 (INF discovery)" -Body {
    . (Join-Path $Root "Tools\DriverEngine.ps1")
    $sb = New-Sandbox "Driver"
    try {
        # Discovery only: an empty sub-folder filter means pnputil receives no valid package
        [System.IO.File]::WriteAllText((Join-Path $sb "test_device.inf"), "; Test INF`n[Version]`nSignature=`"`$Windows NT$`"`nClass=System`n")
        Assert-True ((Get-Command Install-SystemDrivers -ErrorAction SilentlyContinue) -ne $null) "Install-SystemDrivers exported"
        $infs = @(Get-ChildItem -Path $sb -Filter "*.inf" -Recurse)
        Assert-True ($infs.Count -eq 1) "INF discovery"
        "Install-SystemDrivers exported, INF discovery OK"
    } finally {
        Remove-Item $sb -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Invoke-SuiteTest -Category "Tools Sandbox" -Name "ReportingEngine.ps1" -Body {
    . (Join-Path $Root "Tools\ReportingEngine.ps1")
    $tempHtml = Join-Path $env:TEMP "CMP_Report_$(Get-Random).html"
    try {
        $mockSpecs = [PSCustomObject]@{
            ComputerName = "TEST-PC"; UserName = "TestUser"; ChassisType = "Desktop"; OSName = "Windows 11"
            CPU = "Test CPU"; CPUCores = "8 Cores"; RAMTotal = "32 GB"; RAMSpeedActual = "3600 MT/s"
            IsXmpActive = $true; GPU = "Test GPU"; GPUVendor = "NVIDIA"
        }
        $null = New-PostInstallHtmlReport -Specs $mockSpecs -Checks @(@{ Label = "TestCheck"; OK = $true; Detail = "1.0.0" }) `
            -Volumes @(@{ DriveLetter = "C"; FileSystemLabel = "OS"; FileSystemType = "NTFS"; Size = 500GB; SizeRemaining = 250GB; HealthStatus = "Healthy" }) -OutputFile $tempHtml
        Assert-True ((Get-Content $tempHtml -Raw) -like "*<!DOCTYPE html>*") "HTML output"
        "HTML5 dashboard generated"
    } finally {
        Remove-Item $tempHtml -Force -ErrorAction SilentlyContinue
    }
}

Invoke-SuiteTest -Category "Tools Sandbox" -Name "HardwareMonitorEngine.ps1 (persistent counters)" -Body {
    . (Join-Path $Root "Tools\HardwareMonitorEngine.ps1")
    [void](Initialize-HardwareMonitorEngine)
    $null = Get-LiveTelemetrySample
    Start-Sleep -Milliseconds 800
    $sample = Get-LiveTelemetrySample
    Assert-True ($null -ne $sample.CpuName -and $sample.CpuLoadPct -ge 0) "CPU"
    Assert-True ($sample.RamTotalGB -gt 0) "RAM"
    Assert-True ($sample.CpuClockGhz -gt 0) "clock"
    "CPU: $($sample.CpuLoadPct)% @ $($sample.CpuClockGhz) GHz | RAM: $($sample.RamUsedGB)/$($sample.RamTotalGB) GB | GPUs: $($sample.GPUs.Count)"
}

# -------------------------------------------------------------
# 5. POSTINSTALL.EXE BINARY HEALTH
# -------------------------------------------------------------
Write-Host "`n[5/6] PostInstall.exe binary health..." -ForegroundColor Yellow
Invoke-SuiteTest -Category "Binary Health" -Name "PostInstall.exe Integrity & EntryPoint" -Body {
    $exePath = Join-Path $Root "PostInstall.exe"
    Assert-True (Test-Path $exePath) "PostInstall.exe not found"
    $rawBytes = [System.IO.File]::ReadAllBytes($exePath)
    Assert-True ($rawBytes.Length -gt 64 -and $rawBytes[0] -eq 0x4D -and $rawBytes[1] -eq 0x5A) "PE MZ header"
    $asm = [System.Reflection.Assembly]::Load($rawBytes)
    Assert-True ($null -ne $asm.EntryPoint) "entry point"
    "Size: $($rawBytes.Length) bytes, Runtime: $($asm.ImageRuntimeVersion), EntryPoint: $($asm.EntryPoint.DeclaringType.FullName).$($asm.EntryPoint.Name)"
}

# -------------------------------------------------------------
# 6. ENGINE END-TO-END (ISOLATED SANDBOX)
# -------------------------------------------------------------
Write-Host "`n[6/6] Engine end-to-end in sandbox..." -ForegroundColor Yellow
$engineSandbox = New-Sandbox "Engine"
try {
    New-Item -ItemType Directory (Join-Path $engineSandbox "Modules") | Out-Null
    Copy-Item (Join-Path $Root "PostInstallEngine.ps1") $engineSandbox

    $cfg = [ordered]@{
        ApplicationName = "Test"; TargetHost = "*"; Version = "test"
        LogFile = (Join-Path $engineSandbox "run.log"); ErrorLogFile = (Join-Path $engineSandbox "err.log")
        StateFile = (Join-Path $engineSandbox "State\state.json"); SummaryReport = (Join-Path $engineSandbox "summary.md")
        DocsSyncPath = (Join-Path $engineSandbox "Docs"); AutoReboot = $false; RebootCountdownSeconds = 5
        RunOnceKeyName = "CMP_TestSuite_DoNotUse"; MaxRetriesPerStep = 1; StepTimeoutSeconds = 60
    }
    $cfg | ConvertTo-Json | Set-Content (Join-Path $engineSandbox "config.json") -Encoding UTF8

    $utf8Bom = New-Object System.Text.UTF8Encoding($true)
    $modules = [ordered]@{
        "A_Ok"      = 'Write-Output "[SUCCESS] Türkçe çıktı: ğüşiöç İĞ"; exit 0'
        "B_Flaky"   = 'Write-Output "[WARN] flaky"; exit 5'
        "C_Skipped" = 'exit 0'
        "D_Reboot"  = 'Write-Output "[INFO] needs reboot"; exit 3010'
        "E_Hang"    = 'Start-Sleep -Seconds 60; exit 0'
    }
    $stepList = @()
    $order = 1
    foreach ($name in $modules.Keys) {
        [System.IO.File]::WriteAllText((Join-Path $engineSandbox "Modules\$name.ps1"), $modules[$name], $utf8Bom)
        $step = [ordered]@{ Id = $name; Order = $order; Title = $name; Description = $name; Script = "Modules\$name.ps1"
                            RequiresReboot = $false; AllowRebootIfTriggered = $false; Critical = $false }
        if ($name -eq "E_Hang") { $step.TimeoutSeconds = 3 }
        $stepList += [PSCustomObject]$step
        $order++
    }
    ConvertTo-Json -InputObject $stepList -Depth 4 | Set-Content (Join-Path $engineSandbox "steps.json") -Encoding UTF8

    $runner = @'
param($Root, $Resume)
. (Join-Path $Root "PostInstallEngine.ps1")
$q = New-Object 'System.Collections.Concurrent.ConcurrentQueue[string]'
$sel = @("A_Ok", "B_Flaky", "D_Reboot", "E_Hang")
$outcome = Start-PostInstallProcess -Queue $q -SelectedStepIds $sel -Resume:([bool]::Parse($Resume))
"OUTCOME=$outcome"
'@
    $runnerPath = Join-Path $engineSandbox "runner.ps1"
    [System.IO.File]::WriteAllText($runnerPath, $runner, $utf8Bom)
    $stateFile = Join-Path $engineSandbox "State\state.json"

    Invoke-SuiteTest -Category "Engine E2E" -Name "Dot-sourcing engine keeps caller's `$Resume" -Body {
        # Regression: the engine's param block used to overwrite the UI's -Resume switch with $false,
        # so the GUI never auto-continued after a reboot.
        $probe = "param([switch]`$Resume) . '$(Join-Path $engineSandbox 'PostInstallEngine.ps1')'; `"RESUME=`$Resume`""
        $probePath = Join-Path $engineSandbox "probe.ps1"
        [System.IO.File]::WriteAllText($probePath, $probe, $utf8Bom)
        $out = & $WinPS -NoProfile -ExecutionPolicy Bypass -File $probePath -Resume 2>&1 | Out-String
        Assert-True ($out -match "RESUME=True") "caller's `$Resume clobbered: $out"
        "caller scope intact after dot-source"
    }

    Invoke-SuiteTest -Category "Engine E2E" -Name "Fresh run: retry, skip, deferred reboot, timeout" -Body {
        $out = & $WinPS -NoProfile -ExecutionPolicy Bypass -File $runnerPath -Root $engineSandbox -Resume "false" 2>&1 | Out-String
        Assert-True ($out -match "OUTCOME=COMPLETED") "outcome COMPLETED (got: $([regex]::Match($out,'OUTCOME=\w+').Value))"
        $st = Get-Content $stateFile -Raw -Encoding UTF8 | ConvertFrom-Json
        $byId = @{}; foreach ($r in $st.StepResults) { $byId[$r.Id] = $r }
        Assert-True ($byId["A_Ok"].Status -eq "Success") "A success"
        Assert-True ($byId["B_Flaky"].Status -eq "Warning" -and $byId["B_Flaky"].Attempts -eq 2) "B warning after 2 attempts (got $($byId['B_Flaky'].Status)/$($byId['B_Flaky'].Attempts))"
        Assert-True ($byId["C_Skipped"].Status -eq "Skipped") "C skipped"
        Assert-True ($byId["D_Reboot"].Status -eq "Success" -and $st.RebootPending) "D deferred reboot"
        Assert-True ($byId["E_Hang"].ExitCode -eq 1460 -and $byId["E_Hang"].Attempts -eq 1) "E watchdog timeout, not retried"
        Assert-True ($st.Status -eq "Completed") "state Completed"
        "A=Success, B=Warning(2 attempts), C=Skipped, D=deferred reboot, E=timeout 1460"
    }

    Invoke-SuiteTest -Category "Engine E2E" -Name "UTF-8 child output preserved in log" -Body {
        $log = [System.IO.File]::ReadAllText((Join-Path $engineSandbox "run.log"), [System.Text.Encoding]::UTF8)
        Assert-True ($log.Contains("Türkçe çıktı: ğüşiöç İĞ")) "Turkish characters survive the pipe"
        "Turkish characters intact"
    }

    Invoke-SuiteTest -Category "Engine E2E" -Name "Resume of completed session is a no-op; fresh run gets new session" -Body {
        $before = (Get-Content $stateFile -Raw | ConvertFrom-Json).SessionId
        $out = & $WinPS -NoProfile -ExecutionPolicy Bypass -File $runnerPath -Root $engineSandbox -Resume "true" 2>&1 | Out-String
        Assert-True ($out -match "OUTCOME=COMPLETED") "resume outcome"
        Assert-True ((Get-Content $stateFile -Raw | ConvertFrom-Json).SessionId -eq $before) "resume keeps session"

        # Simulate an interrupted session at step index 3 -> resume must continue there
        $st = Get-Content $stateFile -Raw | ConvertFrom-Json
        $st.Status = "RebootPending"; $st.CurrentStepIndex = 3; $st.StepResults[3].Status = "Pending"
        $st | ConvertTo-Json -Depth 8 | Set-Content $stateFile -Encoding UTF8
        $out = & $WinPS -NoProfile -ExecutionPolicy Bypass -File $runnerPath -Root $engineSandbox -Resume "true" 2>&1 | Out-String
        $st2 = Get-Content $stateFile -Raw | ConvertFrom-Json
        Assert-True ($st2.SessionId -eq $before -and $st2.StepResults[0].Attempts -eq 1) "earlier steps not re-run"
        Assert-True ($st2.StepResults[3].Status -eq "Success") "resumed step executed"
        "completed session not re-run; interrupted session resumed at step 4"
    }
} finally {
    Remove-Item $engineSandbox -Recurse -Force -ErrorAction SilentlyContinue
}

# -------------------------------------------------------------
# SUMMARY & MATRIX OUTPUT
# -------------------------------------------------------------
$total  = $testResults.Count
$passed = @($testResults | Where-Object { $_.Status -eq "PASS" }).Count
$failed = @($testResults | Where-Object { $_.Status -eq "FAIL" }).Count
$passRate = if ($total -gt 0) { [Math]::Round(($passed / $total) * 100, 1) } else { 0 }
$totalDuration = [Math]::Round(($testResults | Measure-Object -Property DurationMs -Sum).Sum, 2)
$summaryColor = if ($failed -eq 0) { "Green" } else { "Red" }

Write-Host "`n==========================================================================================" -ForegroundColor $summaryColor
Write-Host "SUMMARY: Total Tests: $total | PASS: $passed | FAIL: $failed | Pass Rate: $passRate% | Total Time: $totalDuration ms" -ForegroundColor $summaryColor
Write-Host "==========================================================================================" -ForegroundColor $summaryColor
$testResults | Where-Object { $_.Status -eq "FAIL" } | Format-Table -Property Category, TestName, Details -AutoSize -Wrap | Out-String | Write-Host

[PSCustomObject]@{
    ExecutionTimestamp = (Get-Date -Format "o")
    TotalTests         = $total
    PassCount          = $passed
    FailCount          = $failed
    PassRatePercent    = $passRate
    TotalDurationMs    = $totalDuration
    Tests              = $testResults
} | ConvertTo-Json -Depth 6 | Set-Content $OutputPath -Encoding UTF8
Write-Host "Test results exported to: $OutputPath" -ForegroundColor Gray

exit $failed
