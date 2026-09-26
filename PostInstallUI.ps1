#Requires -Version 5.1
<#
.SYNOPSIS
    Computer Maintenance Pro - Enterprise GUI Suite v4.0.0
.DESCRIPTION
    Comprehensive Hardware Monitoring, Preventive System Maintenance,
    Hardware-Aware Multi-GPU Companion Management, and 13-Stage Deployment Wizard.
.NOTES
    Author : Antigravity Systems Team
    Version: 4.0.0
#>
[CmdletBinding()]
param(
    [switch]$Resume,
    [switch]$Auto
)

Set-StrictMode -Off
$ErrorActionPreference = "Stop"

#region --- Assembly Loading ---
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()
[System.Windows.Forms.Application]::SetCompatibleTextRenderingDefault($false)
#endregion

#region --- Startup Trace ---
# Each launch records its startup milestones, so a UI that never shows its window can be diagnosed
$Script:UiTraceFile = Join-Path $env:ProgramData "ComputerMaintenancePro\Logs\UI_Startup.log"
function Write-UiTrace {
    param([string]$Step)
    try {
        $dir = Split-Path -Parent $Script:UiTraceFile
        if (-not (Test-Path $dir)) { New-Item -Path $dir -ItemType Directory -Force | Out-Null }
        $line = "[{0}] [PID {1}] {2}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss.fff"), $PID, $Step
        [System.IO.File]::AppendAllText($Script:UiTraceFile, "$line`r`n", (New-Object System.Text.UTF8Encoding($false)))
    } catch {}
}
Write-UiTrace "Baslatiliyor (Resume=$Resume, Auto=$Auto, Elevated=$(([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)))"
#endregion

#region --- Single Instance Guard ---
# RunOnce resume + a manual start (or a double click) must never drive the engine twice.
# The owner writes its PID next to the logs so a second launch can focus it - or, if that copy
# is stuck without a window, offer to end it instead of just refusing to start.
if (-not ("CmpNative.Window" -as [type])) {
    Add-Type -Namespace CmpNative -Name Window -MemberDefinition @"
[System.Runtime.InteropServices.DllImport("user32.dll")] public static extern bool SetForegroundWindow(System.IntPtr hWnd);
[System.Runtime.InteropServices.DllImport("user32.dll")] public static extern bool ShowWindow(System.IntPtr hWnd, int nCmdShow);
"@
}
$Script:InstancePidFile = Join-Path $env:ProgramData "ComputerMaintenancePro\State\UI.pid"
$Script:InstanceMutexCreated = $false
$Script:InstanceMutex = New-Object System.Threading.Mutex($false, "Global\ComputerMaintenancePro_UI")

function Enter-InstanceMutex {
    param([int]$TimeoutMs = 0)
    try { return $Script:InstanceMutex.WaitOne($TimeoutMs) }
    catch [System.Threading.AbandonedMutexException] { return $true }   # previous owner died: now ours
}

if (-not (Enter-InstanceMutex)) {
    # Candidates: the PID recorded by the owner, plus any other UI host found by command line
    # (older builds wrote no PID file; command lines of elevated processes are only visible when elevated)
    $others = @()
    try {
        $otherPid = [int](Get-Content -LiteralPath $Script:InstancePidFile -ErrorAction Stop | Select-Object -First 1)
        $others += Get-Process -Id $otherPid -ErrorAction Stop
    } catch {}
    Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue |
        Where-Object { $_.ProcessId -ne $PID -and $_.CommandLine -match 'PostInstallUI\.ps1' } |
        ForEach-Object { $others += Get-Process -Id $_.ProcessId -ErrorAction SilentlyContinue }
    $others = @($others | Where-Object { $_ } | Sort-Object Id -Unique)

    $withWindow = $others | Where-Object { $_.MainWindowHandle -ne [IntPtr]::Zero } | Select-Object -First 1
    if ($withWindow) {
        # Normal case: bring the running window to the front and quit quietly
        [void][CmpNative.Window]::ShowWindow($withWindow.MainWindowHandle, 9)   # SW_RESTORE
        [void][CmpNative.Window]::SetForegroundWindow($withWindow.MainWindowHandle)
        Write-UiTrace "Zaten acik (PID $($withWindow.Id)); mevcut pencere one getirildi."
        exit 0
    }

    $who = if ($others.Count -gt 0) { ($others | ForEach-Object { "PID $($_.Id) ($($_.StartTime.ToString('HH:mm:ss')))" }) -join ", " } else { "PID görünmüyor" }
    if ($others.Count -eq 0) {
        [System.Windows.Forms.MessageBox]::Show("Computer Maintenance Pro'nun arka planda takılı bir kopyası var, ancak bu yetkiyle görülemiyor.`r`n`r`nUygulamayı PostInstall.exe ile (yönetici olarak) açın ya da Görev Yöneticisi > Ayrıntılar'dan penceresi olmayan 'powershell.exe' süreçlerini sonlandırın.", "Takılı Kopya", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Warning) | Out-Null
        Write-UiTrace "Kilit baskasinda, aday surec gorunmuyor; cikiliyor."
        exit 0
    }
    $answer = [System.Windows.Forms.MessageBox]::Show(
        "Computer Maintenance Pro'nun penceresi olmayan, yanıt vermeyen kopyası/kopyaları arka planda çalışıyor:`r`n$who`r`n`r`nBunlar sonlandırılıp uygulama açılsın mı?",
        "Takılı Kopya Bulundu", [System.Windows.Forms.MessageBoxButtons]::YesNo, [System.Windows.Forms.MessageBoxIcon]::Warning)
    if ($answer -ne [System.Windows.Forms.DialogResult]::Yes) {
        Write-UiTrace "Takili kopya ($who) icin sonlandirma reddedildi; cikiliyor."
        exit 0
    }
    $failed = @()
    foreach ($o in $others) {
        try { Stop-Process -Id $o.Id -Force -ErrorAction Stop } catch { $failed += $o.Id }
    }
    Write-UiTrace "Takili kopyalar sonlandirildi: $who (basarisiz: $($failed -join ','))"
    if (-not (Enter-InstanceMutex -TimeoutMs 5000)) {
        $hint = if ($failed.Count -gt 0) { "Sonlandırılamayan PID: $($failed -join ', '). Uygulamayı yönetici olarak (PostInstall.exe) açmayı deneyin." } else { "Lütfen tekrar deneyin." }
        [System.Windows.Forms.MessageBox]::Show("Önceki kopya kapatılamadı. $hint", "Hata", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Error) | Out-Null
        Write-UiTrace "Kilit 5 sn icinde serbest kalmadi; cikiliyor."
        exit 1
    }
}
$Script:InstanceMutexCreated = $true
try {
    $pidDir = Split-Path -Parent $Script:InstancePidFile
    if (-not (Test-Path $pidDir)) { New-Item -Path $pidDir -ItemType Directory -Force | Out-Null }
    Set-Content -LiteralPath $Script:InstancePidFile -Value $PID -Encoding ASCII
} catch {}
Write-UiTrace "Tek ornek kilidi alindi."
#endregion

#region --- Bootstrap Engine & Tools ---
$Script:UIRoot = if ($PSScriptRoot -and (Test-Path $PSScriptRoot)) {
    $PSScriptRoot
} elseif ($MyInvocation.MyCommand.Path) {
    Split-Path -Parent $MyInvocation.MyCommand.Path
} else {
    "C:\PostInstall"
}

$Script:EnginePath      = Join-Path $Script:UIRoot "PostInstallEngine.ps1"
$Script:DetectorPath    = Join-Path $Script:UIRoot "Tools\SilentDetector.ps1"
$Script:SpecsPath       = Join-Path $Script:UIRoot "Tools\SystemSpecsCollector.ps1"
$Script:SnapshotPath    = Join-Path $Script:UIRoot "Tools\SnapshotEngine.ps1"
$Script:DriverEnginePath = Join-Path $Script:UIRoot "Tools\DriverEngine.ps1"
$Script:PackageEnginePath = Join-Path $Script:UIRoot "Tools\PackageEngine.ps1"
$Script:MaintEnginePath = Join-Path $Script:UIRoot "Tools\MaintenanceEngine.ps1"
$Script:HwMonEnginePath = Join-Path $Script:UIRoot "Tools\HardwareMonitorEngine.ps1"
$Script:GpuDbPath       = Join-Path $Script:UIRoot "gpu_compatibility.json"

if (-not (Test-Path $Script:EnginePath)) {
    [System.Windows.Forms.MessageBox]::Show("PostInstallEngine.ps1 bulunamadi: $Script:EnginePath", "Hata", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Error)
    exit 1
}

. $Script:EnginePath
if (Test-Path $Script:DetectorPath)     { . $Script:DetectorPath }
if (Test-Path $Script:SpecsPath)        { . $Script:SpecsPath }
if (Test-Path $Script:SnapshotPath)     { . $Script:SnapshotPath }
if (Test-Path $Script:DriverEnginePath) { . $Script:DriverEnginePath }
if (Test-Path $Script:PackageEnginePath){ . $Script:PackageEnginePath }
if (Test-Path $Script:MaintEnginePath)  { . $Script:MaintEnginePath }
if (Test-Path $Script:HwMonEnginePath)  { . $Script:HwMonEnginePath }

# Load GPU Database
$Script:GpuDb = $null
if (Test-Path $Script:GpuDbPath) {
    try {
        $Script:GpuDb = Get-Content -LiteralPath $Script:GpuDbPath -Raw -Encoding UTF8 | ConvertFrom-Json
    } catch {
        [System.Diagnostics.Trace]::WriteLine("GPU DB load warning: $($_.Exception.Message)")
    }
}
#endregion

Write-UiTrace "Motor ve araclar yuklendi."

#region --- Theme (Enterprise Dark) ---
$Theme = @{
    BgMain      = [System.Drawing.Color]::FromArgb(13, 17, 23)
    BgCard      = [System.Drawing.Color]::FromArgb(22, 27, 34)
    BgHeader    = [System.Drawing.Color]::FromArgb(33, 38, 45)
    BgConsole   = [System.Drawing.Color]::FromArgb(9, 11, 16)
    BgInput     = [System.Drawing.Color]::FromArgb(28, 33, 40)
    AccentBlue  = [System.Drawing.Color]::FromArgb(31, 111, 235)
    AccentCyan  = [System.Drawing.Color]::FromArgb(56, 189, 248)
    AccentGreen = [System.Drawing.Color]::FromArgb(35, 134, 54)
    AccentAmber = [System.Drawing.Color]::FromArgb(210, 153, 34)
    AccentRed   = [System.Drawing.Color]::FromArgb(218, 54, 51)
    AccentPurple= [System.Drawing.Color]::FromArgb(163, 113, 247)
    TextPrimary = [System.Drawing.Color]::FromArgb(230, 237, 243)
    TextMuted   = [System.Drawing.Color]::FromArgb(139, 148, 158)
    Border      = [System.Drawing.Color]::FromArgb(48, 54, 61)
    
    FontTitle   = (New-Object System.Drawing.Font("Segoe UI Semibold", 12, [System.Drawing.FontStyle]::Bold))
    FontTab     = (New-Object System.Drawing.Font("Segoe UI Semibold", 9.5, [System.Drawing.FontStyle]::Bold))
    FontHeader  = (New-Object System.Drawing.Font("Segoe UI Semibold", 10.5))
    FontSub     = (New-Object System.Drawing.Font("Segoe UI", 8.5))
    FontCardHdr = (New-Object System.Drawing.Font("Segoe UI Semibold", 9.5, [System.Drawing.FontStyle]::Bold))
    FontCardTxt = (New-Object System.Drawing.Font("Segoe UI", 8.5))
    FontMono    = (New-Object System.Drawing.Font("Consolas", 8.5))
    FontButton  = (New-Object System.Drawing.Font("Segoe UI Semibold", 9))
    FontBadge   = (New-Object System.Drawing.Font("Segoe UI", 8, [System.Drawing.FontStyle]::Bold))
    FontGaugeVal= (New-Object System.Drawing.Font("Segoe UI Semibold", 16, [System.Drawing.FontStyle]::Bold))
}
#endregion

#region --- Queues & Shared State ---
$Script:MsgQueue      = New-Object 'System.Collections.Concurrent.ConcurrentQueue[string]'
$Script:StatusQueue   = New-Object 'System.Collections.Concurrent.ConcurrentQueue[object]'
$Script:MaintMsgQueue = New-Object 'System.Collections.Concurrent.ConcurrentQueue[string]'
$Script:GpuMsgQueue   = New-Object 'System.Collections.Concurrent.ConcurrentQueue[string]'
$Script:GpuDoneMarker = "@@GPU_JOB_DONE@@"
$Script:IsRunning     = $false
$Script:CurrentWizardPage = 1
$Script:ActiveTab     = "Monitoring"

$Script:TelemetryJob        = $null
$Script:LastTelemetryUpdate = [DateTime]::MinValue
$Script:TelemetryQueue      = New-Object 'System.Collections.Concurrent.ConcurrentQueue[object]'
$Script:TelemetryControl    = [hashtable]::Synchronized(@{ Stop = $false; Active = $true; RefreshNow = $false; IntervalMs = 2000 })
$Script:BackgroundJobs      = New-Object System.Collections.Generic.List[object]
$Script:OfflineListLoaded   = $false

function Start-ScriptBlockAsync {
    <#
    .NOTES
        The script block is re-created from its text inside the new runspace, so it never keeps
        the UI runspace's session-state affinity. Pass everything it needs via -ArgumentList.
        -Track registers the job for automatic EndInvoke/Dispose by the UI timer (fire-and-forget jobs).
    #>
    param(
        [Parameter(Mandatory=$true)][scriptblock]$ScriptBlock,
        [object[]]$ArgumentList = @(),
        [switch]$Track
    )
    $rs = [runspacefactory]::CreateRunspace()
    $rs.ApartmentState = [System.Threading.ApartmentState]::STA
    $rs.ThreadOptions  = [System.Management.Automation.Runspaces.PSThreadOptions]::ReuseThread
    $rs.Open()
    $ps = [powershell]::Create()
    $ps.Runspace = $rs
    [void]$ps.AddScript($ScriptBlock.ToString())
    foreach ($arg in $ArgumentList) {
        [void]$ps.AddArgument($arg)
    }
    $async = $ps.BeginInvoke()
    $job = [PSCustomObject]@{
        Runspace    = $rs
        PowerShell  = $ps
        AsyncResult = $async
    }
    if ($Track) { $Script:BackgroundJobs.Add($job) }
    return $job
}

function Clear-CompletedBackgroundJobs {
    for ($i = $Script:BackgroundJobs.Count - 1; $i -ge 0; $i--) {
        $job = $Script:BackgroundJobs[$i]
        if ($job.AsyncResult.IsCompleted) {
            try { [void]$job.PowerShell.EndInvoke($job.AsyncResult) } catch {}
            Stop-ScriptBlockAsync $job
            $Script:BackgroundJobs.RemoveAt($i)
        }
    }
}

function Stop-ScriptBlockAsync {
    param($Job)
    if ($Job) {
        try {
            if ($Job.PowerShell) {
                $Job.PowerShell.Stop()
                $Job.PowerShell.Dispose()
            }
        } catch {}
        try {
            if ($Job.Runspace) {
                $Job.Runspace.Close()
                $Job.Runspace.Dispose()
            }
        } catch {}
    }
}
#endregion

#region --- Main Window Form ---
$form = New-Object System.Windows.Forms.Form
$form.Text            = "Computer Maintenance Pro - Enterprise System Care & Staging Suite v$($Script:Config.Version)"
$form.Size            = New-Object System.Drawing.Size(1160, 760)
$form.MinimumSize     = New-Object System.Drawing.Size(1024, 680)
$form.StartPosition   = [System.Windows.Forms.FormStartPosition]::CenterScreen
$form.BackColor       = $Theme.BgMain
$form.ForeColor       = $Theme.TextPrimary
$form.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::Sizable
$form.Icon            = [System.Drawing.SystemIcons]::Application
$form.GetType().GetProperty("DoubleBuffered", [System.Reflection.BindingFlags]"NonPublic,Instance").SetValue($form, $true, $null)
#endregion

#region --- Top Header & Main Navigation Bar ---
$pnlHeader = New-Object System.Windows.Forms.Panel
$pnlHeader.Dock      = [System.Windows.Forms.DockStyle]::Top
$pnlHeader.Height    = 88
$pnlHeader.BackColor = $Theme.BgHeader
$form.Controls.Add($pnlHeader)

# App Title Row
$pnlTitleRow = New-Object System.Windows.Forms.Panel
$pnlTitleRow.Dock      = [System.Windows.Forms.DockStyle]::Top
$pnlTitleRow.Height    = 42
$pnlTitleRow.BackColor = $Theme.BgHeader
$pnlHeader.Controls.Add($pnlTitleRow)

$lblTitle = New-Object System.Windows.Forms.Label
$lblTitle.Text        = "  COMPUTER MAINTENANCE PRO v$($Script:Config.Version)"
$lblTitle.Font        = $Theme.FontTitle
$lblTitle.ForeColor   = $Theme.AccentCyan
$lblTitle.Dock        = [System.Windows.Forms.DockStyle]::Left
$lblTitle.Width       = 380
$lblTitle.TextAlign   = [System.Drawing.ContentAlignment]::MiddleLeft
$lblTitle.UseMnemonic = $false
$pnlTitleRow.Controls.Add($lblTitle)

$lblSubTitle = New-Object System.Windows.Forms.Label
$lblSubTitle.Text        = "Evrensel Sistem Bakımı • Donanım İzleme • Akıllı GPU Yönetimi • Kurulum Süiti"
$lblSubTitle.Font        = $Theme.FontSub
$lblSubTitle.ForeColor   = $Theme.TextMuted
$lblSubTitle.Dock        = [System.Windows.Forms.DockStyle]::Fill
$lblSubTitle.TextAlign   = [System.Drawing.ContentAlignment]::MiddleRight
$lblSubTitle.Padding     = New-Object System.Windows.Forms.Padding(0, 0, 16, 0)
$lblSubTitle.UseMnemonic = $false
$pnlTitleRow.Controls.Add($lblSubTitle)

# Navigation Tabs Bar
$pnlNavTabs = New-Object System.Windows.Forms.Panel
$pnlNavTabs.Dock      = [System.Windows.Forms.DockStyle]::Bottom
$pnlNavTabs.Height    = 44
$pnlNavTabs.BackColor = $Theme.BgCard
$pnlHeader.Controls.Add($pnlNavTabs)

function New-TabNavBtn {
    param([string]$Text, [string]$TabKey, [int]$X, [int]$W)
    $btn = New-Object System.Windows.Forms.Button
    $btn.Text      = $Text
    $btn.Tag       = $TabKey
    $btn.Font      = $Theme.FontTab
    $btn.Location  = New-Object System.Drawing.Point($X, 4)
    $btn.Size      = New-Object System.Drawing.Size($W, 36)
    $btn.BackColor = $Theme.BgCard
    $btn.ForeColor = $Theme.TextMuted
    $btn.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
    $btn.FlatAppearance.BorderSize = 0
    $btn.Cursor    = [System.Windows.Forms.Cursors]::Hand

    $btn.Add_MouseEnter({
        if ($Script:ActiveTab -ne $this.Tag) {
            $this.ForeColor = $Theme.TextPrimary
            $this.BackColor = [System.Drawing.Color]::FromArgb(38, 44, 54)
        }
    })
    $btn.Add_MouseLeave({
        if ($Script:ActiveTab -ne $this.Tag) {
            $this.ForeColor = $Theme.TextMuted
            $this.BackColor = $Theme.BgCard
        }
    })
    return $btn
}

$btnTabMon     = New-TabNavBtn "📊 Canlı İzleme"       "Monitoring"   16  150
$btnTabMaint   = New-TabNavBtn "🛠️ Sistem Bakımı"      "Maintenance"  172 160
$btnTabWizard  = New-TabNavBtn "🚀 Kurulum Sihirbazı"  "Wizard"       338 170
$btnTabGpu     = New-TabNavBtn "🎮 GPU & Sürücüler"    "GpuCenter"    514 170
$btnTabConsole = New-TabNavBtn "📜 Konsol & Loglar"    "Console"      690 160

$Script:NavTabButtons = @($btnTabMon, $btnTabMaint, $btnTabWizard, $btnTabGpu, $btnTabConsole)
foreach ($btn in $Script:NavTabButtons) { $pnlNavTabs.Controls.Add($btn) }
#endregion

#region --- Main Content Container ---
$pnlContent = New-Object System.Windows.Forms.Panel
$pnlContent.Dock      = [System.Windows.Forms.DockStyle]::Fill
$pnlContent.BackColor = $Theme.BgMain
$form.Controls.Add($pnlContent)
$pnlContent.BringToFront()
#endregion

# -------------------------------------------------------------------------------------------------
# TAB 1: HARDWARE MONITORING PANEL
# -------------------------------------------------------------------------------------------------
#region --- Tab 1: Hardware Monitoring ---
$pnlTabMon = New-Object System.Windows.Forms.Panel
$pnlTabMon.Dock      = [System.Windows.Forms.DockStyle]::Fill
$pnlTabMon.BackColor = $Theme.BgMain
$pnlTabMon.Padding   = New-Object System.Windows.Forms.Padding(16, 12, 16, 12)
$pnlContent.Controls.Add($pnlTabMon)

# Monitoring Header Control Bar
$pnlMonCtrlBar = New-Object System.Windows.Forms.Panel
$pnlMonCtrlBar.Dock      = [System.Windows.Forms.DockStyle]::Top
$pnlMonCtrlBar.Height    = 40
$pnlMonCtrlBar.BackColor = $Theme.BgMain
$pnlTabMon.Controls.Add($pnlMonCtrlBar)

$lblMonStatus = New-Object System.Windows.Forms.Label
$lblMonStatus.Text        = "Canlı Donanım & Performans Telemetrisi (Yenilenme: 2 sn)"
$lblMonStatus.Font        = $Theme.FontHeader
$lblMonStatus.ForeColor   = $Theme.AccentCyan
$lblMonStatus.Dock        = [System.Windows.Forms.DockStyle]::Left
$lblMonStatus.Width       = 460
$lblMonStatus.TextAlign   = [System.Drawing.ContentAlignment]::MiddleLeft
$lblMonStatus.UseMnemonic = $false
$pnlMonCtrlBar.Controls.Add($lblMonStatus)

$btnRefreshMon = New-Object System.Windows.Forms.Button
$btnRefreshMon.Text      = "⚡ Şimdi Yenile"
$btnRefreshMon.Font      = $Theme.FontButton
$btnRefreshMon.Dock      = [System.Windows.Forms.DockStyle]::Right
$btnRefreshMon.Width     = 130
$btnRefreshMon.BackColor = $Theme.AccentBlue
$btnRefreshMon.ForeColor = [System.Drawing.Color]::White
$btnRefreshMon.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
$btnRefreshMon.FlatAppearance.BorderSize = 0
$btnRefreshMon.Cursor    = [System.Windows.Forms.Cursors]::Hand
$pnlMonCtrlBar.Controls.Add($btnRefreshMon)

# Telemetry Dashboard Grid (2 Rows x 3 Columns)
$tlpGauges = New-Object System.Windows.Forms.TableLayoutPanel
$tlpGauges.Dock        = [System.Windows.Forms.DockStyle]::Fill
$tlpGauges.BackColor   = $Theme.BgMain
$tlpGauges.ColumnCount = 3
$tlpGauges.RowCount    = 2
$tlpGauges.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 33.3))) | Out-Null
$tlpGauges.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 33.3))) | Out-Null
$tlpGauges.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 33.4))) | Out-Null
$tlpGauges.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Percent, 50))) | Out-Null
$tlpGauges.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Percent, 50))) | Out-Null
$pnlTabMon.Controls.Add($tlpGauges)
# Fill must be front-most in z-order, otherwise the Top bar is laid over the first card row
$tlpGauges.BringToFront()

function New-MetricCard {
    param([string]$Title, [string]$BadgeText, [System.Drawing.Color]$BadgeColor)
    $card = New-Object System.Windows.Forms.Panel
    $card.Dock      = [System.Windows.Forms.DockStyle]::Fill
    $card.BackColor = $Theme.BgCard
    $card.Margin    = New-Object System.Windows.Forms.Padding(6)
    $card.Padding   = New-Object System.Windows.Forms.Padding(12)

    $lblHdr = New-Object System.Windows.Forms.Label
    $lblHdr.Text        = if ($BadgeText) { "$Title  [$BadgeText]" } else { $Title }
    $lblHdr.Font        = $Theme.FontCardHdr
    $lblHdr.ForeColor   = if ($BadgeColor -and ($BadgeColor -ne [System.Drawing.Color]::Empty)) { $BadgeColor } else { $Theme.TextPrimary }
    $lblHdr.Dock        = [System.Windows.Forms.DockStyle]::Top
    $lblHdr.Height      = 26
    $lblHdr.UseMnemonic = $false

    $lblVal = New-Object System.Windows.Forms.Label
    $lblVal.Text        = "--"
    $lblVal.Font        = $Theme.FontGaugeVal
    $lblVal.ForeColor   = $Theme.AccentCyan
    $lblVal.Dock        = [System.Windows.Forms.DockStyle]::Top
    $lblVal.Height      = 38
    $lblVal.TextAlign   = [System.Drawing.ContentAlignment]::MiddleLeft
    $lblVal.UseMnemonic = $false

    $pb = New-Object System.Windows.Forms.ProgressBar
    $pb.Dock      = [System.Windows.Forms.DockStyle]::Top
    $pb.Height    = 10
    $pb.Maximum   = 100
    $pb.Value     = 0
    $pb.Style     = [System.Windows.Forms.ProgressBarStyle]::Continuous

    $lblSub = New-Object System.Windows.Forms.Label
    $lblSub.Text        = "Yükleniyor..."
    $lblSub.Font        = $Theme.FontCardTxt
    $lblSub.ForeColor   = $Theme.TextMuted
    $lblSub.Dock        = [System.Windows.Forms.DockStyle]::Fill
    $lblSub.TextAlign   = [System.Drawing.ContentAlignment]::MiddleLeft
    $lblSub.UseMnemonic = $false

    # Dock addition order: Fill first, then middle Top controls, then top-most Header last
    $card.Controls.Add($lblSub)
    $card.Controls.Add($pb)
    $card.Controls.Add($lblVal)
    $card.Controls.Add($lblHdr)

    return @{
        Panel       = $card
        ValueLabel  = $lblVal
        ProgressBar = $pb
        SubLabel    = $lblSub
    }
}

# 6 Metric Cards
$cardCpu  = New-MetricCard "💻 İŞLEMCİ (CPU)"          "CPU"  $Theme.AccentBlue
$cardGpuD = New-MetricCard "🎮 HARİCİ GPU (NVIDIA)"    "dGPU" $Theme.AccentGreen
$cardGpuI = New-MetricCard "🖥️ DAHİLİ GRAFİK (AMD/Intel)" "iGPU" $Theme.AccentPurple
$cardRam  = New-MetricCard "🧠 BELLEK (RAM)"          "RAM"  $Theme.AccentAmber
$cardDisk = New-MetricCard "💾 DEPOLAMA & DİSKLER"    "NVMe" $Theme.AccentCyan
$cardBat  = New-MetricCard "🔋 GÜÇ & PİL SAĞLIĞI"     "BAT"  $Theme.AccentGreen

$tlpGauges.Controls.Add($cardCpu.Panel,  0, 0)
$tlpGauges.Controls.Add($cardGpuD.Panel, 1, 0)
$tlpGauges.Controls.Add($cardGpuI.Panel, 2, 0)
$tlpGauges.Controls.Add($cardRam.Panel,  0, 1)
$tlpGauges.Controls.Add($cardDisk.Panel, 1, 1)
$tlpGauges.Controls.Add($cardBat.Panel,  2, 1)
#endregion

# -------------------------------------------------------------------------------------------------
# TAB 2: SYSTEM MAINTENANCE PANEL
# -------------------------------------------------------------------------------------------------
#region --- Tab 2: System Maintenance ---
$pnlTabMaint = New-Object System.Windows.Forms.Panel
$pnlTabMaint.Dock      = [System.Windows.Forms.DockStyle]::Fill
$pnlTabMaint.BackColor = $Theme.BgMain
$pnlTabMaint.Padding   = New-Object System.Windows.Forms.Padding(16, 12, 16, 12)
$pnlContent.Controls.Add($pnlTabMaint)

# Split Container: Top Action Buttons Grid, Bottom Live Maintenance Log
$splMaint = New-Object System.Windows.Forms.SplitContainer
$splMaint.Dock         = [System.Windows.Forms.DockStyle]::Fill
$splMaint.Orientation  = [System.Windows.Forms.Orientation]::Horizontal
$splMaint.SplitterDistance = 290
$splMaint.BackColor    = $Theme.Border
$pnlTabMaint.Controls.Add($splMaint)

# Action Buttons Table Layout
$tlpMaintActions = New-Object System.Windows.Forms.TableLayoutPanel
$tlpMaintActions.Dock        = [System.Windows.Forms.DockStyle]::Fill
$tlpMaintActions.BackColor   = $Theme.BgMain
$tlpMaintActions.ColumnCount = 4
$tlpMaintActions.RowCount    = 2
for ($c = 0; $c -lt 4; $c++) {
    $tlpMaintActions.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 25))) | Out-Null
}
$tlpMaintActions.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Percent, 50))) | Out-Null
$tlpMaintActions.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Percent, 50))) | Out-Null
$splMaint.Panel1.Controls.Add($tlpMaintActions)

function New-MaintActionButton {
    param([string]$Title, [string]$Desc, [System.Drawing.Color]$Accent)
    $card = New-Object System.Windows.Forms.Panel
    $card.Dock      = [System.Windows.Forms.DockStyle]::Fill
    $card.BackColor = $Theme.BgCard
    $card.Margin    = New-Object System.Windows.Forms.Padding(6)
    $card.Padding   = New-Object System.Windows.Forms.Padding(10)

    $lbl = New-Object System.Windows.Forms.Label
    $lbl.Text        = $Title
    $lbl.Font        = $Theme.FontCardHdr
    $lbl.ForeColor   = $Accent
    $lbl.Dock        = [System.Windows.Forms.DockStyle]::Top
    $lbl.Height      = 24
    $lbl.UseMnemonic = $false
    $lblD = New-Object System.Windows.Forms.Label
    $lblD.Text        = $Desc
    $lblD.Font        = $Theme.FontSub
    $lblD.ForeColor   = $Theme.TextMuted
    $lblD.Dock        = [System.Windows.Forms.DockStyle]::Fill
    $lblD.UseMnemonic = $false

    $btn = New-Object System.Windows.Forms.Button
    $btn.Text      = "Uygula"
    $btn.Font      = $Theme.FontButton
    $btn.Dock      = [System.Windows.Forms.DockStyle]::Bottom
    $btn.Height    = 30
    $btn.BackColor = $Theme.BgInput
    $btn.ForeColor = $Theme.TextPrimary
    $btn.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
    $btn.FlatAppearance.BorderColor = $Theme.Border
    $btn.Cursor    = [System.Windows.Forms.Cursors]::Hand

    # Proper WinForms dock stack order: Fill first, Bottom next, Top last
    $card.Controls.Add($lblD)
    $card.Controls.Add($btn)
    $card.Controls.Add($lbl)

    return @{ Panel = $card; Button = $btn }
}

$mbtnTemp     = New-MaintActionButton "⚡ Hızlı Çöp & Temp Temizliği" "Geçici dosyalar, Prefetch ve Geri Dönüşüm Kutusu." $Theme.AccentCyan
$mbtnWinUp    = New-MaintActionButton "🧹 Windows Update Onarımı" "İndirme önbelleğini temizler, servisleri sıfırlar." $Theme.AccentBlue
$mbtnDism     = New-MaintActionButton "🔧 DISM WinSxS Tasfiyesi" "Eski Windows güncelleme paketlerini diskten siler." $Theme.AccentGreen
$mbtnHealth   = New-MaintActionButton "🛡️ Sistem Dosya Bütünlüğü" "DISM CheckHealth ile dosya bozulmalarını tarar." $Theme.AccentAmber
$mbtnNet      = New-MaintActionButton "🌐 Ağ & DNS Sıfırlama" "DNS önbelleği, Winsock ve ARP soketlerini yeniler." $Theme.AccentCyan
$mbtnTrim     = New-MaintActionButton "💾 SSD Sürücü ReTRIM" "Tüm SSD ve NVMe sürücülerine anında TRIM gönderir." $Theme.AccentPurple
$mbtnBat      = New-MaintActionButton "🔋 Pil Sağlık Raporu" "Aşınma düzeyi ve döngü sayısını HTML raporlar." $Theme.AccentGreen
$mbtnFull     = New-MaintActionButton "🚀 1-Tıkla Tam Bakım" "Tüm hijyen, disk ve ağ optimizasyonlarını çalıştırır." $Theme.AccentRed

$tlpMaintActions.Controls.Add($mbtnTemp.Panel,   0, 0)
$tlpMaintActions.Controls.Add($mbtnWinUp.Panel,  1, 0)
$tlpMaintActions.Controls.Add($mbtnDism.Panel,   2, 0)
$tlpMaintActions.Controls.Add($mbtnHealth.Panel, 3, 0)
$tlpMaintActions.Controls.Add($mbtnNet.Panel,    0, 1)
$tlpMaintActions.Controls.Add($mbtnTrim.Panel,   1, 1)
$tlpMaintActions.Controls.Add($mbtnBat.Panel,    2, 1)
$tlpMaintActions.Controls.Add($mbtnFull.Panel,   3, 1)

# Maintenance Live Log
$rtbMaintLog = New-Object System.Windows.Forms.RichTextBox
$rtbMaintLog.Dock        = [System.Windows.Forms.DockStyle]::Fill
$rtbMaintLog.BackColor   = $Theme.BgConsole
$rtbMaintLog.ForeColor   = $Theme.TextPrimary
$rtbMaintLog.Font        = $Theme.FontMono
$rtbMaintLog.BorderStyle = [System.Windows.Forms.BorderStyle]::None
$rtbMaintLog.ReadOnly    = $true
$splMaint.Panel2.Controls.Add($rtbMaintLog)
#endregion

# -------------------------------------------------------------------------------------------------
# TAB 3: POST-INSTALLATION & STAGING WIZARD
# -------------------------------------------------------------------------------------------------
#region --- Tab 3: Staging Wizard ---
$pnlTabWizard = New-Object System.Windows.Forms.Panel
$pnlTabWizard.Dock      = [System.Windows.Forms.DockStyle]::Fill
$pnlTabWizard.BackColor = $Theme.BgMain
$pnlContent.Controls.Add($pnlTabWizard)

# Breadcrumb Bar for Wizard
$pnlWizardBc = New-Object System.Windows.Forms.TableLayoutPanel
$pnlWizardBc.Dock        = [System.Windows.Forms.DockStyle]::Top
$pnlWizardBc.Height      = 32
$pnlWizardBc.BackColor   = $Theme.BgCard
$pnlWizardBc.ColumnCount = 5
$pnlWizardBc.RowCount    = 1
for ($col = 0; $col -lt 5; $col++) {
    $pnlWizardBc.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 20))) | Out-Null
}
$pnlTabWizard.Controls.Add($pnlWizardBc)

$bcSteps = @("1. Sistem Özeti", "2. Paket Seçimi", "3. Özel Yükleyiciler", "4. Kurulum Süreci", "5. Tamamlandı")
$Script:BreadcrumbLabels = @()
for ($i = 0; $i -lt $bcSteps.Count; $i++) {
    $lblBc = New-Object System.Windows.Forms.Label
    $lblBc.Text      = $bcSteps[$i]
    $lblBc.Font      = $Theme.FontSub
    $lblBc.ForeColor = if ($i -eq 0) { $Theme.AccentCyan } else { $Theme.TextMuted }
    $lblBc.TextAlign = [System.Drawing.ContentAlignment]::MiddleCenter
    $lblBc.Dock      = [System.Windows.Forms.DockStyle]::Fill
    $lblBc.UseMnemonic = $false
    $pnlWizardBc.Controls.Add($lblBc, $i, 0)
    $Script:BreadcrumbLabels += $lblBc
}

# Wizard Pages Container
$pnlWizardPages = New-Object System.Windows.Forms.Panel
$pnlWizardPages.Dock      = [System.Windows.Forms.DockStyle]::Fill
$pnlWizardPages.BackColor = $Theme.BgMain
$pnlWizardPages.Padding   = New-Object System.Windows.Forms.Padding(16, 8, 16, 8)
$pnlTabWizard.Controls.Add($pnlWizardPages)

# Wizard Bottom Bar
$pnlWizardBottom = New-Object System.Windows.Forms.Panel
$pnlWizardBottom.Dock      = [System.Windows.Forms.DockStyle]::Bottom
$pnlWizardBottom.Height    = 52
$pnlWizardBottom.BackColor = $Theme.BgHeader
$pnlTabWizard.Controls.Add($pnlWizardBottom)

$pnlWizardBtns = New-Object System.Windows.Forms.Panel
$pnlWizardBtns.Dock      = [System.Windows.Forms.DockStyle]::Right
$pnlWizardBtns.Width     = 660
$pnlWizardBtns.BackColor = [System.Drawing.Color]::Transparent
$pnlWizardBottom.Controls.Add($pnlWizardBtns)

function New-FixedBtn {
    param([string]$Text, [int]$X, [int]$W, [System.Drawing.Color]$Bg, [System.Drawing.Color]$Fg = ([System.Drawing.Color]::White))
    $btn = New-Object System.Windows.Forms.Button
    $btn.Text      = $Text
    $btn.Font      = $Theme.FontButton
    $btn.Location  = New-Object System.Drawing.Point($X, 8)
    $btn.Size      = New-Object System.Drawing.Size($W, 36)
    $btn.BackColor = $Bg
    $btn.ForeColor = $Fg
    $btn.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
    $btn.FlatAppearance.BorderColor = $Theme.Border
    $btn.FlatAppearance.BorderSize  = 1
    $btn.Cursor    = [System.Windows.Forms.Cursors]::Hand
    return $btn
}

$btnBack    = New-FixedBtn "Geri"                 10  90  $Theme.BgCard     $Theme.TextPrimary
$btnExpress = New-FixedBtn "Hızlı Otomatik Kur"   110 160 $Theme.AccentCyan  ([System.Drawing.Color]::Black)
$btnNext    = New-FixedBtn "İleri"                280 110 $Theme.AccentBlue  ([System.Drawing.Color]::White)
$btnStart   = New-FixedBtn "Kurulumu Başlat"     280 130 $Theme.AccentGreen ([System.Drawing.Color]::White)
$btnOpenLog = New-FixedBtn "Log Aç"               420 100 $Theme.BgCard     $Theme.TextPrimary
$btnClose   = New-FixedBtn "Kapat"                530 110 $Theme.BgCard     $Theme.TextPrimary

$btnBack.Enabled  = $false
$btnStart.Visible = $false

$pnlWizardBtns.Controls.Add($btnBack)
$pnlWizardBtns.Controls.Add($btnExpress)
$pnlWizardBtns.Controls.Add($btnNext)
$pnlWizardBtns.Controls.Add($btnStart)
$pnlWizardBtns.Controls.Add($btnOpenLog)
$pnlWizardBtns.Controls.Add($btnClose)

$lblNavStatus = New-Object System.Windows.Forms.Label
$lblNavStatus.Text        = "Hazır. Sistem donanım özetini inceleyip kuruluma ilerleyin."
$lblNavStatus.Font        = $Theme.FontSub
$lblNavStatus.ForeColor   = $Theme.TextMuted
$lblNavStatus.Dock        = [System.Windows.Forms.DockStyle]::Fill
$lblNavStatus.TextAlign   = [System.Drawing.ContentAlignment]::MiddleLeft
$lblNavStatus.Padding     = New-Object System.Windows.Forms.Padding(16, 0, 0, 0)
$lblNavStatus.UseMnemonic = $false
$pnlWizardBottom.Controls.Add($lblNavStatus)

# --- Wizard Page 1: Specs & Health ---
$pnlPage1 = New-Object System.Windows.Forms.Panel
$pnlPage1.Dock      = [System.Windows.Forms.DockStyle]::Fill
$pnlPage1.BackColor = $Theme.BgMain
$pnlWizardPages.Controls.Add($pnlPage1)

$tlpPage1 = New-Object System.Windows.Forms.TableLayoutPanel
$tlpPage1.Dock        = [System.Windows.Forms.DockStyle]::Fill
$tlpPage1.ColumnCount = 1
$tlpPage1.RowCount    = 3
$tlpPage1.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, 32))) | Out-Null
$tlpPage1.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, 270))) | Out-Null
$tlpPage1.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Percent, 100))) | Out-Null
$pnlPage1.Controls.Add($tlpPage1)

$lblP1Title = New-Object System.Windows.Forms.Label
$lblP1Title.Text        = "Bilgisayar Donanım Profili ve Sağlık Değerlendirmesi"
$lblP1Title.Font        = $Theme.FontHeader
$lblP1Title.ForeColor   = $Theme.AccentCyan
$lblP1Title.Dock        = [System.Windows.Forms.DockStyle]::Fill
$lblP1Title.TextAlign   = [System.Drawing.ContentAlignment]::MiddleLeft
$lblP1Title.UseMnemonic = $false
$tlpPage1.Controls.Add($lblP1Title, 0, 0)

$tlpSpecsGrid = New-Object System.Windows.Forms.TableLayoutPanel
$tlpSpecsGrid.Dock        = [System.Windows.Forms.DockStyle]::Fill
$tlpSpecsGrid.ColumnCount = 3
$tlpSpecsGrid.RowCount    = 2
for ($c = 0; $c -lt 3; $c++) { $tlpSpecsGrid.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 33.3))) | Out-Null }
$tlpSpecsGrid.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Percent, 50))) | Out-Null
$tlpSpecsGrid.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Percent, 50))) | Out-Null
$tlpPage1.Controls.Add($tlpSpecsGrid, 0, 1)

function New-SpecBox {
    param([string]$Hdr)
    $box = New-Object System.Windows.Forms.GroupBox
    $box.Text      = $Hdr
    $box.Font      = $Theme.FontCardHdr
    $box.ForeColor = $Theme.AccentCyan
    $box.BackColor = $Theme.BgCard
    $box.Dock      = [System.Windows.Forms.DockStyle]::Fill
    $box.Margin    = New-Object System.Windows.Forms.Padding(4)
    $box.Padding   = New-Object System.Windows.Forms.Padding(8)
    
    $lbl = New-Object System.Windows.Forms.Label
    $lbl.Font        = $Theme.FontCardTxt
    $lbl.ForeColor   = $Theme.TextPrimary
    $lbl.Dock        = [System.Windows.Forms.DockStyle]::Fill
    $lbl.TextAlign   = [System.Drawing.ContentAlignment]::MiddleLeft
    $lbl.UseMnemonic = $false
    $box.Controls.Add($lbl)
    return @{ GroupBox = $box; Label = $lbl }
}

$boxCpu     = New-SpecBox "İşlemci (CPU)"
$boxGpu     = New-SpecBox "Grafik (GPU)"
$boxRam     = New-SpecBox "Bellek (RAM)"
$boxDisk    = New-SpecBox "Depolama (NVMe/SSD)"
$boxMother  = New-SpecBox "Anakart & BIOS"
$boxNetwork = New-SpecBox "Ağ & İnternet"

$tlpSpecsGrid.Controls.Add($boxCpu.GroupBox,     0, 0)
$tlpSpecsGrid.Controls.Add($boxGpu.GroupBox,     1, 0)
$tlpSpecsGrid.Controls.Add($boxRam.GroupBox,     2, 0)
$tlpSpecsGrid.Controls.Add($boxDisk.GroupBox,    0, 1)
$tlpSpecsGrid.Controls.Add($boxMother.GroupBox,  1, 1)
$tlpSpecsGrid.Controls.Add($boxNetwork.GroupBox, 2, 1)

# Health & Action Strip
$pnlHealth = New-Object System.Windows.Forms.Panel
$pnlHealth.Dock      = [System.Windows.Forms.DockStyle]::Fill
$pnlHealth.BackColor = $Theme.BgCard
$pnlHealth.Padding   = New-Object System.Windows.Forms.Padding(12)
$tlpPage1.Controls.Add($pnlHealth, 0, 2)

$lblHealthHdr = New-Object System.Windows.Forms.Label
$lblHealthHdr.Text        = "Sistem Hazırlık Durumu"
$lblHealthHdr.Font        = $Theme.FontCardHdr
$lblHealthHdr.ForeColor   = $Theme.AccentGreen
$lblHealthHdr.Dock        = [System.Windows.Forms.DockStyle]::Top
$lblHealthHdr.Height      = 22
$lblHealthHdr.UseMnemonic = $false
$pnlHealth.Controls.Add($lblHealthHdr)

$lblHealthBody = New-Object System.Windows.Forms.Label
$lblHealthBody.Font        = $Theme.FontSub
$lblHealthBody.ForeColor   = $Theme.TextPrimary
$lblHealthBody.Dock        = [System.Windows.Forms.DockStyle]::Fill
$lblHealthBody.TextAlign   = [System.Drawing.ContentAlignment]::MiddleLeft
$lblHealthBody.UseMnemonic = $false
$pnlHealth.Controls.Add($lblHealthBody)

# --- Wizard Page 2: Component Selection ---
$pnlPage2 = New-Object System.Windows.Forms.Panel
$pnlPage2.Dock      = [System.Windows.Forms.DockStyle]::Fill
$pnlPage2.BackColor = $Theme.BgMain
$pnlWizardPages.Controls.Add($pnlPage2)

$tlpPage2 = New-Object System.Windows.Forms.TableLayoutPanel
$tlpPage2.Dock        = [System.Windows.Forms.DockStyle]::Fill
$tlpPage2.ColumnCount = 1
$tlpPage2.RowCount    = 3
$tlpPage2.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, 32))) | Out-Null
$tlpPage2.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, 42))) | Out-Null
$tlpPage2.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Percent, 100))) | Out-Null
$pnlPage2.Controls.Add($tlpPage2)

$lblP2Title = New-Object System.Windows.Forms.Label
$lblP2Title.Text        = "Uygulanacak Kurulum Adımları ve Yazılım Paketleri"
$lblP2Title.Font        = $Theme.FontHeader
$lblP2Title.ForeColor   = $Theme.AccentCyan
$lblP2Title.Dock        = [System.Windows.Forms.DockStyle]::Fill
$lblP2Title.UseMnemonic = $false
$tlpPage2.Controls.Add($lblP2Title, 0, 0)

$pnlPresets = New-Object System.Windows.Forms.Panel
$pnlPresets.Dock      = [System.Windows.Forms.DockStyle]::Fill
$tlpPage2.Controls.Add($pnlPresets, 0, 1)

$btnPresetFull = New-FixedBtn "Tam Kurulum (Full)"    0   140 $Theme.BgInput $Theme.TextPrimary
$btnPresetDev  = New-FixedBtn "Geliştirici (Dev)"     150 140 $Theme.BgInput $Theme.TextPrimary
$btnPresetMin  = New-FixedBtn "Temel (Minimal)"       300 130 $Theme.BgInput $Theme.TextPrimary
$btnSelectAll  = New-FixedBtn "Tümünü Seç"            440 100 $Theme.BgInput $Theme.TextPrimary
$btnDeselectAll= New-FixedBtn "Temizle"               550 90  $Theme.BgInput $Theme.TextPrimary

$pnlPresets.Controls.Add($btnPresetFull)
$pnlPresets.Controls.Add($btnPresetDev)
$pnlPresets.Controls.Add($btnPresetMin)
$pnlPresets.Controls.Add($btnSelectAll)
$pnlPresets.Controls.Add($btnDeselectAll)

$clbSteps = New-Object System.Windows.Forms.CheckedListBox
$clbSteps.Dock        = [System.Windows.Forms.DockStyle]::Fill
$clbSteps.BackColor   = $Theme.BgCard
$clbSteps.ForeColor   = $Theme.TextPrimary
$clbSteps.Font        = $Theme.FontSub
$clbSteps.BorderStyle = [System.Windows.Forms.BorderStyle]::None
$clbSteps.CheckOnClick= $true
$tlpPage2.Controls.Add($clbSteps, 0, 2)

# Populate steps into CheckedListBox
foreach ($step in $Script:Steps) {
    $itemText = "[$($step.Order)] $($step.Title) - $($step.Description)"
    $clbSteps.Items.Add($itemText, $true) | Out-Null
}

# --- Wizard Page 3: Offline Installers Dropzone ---
$pnlPage3 = New-Object System.Windows.Forms.Panel
$pnlPage3.Dock      = [System.Windows.Forms.DockStyle]::Fill
$pnlPage3.BackColor = $Theme.BgMain
$pnlWizardPages.Controls.Add($pnlPage3)

$pnlP3TopBar = New-Object System.Windows.Forms.Panel
$pnlP3TopBar.Dock      = [System.Windows.Forms.DockStyle]::Top
$pnlP3TopBar.Height    = 38
$pnlP3TopBar.BackColor = $Theme.BgMain
$pnlPage3.Controls.Add($pnlP3TopBar)

$lblP3Title = New-Object System.Windows.Forms.Label
$lblP3Title.Text        = "📦 Çevrimdışı ve Özel Yükleyiciler ($(Join-Path $Script:UIRoot 'Installers'))"
$lblP3Title.Font        = $Theme.FontHeader
$lblP3Title.ForeColor   = $Theme.AccentCyan
$lblP3Title.Dock        = [System.Windows.Forms.DockStyle]::Left
$lblP3Title.Width       = 480
$lblP3Title.TextAlign   = [System.Drawing.ContentAlignment]::MiddleLeft
$lblP3Title.UseMnemonic = $false
$pnlP3TopBar.Controls.Add($lblP3Title)

$btnRefreshInstallers = New-Object System.Windows.Forms.Button
$btnRefreshInstallers.Text      = "🔄 Listeyi Yenile"
$btnRefreshInstallers.Font      = $Theme.FontButton
$btnRefreshInstallers.Dock      = [System.Windows.Forms.DockStyle]::Right
$btnRefreshInstallers.Width     = 120
$btnRefreshInstallers.BackColor = $Theme.BgInput
$btnRefreshInstallers.ForeColor = $Theme.TextPrimary
$btnRefreshInstallers.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
$btnRefreshInstallers.FlatAppearance.BorderColor = $Theme.Border
$btnRefreshInstallers.Cursor    = [System.Windows.Forms.Cursors]::Hand
$pnlP3TopBar.Controls.Add($btnRefreshInstallers)

$btnOpenInstallers = New-Object System.Windows.Forms.Button
$btnOpenInstallers.Text      = "📁 Klasörü Aç"
$btnOpenInstallers.Font      = $Theme.FontButton
$btnOpenInstallers.Dock      = [System.Windows.Forms.DockStyle]::Right
$btnOpenInstallers.Width     = 120
$btnOpenInstallers.BackColor = $Theme.BgInput
$btnOpenInstallers.ForeColor = $Theme.AccentCyan
$btnOpenInstallers.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
$btnOpenInstallers.FlatAppearance.BorderColor = $Theme.Border
$btnOpenInstallers.Cursor    = [System.Windows.Forms.Cursors]::Hand
$pnlP3TopBar.Controls.Add($btnOpenInstallers)

$lstOffline = New-Object System.Windows.Forms.ListView
$lstOffline.Dock        = [System.Windows.Forms.DockStyle]::Fill
$lstOffline.BackColor   = $Theme.BgCard
$lstOffline.ForeColor   = $Theme.TextPrimary
$lstOffline.Font        = $Theme.FontSub
$lstOffline.View        = [System.Windows.Forms.View]::Details
$lstOffline.FullRowSelect = $true
$lstOffline.CheckBoxes  = $true
$lstOffline.BorderStyle = [System.Windows.Forms.BorderStyle]::None
$lstOffline.Columns.Add("Dosya Adı", 280) | Out-Null
$lstOffline.Columns.Add("Tür", 140) | Out-Null
$lstOffline.Columns.Add("Boyut", 90) | Out-Null
$lstOffline.Columns.Add("Algılanan Sessiz Parametre", 200) | Out-Null
$lstOffline.Columns.Add("Durum", 200) | Out-Null
$pnlPage3.Controls.Add($lstOffline)

# Dock order: Fill first, Top last
$lstOffline.BringToFront()

function Update-OfflineInstallersList {
    $lstOffline.Items.Clear()
    $instDir = Join-Path $Script:UIRoot "Installers"
    if (-not (Test-Path $instDir)) {
        try { New-Item -ItemType Directory -Path $instDir -Force | Out-Null } catch {}
    }

    $installers = @()
    if (Get-Command Get-CustomInstallersList -ErrorAction SilentlyContinue) {
        $installers = Get-CustomInstallersList -Directory $instDir
    }

    $Script:OfflineListLoaded = $true
    if ($installers -and $installers.Count -gt 0) {
        foreach ($inst in $installers) {
            $lvi = New-Object System.Windows.Forms.ListViewItem($inst.FileName)
            $lvi.SubItems.Add($inst.DetectedType) | Out-Null
            $lvi.SubItems.Add("$($inst.SizeMB) MB") | Out-Null
            $lvi.SubItems.Add($inst.SilentArgs) | Out-Null
            $stateText = if ($inst.IsInstalled) { "Kurulu (v$($inst.InstalledVersion)) - atlanır" }
                         elseif ($inst.InstalledVersion) { "Güncellenecek (v$($inst.InstalledVersion) → v$($inst.ProductVersion))" }
                         else { "Kurulacak" }
            $lvi.SubItems.Add($stateText) | Out-Null
            # Already-installed packages start unchecked; ticking them forces a reinstall
            $lvi.Checked = [bool]$inst.Selected
            if ($inst.IsInstalled) { $lvi.ForeColor = $Theme.TextMuted }
            $lvi.Tag     = $inst
            $lstOffline.Items.Add($lvi) | Out-Null
        }
    } else {
        $lvi = New-Object System.Windows.Forms.ListViewItem("Henüz çevrimdışı yükleyici eklenmedi.")
        $lvi.SubItems.Add("--") | Out-Null
        $lvi.SubItems.Add("--") | Out-Null
        $lvi.SubItems.Add("Installers klasörüne .exe / .msi dosyaları kopyalayarak otomatik kurulum sağlayabilirsiniz.") | Out-Null
        $lvi.Checked = $false
        $lvi.ForeColor = $Theme.TextMuted
        $lstOffline.Items.Add($lvi) | Out-Null
    }
}

$btnOpenInstallers.Add_Click({
    $instDir = Join-Path $Script:UIRoot "Installers"
    if (-not (Test-Path $instDir)) {
        try { New-Item -ItemType Directory -Path $instDir -Force | Out-Null } catch {}
    }
    Start-Process "explorer.exe" -ArgumentList "`"$instDir`""
})

$btnRefreshInstallers.Add_Click({
    Update-OfflineInstallersList
})

# --- Wizard Page 4: Live Execution ---
$pnlPage4 = New-Object System.Windows.Forms.Panel
$pnlPage4.Dock      = [System.Windows.Forms.DockStyle]::Fill
$pnlPage4.BackColor = $Theme.BgMain
$pnlWizardPages.Controls.Add($pnlPage4)

$splPage4 = New-Object System.Windows.Forms.SplitContainer
$splPage4.Dock         = [System.Windows.Forms.DockStyle]::Fill
$splPage4.Orientation  = [System.Windows.Forms.Orientation]::Horizontal
$splPage4.SplitterDistance = 240
$splPage4.BackColor    = $Theme.Border
$pnlPage4.Controls.Add($splPage4)

$lstSteps = New-Object System.Windows.Forms.ListView
$lstSteps.Dock        = [System.Windows.Forms.DockStyle]::Fill
$lstSteps.BackColor   = $Theme.BgCard
$lstSteps.ForeColor   = $Theme.TextPrimary
$lstSteps.Font        = $Theme.FontSub
$lstSteps.View        = [System.Windows.Forms.View]::Details
$lstSteps.FullRowSelect = $true
$lstSteps.BorderStyle = [System.Windows.Forms.BorderStyle]::None
$lstSteps.Columns.Add("Adım", 380) | Out-Null
$lstSteps.Columns.Add("Durum", 130) | Out-Null
$lstSteps.Columns.Add("Süre", 90) | Out-Null
$splPage4.Panel1.Controls.Add($lstSteps)

foreach ($step in $Script:Steps) {
    $lvi = New-Object System.Windows.Forms.ListViewItem("$($step.Order). $($step.Title)")
    $lvi.SubItems.Add("Bekliyor") | Out-Null
    $lvi.SubItems.Add("--") | Out-Null
    $lstSteps.Items.Add($lvi) | Out-Null
}

$rtbLog = New-Object System.Windows.Forms.RichTextBox
$rtbLog.Dock        = [System.Windows.Forms.DockStyle]::Fill
$rtbLog.BackColor   = $Theme.BgConsole
$rtbLog.ForeColor   = $Theme.TextPrimary
$rtbLog.Font        = $Theme.FontMono
$rtbLog.BorderStyle = [System.Windows.Forms.BorderStyle]::None
$rtbLog.ReadOnly    = $true
$splPage4.Panel2.Controls.Add($rtbLog)

# --- Wizard Page 5: Completion Summary ---
$pnlPage5 = New-Object System.Windows.Forms.Panel
$pnlPage5.Dock      = [System.Windows.Forms.DockStyle]::Fill
$pnlPage5.BackColor = $Theme.BgMain
$pnlPage5.Padding   = New-Object System.Windows.Forms.Padding(24)
$pnlWizardPages.Controls.Add($pnlPage5)

$lblP5Title = New-Object System.Windows.Forms.Label
$lblP5Title.Text        = "Kurulum Başarıyla Tamamlandı!"
$lblP5Title.Font        = $Theme.FontTitle
$lblP5Title.ForeColor   = $Theme.AccentGreen
$lblP5Title.Dock        = [System.Windows.Forms.DockStyle]::Top
$lblP5Title.Height      = 40
$lblP5Title.UseMnemonic = $false
$pnlPage5.Controls.Add($lblP5Title)

$lblSummaryBody = New-Object System.Windows.Forms.Label
$lblSummaryBody.Font        = $Theme.FontSub
$lblSummaryBody.ForeColor   = $Theme.TextPrimary
$lblSummaryBody.Dock        = [System.Windows.Forms.DockStyle]::Fill
$lblSummaryBody.UseMnemonic = $false
$pnlPage5.Controls.Add($lblSummaryBody)
#endregion

# -------------------------------------------------------------------------------------------------
# TAB 4: GPU & DRIVER CENTER
# -------------------------------------------------------------------------------------------------
#region --- Tab 4: GPU Center ---
$pnlTabGpu = New-Object System.Windows.Forms.Panel
$pnlTabGpu.Dock      = [System.Windows.Forms.DockStyle]::Fill
$pnlTabGpu.BackColor = $Theme.BgMain
$pnlTabGpu.Padding   = New-Object System.Windows.Forms.Padding(16, 12, 16, 12)
$pnlContent.Controls.Add($pnlTabGpu)

$lblGpuCenterHdr = New-Object System.Windows.Forms.Label
$lblGpuCenterHdr.Text        = "Grafik Kartları ve Üretici Yazılım Uyumluluk Merkezi"
$lblGpuCenterHdr.Font        = $Theme.FontHeader
$lblGpuCenterHdr.ForeColor   = $Theme.AccentCyan
$lblGpuCenterHdr.Dock        = [System.Windows.Forms.DockStyle]::Top
$lblGpuCenterHdr.Height      = 32
$lblGpuCenterHdr.UseMnemonic = $false
$pnlTabGpu.Controls.Add($lblGpuCenterHdr)

$flpGpuCards = New-Object System.Windows.Forms.FlowLayoutPanel
$flpGpuCards.Dock        = [System.Windows.Forms.DockStyle]::Fill
$flpGpuCards.AutoScroll  = $true
$flpGpuCards.BackColor   = $Theme.BgMain
$pnlTabGpu.Controls.Add($flpGpuCards)

# GPU operations log stays on this tab (installs used to jump to the Maintenance tab)
$rtbGpuLog = New-Object System.Windows.Forms.RichTextBox
$rtbGpuLog.Dock        = [System.Windows.Forms.DockStyle]::Bottom
$rtbGpuLog.Height      = 150
$rtbGpuLog.BackColor   = $Theme.BgConsole
$rtbGpuLog.ForeColor   = $Theme.TextPrimary
$rtbGpuLog.Font        = $Theme.FontMono
$rtbGpuLog.BorderStyle = [System.Windows.Forms.BorderStyle]::None
$rtbGpuLog.ReadOnly    = $true
$pnlTabGpu.Controls.Add($rtbGpuLog)
$flpGpuCards.BringToFront()
#endregion

# -------------------------------------------------------------------------------------------------
# TAB 5: UNIFIED CONSOLE & LOGS
# -------------------------------------------------------------------------------------------------
#region --- Tab 5: Unified Console ---
$pnlTabConsole = New-Object System.Windows.Forms.Panel
$pnlTabConsole.Dock      = [System.Windows.Forms.DockStyle]::Fill
$pnlTabConsole.BackColor = $Theme.BgMain
$pnlTabConsole.Padding   = New-Object System.Windows.Forms.Padding(16, 12, 16, 12)
$pnlContent.Controls.Add($pnlTabConsole)

$pnlConsoleBar = New-Object System.Windows.Forms.Panel
$pnlConsoleBar.Dock      = [System.Windows.Forms.DockStyle]::Top
$pnlConsoleBar.Height    = 40
$pnlConsoleBar.BackColor = $Theme.BgMain

$lblConsoleHdr = New-Object System.Windows.Forms.Label
$lblConsoleHdr.Text        = "📜 Tüm Sistem Olayları & Konsol Günlüğü"
$lblConsoleHdr.Font        = $Theme.FontHeader
$lblConsoleHdr.ForeColor   = $Theme.AccentCyan
$lblConsoleHdr.Dock        = [System.Windows.Forms.DockStyle]::Left
$lblConsoleHdr.Width       = 380
$lblConsoleHdr.TextAlign   = [System.Drawing.ContentAlignment]::MiddleLeft
$lblConsoleHdr.UseMnemonic = $false
$pnlConsoleBar.Controls.Add($lblConsoleHdr)

$pnlConsoleActions = New-Object System.Windows.Forms.FlowLayoutPanel
$pnlConsoleActions.Dock      = [System.Windows.Forms.DockStyle]::Right
$pnlConsoleActions.Width     = 420
$pnlConsoleActions.FlowDirection = [System.Windows.Forms.FlowDirection]::RightToLeft
$pnlConsoleActions.BackColor = [System.Drawing.Color]::Transparent
$pnlConsoleBar.Controls.Add($pnlConsoleActions)

$btnClearConsole = New-Object System.Windows.Forms.Button
$btnClearConsole.Text      = "🗑️ Temizle"
$btnClearConsole.Font      = $Theme.FontButton
$btnClearConsole.Size      = New-Object System.Drawing.Size(110, 30)
$btnClearConsole.BackColor = $Theme.BgInput
$btnClearConsole.ForeColor = $Theme.TextPrimary
$btnClearConsole.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
$btnClearConsole.FlatAppearance.BorderColor = $Theme.Border
$btnClearConsole.Cursor    = [System.Windows.Forms.Cursors]::Hand
$btnClearConsole.Add_Click({ $rtbUnifiedConsole.Clear() })
$pnlConsoleActions.Controls.Add($btnClearConsole)

$btnCopyConsole = New-Object System.Windows.Forms.Button
$btnCopyConsole.Text      = "📋 Kopyala"
$btnCopyConsole.Font      = $Theme.FontButton
$btnCopyConsole.Size      = New-Object System.Drawing.Size(110, 30)
$btnCopyConsole.BackColor = $Theme.BgInput
$btnCopyConsole.ForeColor = $Theme.TextPrimary
$btnCopyConsole.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
$btnCopyConsole.FlatAppearance.BorderColor = $Theme.Border
$btnCopyConsole.Cursor    = [System.Windows.Forms.Cursors]::Hand
$btnCopyConsole.Add_Click({
    if (-not [string]::IsNullOrEmpty($rtbUnifiedConsole.Text)) {
        [System.Windows.Forms.Clipboard]::SetText($rtbUnifiedConsole.Text)
    }
})
$pnlConsoleActions.Controls.Add($btnCopyConsole)

$rtbUnifiedConsole = New-Object System.Windows.Forms.RichTextBox
$rtbUnifiedConsole.Dock        = [System.Windows.Forms.DockStyle]::Fill
$rtbUnifiedConsole.BackColor   = $Theme.BgConsole
$rtbUnifiedConsole.ForeColor   = $Theme.TextPrimary
$rtbUnifiedConsole.Font        = $Theme.FontMono
$rtbUnifiedConsole.BorderStyle = [System.Windows.Forms.BorderStyle]::None
$rtbUnifiedConsole.ReadOnly    = $true

# Dock order: Fill first, Top last
$pnlTabConsole.Controls.Add($rtbUnifiedConsole)
$pnlTabConsole.Controls.Add($pnlConsoleBar)
#endregion

#region --- Navigation & Tab Switching Logic ---
function Switch-AppTab {
    param([string]$TabName)
    $Script:ActiveTab = $TabName

    $pnlTabMon.Visible     = ($TabName -eq "Monitoring")
    $pnlTabMaint.Visible   = ($TabName -eq "Maintenance")
    $pnlTabWizard.Visible  = ($TabName -eq "Wizard")
    $pnlTabGpu.Visible     = ($TabName -eq "GpuCenter")
    $pnlTabConsole.Visible = ($TabName -eq "Console")

    switch ($TabName) {
        "Monitoring"  { $pnlTabMon.BringToFront() }
        "Maintenance" { $pnlTabMaint.BringToFront() }
        "Wizard"      { $pnlTabWizard.BringToFront() }
        "GpuCenter"   {
            $pnlTabGpu.BringToFront()
            if (-not $Script:GpuCardsLoaded) {
                $Script:GpuCardsLoaded = $true
                try { Update-GpuCenterCard } catch { Write-GpuLog "[ERROR] GPU kartları yüklenemedi: $($_.Exception.Message)" }
            }
        }
        "Console"     { $pnlTabConsole.BringToFront() }
    }

    foreach ($btn in $Script:NavTabButtons) {
        if ($btn.Tag -eq $TabName) {
            $btn.BackColor = $Theme.BgHeader
            $btn.ForeColor = $Theme.AccentCyan
            $btn.FlatAppearance.BorderSize = 1
            $btn.FlatAppearance.BorderColor = $Theme.AccentCyan
        } else {
            $btn.BackColor = $Theme.BgCard
            $btn.ForeColor = $Theme.TextMuted
            $btn.FlatAppearance.BorderSize = 0
        }
    }
}

$btnTabMon.Add_Click({ Switch-AppTab -TabName "Monitoring" })
$btnTabMaint.Add_Click({ Switch-AppTab -TabName "Maintenance" })
$btnTabWizard.Add_Click({ Switch-AppTab -TabName "Wizard" })
$btnTabGpu.Add_Click({ Switch-AppTab -TabName "GpuCenter" })
$btnTabConsole.Add_Click({ Switch-AppTab -TabName "Console" })

function Set-WizardPage {
    param([int]$PageNum)
    $Script:CurrentWizardPage = $PageNum

    $pnlPage1.Visible = ($PageNum -eq 1)
    $pnlPage2.Visible = ($PageNum -eq 2)
    $pnlPage3.Visible = ($PageNum -eq 3)
    $pnlPage4.Visible = ($PageNum -eq 4)
    $pnlPage5.Visible = ($PageNum -eq 5)

    for ($i = 0; $i -lt $Script:BreadcrumbLabels.Count; $i++) {
        if ($i -lt ($PageNum - 1)) {
            $Script:BreadcrumbLabels[$i].ForeColor = $Theme.AccentGreen
        } elseif ($i -eq ($PageNum - 1)) {
            $Script:BreadcrumbLabels[$i].ForeColor = $Theme.AccentCyan
        } else {
            $Script:BreadcrumbLabels[$i].ForeColor = $Theme.TextMuted
        }
    }

    $btnBack.Enabled   = ($PageNum -gt 1 -and $PageNum -lt 4 -and -not $Script:IsRunning)
    $btnExpress.Visible = ($PageNum -eq 1 -and -not $Script:IsRunning)
    $btnNext.Visible   = ($PageNum -lt 3 -and -not $Script:IsRunning)
    $btnStart.Visible  = ($PageNum -eq 3 -and -not $Script:IsRunning)

    switch ($PageNum) {
        1 { $lblNavStatus.Text = "Hazır. Sistem donanım özetini inceleyip ilerleyin." }
        2 { $lblNavStatus.Text = "Kurulum adımlarını ve paketleri seçin." }
        3 { 
            $lblNavStatus.Text = "Özel yükleyicileri gözden geçirin ve Başlat'a tıklayın."
            Update-OfflineInstallersList
        }
        4 { $lblNavStatus.Text = "Kurulum yürütülüyor... Lütfen bekleyin." }
        5 { $lblNavStatus.Text = "Tüm işlemler tamamlandı." }
    }
}

$btnNext.Add_Click({
    if ($Script:CurrentWizardPage -lt 3) { Set-WizardPage ($Script:CurrentWizardPage + 1) }
})

$btnBack.Add_Click({
    if ($Script:CurrentWizardPage -gt 1) { Set-WizardPage ($Script:CurrentWizardPage - 1) }
})

$btnExpress.Add_Click({
    for ($i = 0; $i -lt $clbSteps.Items.Count; $i++) { $clbSteps.SetItemChecked($i, $true) }
    Start-InstallationProcess
})

$btnSelectAll.Add_Click({
    for ($i = 0; $i -lt $clbSteps.Items.Count; $i++) { $clbSteps.SetItemChecked($i, $true) }
})

$btnDeselectAll.Add_Click({
    for ($i = 0; $i -lt $clbSteps.Items.Count; $i++) { $clbSteps.SetItemChecked($i, $false) }
})

$btnPresetFull.Add_Click({
    for ($i = 0; $i -lt $clbSteps.Items.Count; $i++) { $clbSteps.SetItemChecked($i, $true) }
})

$btnPresetDev.Add_Click({
    for ($i = 0; $i -lt $clbSteps.Items.Count; $i++) {
        $step = $Script:Steps[$i]
        $isDev = $step.Id -in @("00_SystemSnapshotAndBackup", "01_SystemBaseline", "04_CoreRuntimes", "05_HardwareAndDrivers", "06_DeveloperTools", "07_EnvironmentAndPaths", "11_NetworkAndDNSOptimization", "12_SecurityBaseline", "08_PostInstallAudit")
        $clbSteps.SetItemChecked($i, $isDev)
    }
})

$btnPresetMin.Add_Click({
    for ($i = 0; $i -lt $clbSteps.Items.Count; $i++) {
        $step = $Script:Steps[$i]
        $isMin = $step.Id -in @("00_SystemSnapshotAndBackup", "01_SystemBaseline", "04_CoreRuntimes", "07_EnvironmentAndPaths", "08_PostInstallAudit")
        $clbSteps.SetItemChecked($i, $isMin)
    }
})
#endregion

#region --- Hardware Specs Population (Page 1) ---
$boxCpu.Label.Text     = "İşlemci özellikleri taranıyor..."
$boxGpu.Label.Text     = "Grafik kartları algılanıyor..."
$boxRam.Label.Text     = "Bellek taranıyor..."
$boxDisk.Label.Text    = "Sürücüler taranıyor..."
$boxMother.Label.Text  = "Anakart & BIOS taranıyor..."
$boxNetwork.Label.Text = "Ağ bağdaştırıcıları taranıyor..."

$Script:SpecsJob = $null
if (Test-Path $Script:SpecsPath) {
    $specsCollector = $Script:SpecsPath
    $Script:SpecsJob = Start-ScriptBlockAsync -ScriptBlock {
        param($path)
        try {
            if (Test-Path $path) { . $path }
            return (Get-SystemSpecsSnapshot)
        } catch {
            return $null
        }
    } -ArgumentList @($specsCollector)
}
#endregion

#region --- GPU Center Cards Population (Tab 4) ---
function Write-GpuLog {
    param([string]$Message)
    $line = if ($Message -match '^\[\d{2}:\d{2}:\d{2}\]') { $Message } else { "[$((Get-Date).ToString('HH:mm:ss'))] $Message" }
    $rtbGpuLog.SelectionStart  = $rtbGpuLog.TextLength
    $rtbGpuLog.SelectionLength = 0
    $rtbGpuLog.SelectionColor  = if ($line -match "\[SUCCESS\]|\[SKIP\]") { $Theme.AccentGreen }
                                 elseif ($line -match "\[WARN\]|\[UPGRADE\]") { $Theme.AccentAmber }
                                 elseif ($line -match "\[ERROR\]") { $Theme.AccentRed }
                                 else { $Theme.TextPrimary }
    $rtbGpuLog.AppendText("$line`r`n")
    $rtbGpuLog.ScrollToCaret()
    $rtbUnifiedConsole.AppendText("[$((Get-Date).ToString('HH:mm:ss'))] [GPU] $Message`r`n")
}

function Update-GpuCenterCard {
    $flpGpuCards.Controls.Clear()
    $controllers = Get-CimInstance Win32_VideoController -ErrorAction SilentlyContinue

    foreach ($ctrl in $controllers) {
        $gpuName = $ctrl.Name
        $driverVer = $ctrl.DriverVersion

        $card = New-Object System.Windows.Forms.Panel
        $card.Width     = 530
        $card.Height    = 240
        $card.BackColor = $Theme.BgCard
        $card.Margin    = New-Object System.Windows.Forms.Padding(10)
        $card.Padding   = New-Object System.Windows.Forms.Padding(16)

        $lblTitle = New-Object System.Windows.Forms.Label
        $lblTitle.Text        = "🎮 $gpuName"
        $lblTitle.Font        = $Theme.FontCardHdr
        $lblTitle.ForeColor   = $Theme.AccentCyan
        $lblTitle.Dock        = [System.Windows.Forms.DockStyle]::Top
        $lblTitle.Height      = 34
        $lblTitle.TextAlign   = [System.Drawing.ContentAlignment]::MiddleLeft
        $lblTitle.UseMnemonic = $false

        # Match with GPU Database (shared with module 09)
        $gpuMatch       = Find-GpuProfile -GpuName $gpuName -GpuDb $Script:GpuDb
        $vendorKey      = $gpuMatch.VendorKey
        $matchedProfile = $gpuMatch.Profile
        $recApp         = if ($matchedProfile) { $matchedProfile.RecommendedApp } else { "Standart Sürücü" }

        # Check installed status (Uninstall registry + Store/AppX packages)
        $isInstalled = $false
        $instVer = ""
        if ($matchedProfile) {
            $chk = Get-GpuCompanionStatus -GpuProfile $matchedProfile
            $isInstalled = $chk.IsInstalled
            $instVer = $chk.InstalledVersion
        }
        $softwareStatus = if ($isInstalled) { "Kurulu (v$instVer)" } else { "Kurulu Değil" }
        $lblDetails = New-Object System.Windows.Forms.Label
        $lblDetails.Font        = $Theme.FontCardTxt
        $lblDetails.ForeColor   = $Theme.TextPrimary
        $lblDetails.Dock        = [System.Windows.Forms.DockStyle]::Fill
        $lblDetails.TextAlign   = [System.Drawing.ContentAlignment]::MiddleLeft
        $lblDetails.Padding     = New-Object System.Windows.Forms.Padding(4, 6, 4, 6)
        $lblDetails.Text        = "Üretici         : $vendorKey`r`n" +
                                  "Sürücü Sürümü   : $driverVer`r`n" +
                                  "Önerilen Yazılım: $recApp`r`n" +
                                  "Yazılım Durumu  : $softwareStatus"
        $lblDetails.UseMnemonic = $false

        $btnRow = New-Object System.Windows.Forms.Panel
        $btnRow.Dock      = [System.Windows.Forms.DockStyle]::Bottom
        $btnRow.Height    = 36

        $btnInstallGpu = New-Object System.Windows.Forms.Button
        $btnInstallGpu.Text      = if ($isInstalled) { "Yeniden Kur / Güncelle" } else { "Yazılımı Kur" }
        $btnInstallGpu.Font      = $Theme.FontButton
        $btnInstallGpu.Dock      = [System.Windows.Forms.DockStyle]::Left
        $btnInstallGpu.Width     = 180
        $btnInstallGpu.BackColor = if ($isInstalled) { $Theme.BgInput } else { $Theme.AccentGreen }
        $btnInstallGpu.ForeColor = [System.Drawing.Color]::White
        $btnInstallGpu.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
        $btnInstallGpu.FlatAppearance.BorderSize = 0
        $btnInstallGpu.Cursor    = [System.Windows.Forms.Cursors]::Hand
        $btnRow.Controls.Add($btnInstallGpu)

        $btnExportDrv = New-Object System.Windows.Forms.Button
        $btnExportDrv.Text      = "⚡ Sürücüyü Yedekle"
        $btnExportDrv.Font      = $Theme.FontButton
        $btnExportDrv.Dock      = [System.Windows.Forms.DockStyle]::Right
        $btnExportDrv.Width     = 160
        $btnExportDrv.BackColor = $Theme.BgInput
        $btnExportDrv.ForeColor = $Theme.TextPrimary
        $btnExportDrv.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
        $btnExportDrv.FlatAppearance.BorderColor = $Theme.Border
        $btnExportDrv.Cursor    = [System.Windows.Forms.Cursors]::Hand
        $btnRow.Controls.Add($btnExportDrv)

        # Proper WinForms dock stack order: Fill first, Bottom next, Top last
        $card.Controls.Add($lblDetails)
        $card.Controls.Add($btnRow)
        $card.Controls.Add($lblTitle)

        # Event Handlers: click handlers are not closures, so per-card data travels on the button itself.
        # (Reading loop variables inside the handler would always yield the LAST GPU's profile.)
        $btnInstallGpu.Tag = [PSCustomObject]@{ Profile = $matchedProfile; App = $recApp }
        $btnInstallGpu.Add_Click({
            $info = $this.Tag
            if (-not $info.Profile) {
                Write-GpuLog "Bu GPU için tanımlı destek yazılımı yok."
                return
            }
            $this.Enabled = $false
            $this.Text    = "Kuruluyor..."
            Write-GpuLog "GPU Destek Yazılımı Kurulumu: $($info.App)..."
            Start-ScriptBlockAsync -Track -ScriptBlock {
                param($p, $app, $q, $pkgPath, $doneMarker)
                try {
                    . $pkgPath
                    $res = Install-GpuCompanionApp -GpuProfile $p -ForceReinstall 6>&1 |
                           ForEach-Object { if ($_ -is [System.Management.Automation.InformationRecord]) { $q.Enqueue("$_"); } else { $_ } }
                    $status = if ($res.Success) { "[SUCCESS] $app kurulum süreci tamamlandı ($($res.TierUsed))." } else { "[ERROR] $app kurulamadı: $($res.Details)" }
                    $q.Enqueue("[$((Get-Date).ToString('HH:mm:ss'))] $status")
                } catch {
                    $q.Enqueue("[$((Get-Date).ToString('HH:mm:ss'))] [ERROR] $app kurulum hatası: $($_.Exception.Message)")
                }
                # Tells the UI timer to rebuild the cards so the new install state is shown
                $q.Enqueue($doneMarker)
            } -ArgumentList @($info.Profile, $info.App, $Script:GpuMsgQueue, $Script:PackageEnginePath, $Script:GpuDoneMarker) | Out-Null
        })

        $btnExportDrv.Add_Click({
            $this.Enabled = $false
            Write-GpuLog "Sistem sürücüleri %ProgramData%\ComputerMaintenancePro\Backups\Drivers klasörüne yedekleniyor..."
            Start-ScriptBlockAsync -Track -ScriptBlock {
                param($path, $q, $doneMarker)
                try {
                    if (Test-Path $path) { . $path }
                    $res = Export-SystemDrivers
                    if ($res.Success) {
                        $q.Enqueue("[$((Get-Date).ToString('HH:mm:ss'))] [SUCCESS] $($res.ExportedCount) sürücü yedeklendi: $($res.Destination)")
                    } else {
                        $q.Enqueue("[$((Get-Date).ToString('HH:mm:ss'))] [ERROR] Sürücü yedekleme başarısız: $($res.ErrorMessage)")
                    }
                } catch {
                    $q.Enqueue("[$((Get-Date).ToString('HH:mm:ss'))] [ERROR] Sürücü yedekleme hatası: $($_.Exception.Message)")
                }
                $q.Enqueue($doneMarker)
            } -ArgumentList @($Script:DriverEnginePath, $Script:GpuMsgQueue, $Script:GpuDoneMarker) | Out-Null
        })

        $flpGpuCards.Controls.Add($card)
    }
}
# Built on first visit of the GPU tab: keeps registry/AppX lookups out of the startup path
$Script:GpuCardsLoaded = $false
#endregion

#region --- Maintenance Action Button Handlers (Tab 2) ---
function Invoke-AsyncMaintenanceAction {
    param([string]$ActionName, [scriptblock]$ActionBlock)

    $rtbMaintLog.SelectionStart = $rtbMaintLog.TextLength
    $rtbMaintLog.SelectionColor = $Theme.AccentCyan
    $rtbMaintLog.AppendText("`r`n=======================================================`r`n")
    $rtbMaintLog.AppendText("  BAKIM İŞLEMİ BAŞLATILDI: $ActionName`r`n")
    $rtbMaintLog.AppendText("=======================================================`r`n")
    $rtbMaintLog.ScrollToCaret()

    # The action travels as TEXT and is re-created inside the worker runspace: a ScriptBlock object
    # keeps affinity to the UI runspace, and invoking it from another thread is unsafe.
    Start-ScriptBlockAsync -Track -ScriptBlock {
        param($code, $queue, $name, $path)
        try {
            if (Test-Path $path) { . $path }
            $action = [scriptblock]::Create($code)
            # *>&1 captures Write-Output AND Write-Host (information stream) of the maintenance engine
            . $action *>&1 | ForEach-Object {
                $text = "$_".Trim()
                if ($text) { $queue.Enqueue($text) }
            }
            $queue.Enqueue("[SUCCESS] $name başarıyla tamamlandı.")
        } catch {
            $queue.Enqueue("[ERROR] $name sırasında hata: $($_.Exception.Message)")
        }
    } -ArgumentList @($ActionBlock.ToString(), $Script:MaintMsgQueue, $ActionName, $Script:MaintEnginePath) | Out-Null
}

$mbtnTemp.Button.Add_Click({
    Invoke-AsyncMaintenanceAction "Hızlı Çöp & Temp Temizliği" {
        $res = Clear-SystemJunkAndTemp -IncludeRecycleBin
        Write-Output "Temizlenen Alan: $($res.MBFreed) MB"
    }
})

$mbtnWinUp.Button.Add_Click({
    Invoke-AsyncMaintenanceAction "Windows Update Önbellek Tasfiyesi" {
        $res = Clear-WindowsUpdateCache
        Write-Output "Temizlenen Güncelleme Önbelleği: $($res.MBFreed) MB"
    }
})

$mbtnDism.Button.Add_Click({
    Invoke-AsyncMaintenanceAction "DISM WinSxS Bileşen Tasfiyesi" {
        Invoke-DismComponentCleanup -ResetBase | Out-Null
    }
})

$mbtnHealth.Button.Add_Click({
    Invoke-AsyncMaintenanceAction "DISM Sistem Sağlık Taraması" {
        Invoke-SystemHealthScan | Out-Null
    }
})

$mbtnNet.Button.Add_Click({
    Invoke-AsyncMaintenanceAction "Ağ & DNS Sıfırlama" {
        Reset-NetworkStack | Out-Null
    }
})

$mbtnTrim.Button.Add_Click({
    Invoke-AsyncMaintenanceAction "SSD ReTRIM Optimizasyonu" {
        Optimize-StorageDrives | Out-Null
    }
})

$mbtnBat.Button.Add_Click({
    Invoke-AsyncMaintenanceAction "Pil Sağlık ve Kalibrasyon Raporu" {
        $bat = Get-BatteryHealthReport
        Write-Output "Pil Sağlığı: $($bat.HealthPercentage)% | Rapor: $($bat.ReportPath)"
        if ($bat.ReportPath -and (Test-Path $bat.ReportPath)) {
            Start-Process $bat.ReportPath
        }
    }
})

$mbtnFull.Button.Add_Click({
    Invoke-AsyncMaintenanceAction "1-Tıkla Tam Sistem Bakımı" {
        Clear-SystemJunkAndTemp -IncludeRecycleBin | Out-Null
        Clear-WindowsUpdateCache | Out-Null
        Invoke-SystemHealthScan | Out-Null
        Invoke-DismComponentCleanup | Out-Null
        Reset-NetworkStack | Out-Null
        Optimize-StorageDrives | Out-Null
        Prune-WindowsEventLogs | Out-Null
    }
})
#endregion

#region --- Installation Runspace (Wizard Tab) ---
function Save-OfflineInstallerSelection {
    <#
    .SYNOPSIS
        Hands the page-3 checkbox selection to module 10 via a file next to the engine state.
    #>
    param([switch]$Resume)
    $selectionFile = Join-Path (Split-Path -Parent $Script:StateFile) "OfflineSelection.json"
    if ($Script:OfflineListLoaded) {
        $files = @($lstOffline.Items | Where-Object { $_.Checked -and $_.Tag } | ForEach-Object { $_.Tag.FileName })
        [PSCustomObject]@{ SavedAt = (Get-Date -Format "o"); Files = $files } |
            ConvertTo-Json -Depth 3 | Set-Content -LiteralPath $selectionFile -Encoding UTF8
    } elseif (-not $Resume -and (Test-Path $selectionFile)) {
        # Express/auto run without visiting page 3: a stale selection from an old session must not filter
        Remove-Item -LiteralPath $selectionFile -Force -ErrorAction SilentlyContinue
    }
}

function Start-InstallationProcess {
    param([switch]$Resume)

    $Script:IsRunning = $true
    Set-WizardPage 4
    foreach ($lvi in $lstSteps.Items) { $lvi.SubItems[1].Text = "Bekliyor"; $lvi.SubItems[2].Text = "--"; $lvi.ForeColor = $Theme.TextPrimary }

    $selectedIds = @()
    for ($i = 0; $i -lt $clbSteps.Items.Count; $i++) {
        if ($clbSteps.GetItemChecked($i)) {
            $selectedIds += $Script:Steps[$i].Id
        }
    }

    try { Save-OfflineInstallerSelection -Resume:$Resume } catch {
        [System.Diagnostics.Trace]::WriteLine("Offline selection save warning: $($_.Exception.Message)")
    }

    $capturedEnginePath = $Script:EnginePath
    $capturedMsgQueue   = $Script:MsgQueue
    $capturedStatusQ    = $Script:StatusQueue
    $capturedStepIds    = $selectedIds
    $capturedResume     = [bool]$Resume

    $runspace = [System.Management.Automation.Runspaces.RunspaceFactory]::CreateRunspace()
    $runspace.ApartmentState = [System.Threading.ApartmentState]::STA
    $runspace.ThreadOptions  = [System.Management.Automation.Runspaces.PSThreadOptions]::ReuseThread
    $runspace.Open()

    $ps = [System.Management.Automation.PowerShell]::Create()
    $ps.Runspace = $runspace

    [void]$ps.AddScript({
        param($EnginePath, $MsgQueue, $StatusQueue, $SelectedIds, $Resume)
        $finalStatus = "FAILED"
        try {
            . $EnginePath
            $callback = {
                param($idx, $status)
                $StatusQueue.Enqueue([PSCustomObject]@{ Index = $idx; Status = $status })
            }
            $result = Start-PostInstallProcess -Queue $MsgQueue -StepStatusCallback $callback -SelectedStepIds $SelectedIds -Resume:$Resume
            $finalStatus = switch ($result) {
                "REBOOT"    { "REBOOT_TRIGGERED" }
                "COMPLETED" { "COMPLETED"         }
                default     { "FAILED"            }
            }
        } catch {
            $MsgQueue.Enqueue("[ERROR] Motor beklenmeyen bir hata ile durdu: $($_.Exception.Message)")
        }
        # Always report a terminal status, otherwise the wizard would stay locked on page 4
        $StatusQueue.Enqueue([PSCustomObject]@{ Index = -1; Status = $finalStatus })
    })

    [void]$ps.AddParameter("EnginePath",  $capturedEnginePath)
    [void]$ps.AddParameter("MsgQueue",    $capturedMsgQueue)
    [void]$ps.AddParameter("StatusQueue", $capturedStatusQ)
    [void]$ps.AddParameter("SelectedIds", $capturedStepIds)
    [void]$ps.AddParameter("Resume",      $capturedResume)

    $asyncResult = $ps.BeginInvoke()
    $Script:WorkerPS     = $ps
    $Script:WorkerRS     = $runspace
    $Script:WorkerResult = $asyncResult
}

$btnStart.Add_Click({ Start-InstallationProcess })
#endregion

#region --- UI Update & Telemetry Timers ---
# Fast UI log pump timer (100ms)
$uiTimer = New-Object System.Windows.Forms.Timer
$uiTimer.Interval = 100
$uiTimer.Add_Tick({
    # 0. Hardware Specs Background Job
    if ($Script:SpecsJob -and $Script:SpecsJob.AsyncResult.IsCompleted) {
        try {
            $rawSpecs = $Script:SpecsJob.PowerShell.EndInvoke($Script:SpecsJob.AsyncResult)
            $specs = $rawSpecs | Select-Object -Last 1
            if ($specs) {
                $boxCpu.Label.Text     = "$($specs.Processor.Name)`r`n$($specs.Processor.Cores) Çekirdek / $($specs.Processor.LogicalProcessors) İş Parçacığı | $($specs.Processor.MaxClockGHz) GHz"
                $gpus = $specs.Display.GPUs
                $gpuText = ($gpus | ForEach-Object {
                    $vramStr = if ($_.VRAM_MB -gt 512) { "$([math]::Round($_.VRAM_MB/1024,1)) GB" } elseif ($_.VRAM_MB -gt 0) { "$($_.VRAM_MB) MB" } else { "Sistem Paylaşımlı" }
                    "$($_.Vendor): $($_.Name) ($vramStr)"
                }) -join "`r`n"
                $boxGpu.Label.Text     = $gpuText
                $boxRam.Label.Text     = "$($specs.Memory.TotalGB) GB ($($specs.Memory.ModuleCount) modül) | $($specs.Memory.Speed) MHz"
                $disks = $specs.Storage.Disks
                $boxDisk.Label.Text    = ($disks | ForEach-Object { "$($_.Index) [$($_.Model)] ($($_.SizeGB) GB - Boş: $($_.FreeGB) GB)" }) -join "`r`n"
                $boxMother.Label.Text  = "$($specs.Motherboard.Manufacturer) $($specs.Motherboard.Product)`r`nBIOS: $($specs.Motherboard.BIOSVersion)"
                $boxNetwork.Label.Text = "$($specs.Network.Adapters.Count) Ağ Bağdaştırıcısı Aktif"

                $secBootStr = if ($specs.Platform.SecureBoot) { "Aktif" } else { "Devre Dışı" }
                $vmStr      = if ($specs.Platform.IsVirtualMachine) { "Evet" } else { "Fiziksel PC" }
                $lblHealthBody.Text = "Form Faktör: $($specs.Platform.FormFactor)`r`n" +
                    "Güvenli Önyükleme (Secure Boot): $secBootStr | " +
                    "Sanal Makine: $vmStr`r`n" +
                    "Windows Sürümü: $($specs.OperatingSystem.Caption) ($($specs.OperatingSystem.BuildNumber))"
            }
        } catch {
            [System.Diagnostics.Trace]::WriteLine("System specs background render warning: $($_.Exception.Message)")
        }
        Stop-ScriptBlockAsync $Script:SpecsJob
        $Script:SpecsJob = $null
    }
    # 1. Wizard Log Queue
    $msg = ""
    $appended = $false
    while ($Script:MsgQueue.TryDequeue([ref]$msg)) {
        if ([string]::IsNullOrEmpty($msg)) { continue }
        $rtbLog.SelectionStart  = $rtbLog.TextLength
        $rtbLog.SelectionLength = 0
        $rtbLog.SelectionColor = if ($msg -match "\[SUCCESS\]|\[SKIP\]") { $Theme.AccentGreen }
                                 elseif ($msg -match "\[WARN\]|\[UPGRADE\]") { $Theme.AccentAmber }
                                 elseif ($msg -match "\[ERROR\]")   { $Theme.AccentRed   }
                                 else { $Theme.TextPrimary }
        $rtbLog.AppendText("$msg`r`n")
        $rtbUnifiedConsole.AppendText("[$((Get-Date).ToString('HH:mm:ss'))] $msg`r`n")
        $appended = $true
    }
    if ($appended) { $rtbLog.ScrollToCaret() }

    # 2b. GPU Center Log Queue (installs / driver backup stay on the GPU tab)
    $gMsg = ""
    while ($Script:GpuMsgQueue.TryDequeue([ref]$gMsg)) {
        if ([string]::IsNullOrEmpty($gMsg)) { continue }
        if ($gMsg -eq $Script:GpuDoneMarker) {
            try { Update-GpuCenterCard } catch { Write-GpuLog "[WARN] Kartlar yenilenemedi: $($_.Exception.Message)" }
            continue
        }
        Write-GpuLog $gMsg
    }

    # 2. Maintenance Log Queue
    $mMsg = ""
    while ($Script:MaintMsgQueue.TryDequeue([ref]$mMsg)) {
        if ([string]::IsNullOrEmpty($mMsg)) { continue }
        $rtbMaintLog.SelectionStart  = $rtbMaintLog.TextLength
        $rtbMaintLog.SelectionLength = 0
        $rtbMaintLog.SelectionColor = if ($mMsg -match "\[SUCCESS\]|\[SKIP\]") { $Theme.AccentGreen }
                                      elseif ($mMsg -match "\[WARN\]|\[UPGRADE\]") { $Theme.AccentAmber }
                                      elseif ($mMsg -match "\[ERROR\]") { $Theme.AccentRed }
                                      else { $Theme.TextPrimary }
        $rtbMaintLog.AppendText("$mMsg`r`n")
        $rtbMaintLog.ScrollToCaret()
        $rtbUnifiedConsole.AppendText("[$((Get-Date).ToString('HH:mm:ss'))] [MAINT] $mMsg`r`n")
    }

    # 3. Wizard Step Status Updates
    $update = $null
    while ($Script:StatusQueue.TryDequeue([ref]$update)) {
        $idx = $update.Index
        $st  = $update.Status

        if ($idx -ge 0 -and $idx -lt $lstSteps.Items.Count) {
            $lvi = $lstSteps.Items[$idx]
            switch ($st) {
                "Running" { $lvi.SubItems[1].Text = ">> Çalışıyor"; $lvi.ForeColor = $Theme.AccentCyan; $lvi.Tag = Get-Date }
                "Success" { $lvi.SubItems[1].Text = "OK Başarılı";  $lvi.ForeColor = $Theme.AccentGreen }
                "Warning" { $lvi.SubItems[1].Text = "!! Uyarı";    $lvi.ForeColor = $Theme.AccentAmber }
                "Skipped" { $lvi.SubItems[1].Text = "-- Atlandı";   $lvi.ForeColor = $Theme.TextMuted }
                "Failed"  { $lvi.SubItems[1].Text = "X Hata";      $lvi.ForeColor = $Theme.AccentRed }
            }
            if ($st -in @("Success", "Warning", "Failed") -and $lvi.Tag -is [datetime]) {
                $lvi.SubItems[2].Text = "{0:N0} sn" -f ((Get-Date) - $lvi.Tag).TotalSeconds
            }
        }

        if ($idx -eq -1) {
            Complete-WizardRun -Outcome $st
        }
    }

    # 4. Dispose finished fire-and-forget runspaces (maintenance / GPU / driver jobs)
    if ($Script:BackgroundJobs.Count -gt 0) { Clear-CompletedBackgroundJobs }
})

function Complete-WizardRun {
    <#
    .SYNOPSIS
        Terminal state of an engine run: summary page for every outcome + reboot handling.
    #>
    param([string]$Outcome)

    $Script:IsRunning = $false
    try { if ($Script:WorkerPS) { [void]$Script:WorkerPS.EndInvoke($Script:WorkerResult) } } catch {}
    try { if ($Script:WorkerPS) { $Script:WorkerPS.Dispose() }; if ($Script:WorkerRS) { $Script:WorkerRS.Close(); $Script:WorkerRS.Dispose() } } catch {}
    $Script:WorkerPS = $null; $Script:WorkerRS = $null

    $stObj = $null
    try { $stObj = Get-EngineState } catch {}
    $stats = if ($stObj) {
        "• Toplam Adım    : $($stObj.TotalSteps)`r`n" +
        "• Başarılı Adım  : $($stObj.CompletedSteps)`r`n" +
        "• Hatalı Adım    : $($stObj.FailedSteps)`r`n" +
        "• Atlanan Adım   : $(@($stObj.StepResults | Where-Object { $_.Status -eq 'Skipped' }).Count)`r`n"
    } else { "" }

    switch ($Outcome) {
        "COMPLETED" {
            $lblP5Title.Text      = "Kurulum Başarıyla Tamamlandı!"
            $lblP5Title.ForeColor = $Theme.AccentGreen
            $rebootNote = if ($stObj -and $stObj.RebootPending) { "`r`n⚠ Bazı bileşenler yeniden başlatma sonrası etkin olacak. Uygun bir zamanda bilgisayarı yeniden başlatın.`r`n" } else { "" }
            $lblSummaryBody.Text  = "Tüm seçili adımlar işlendi.`r`n`r`n$stats• Rapor Dosyası  : $Script:SummaryReport`r`n$rebootNote"
        }
        "FAILED" {
            $lblP5Title.Text      = "Kurulum Kritik Hata Nedeniyle Durdu"
            $lblP5Title.ForeColor = $Theme.AccentRed
            $failedStep = if ($stObj) { $stObj.StepResults | Where-Object { $_.Status -eq "Failed" } | Select-Object -First 1 } else { $null }
            $failText   = if ($failedStep) { "• Hatalı Adım    : $($failedStep.Title)`r`n• Hata           : $($failedStep.ErrorMessage)`r`n" } else { "" }
            $lblSummaryBody.Text  = "Ayrıntılar için 'Log Aç' butonunu kullanın.`r`n`r`n$stats$failText• Log Dosyası    : $Script:LogFile"
        }
        "REBOOT_TRIGGERED" {
            $countdown = Get-RebootCountdownSeconds
            $lblP5Title.Text      = "Yeniden Başlatma Gerekiyor"
            $lblP5Title.ForeColor = $Theme.AccentAmber
            $lblSummaryBody.Text  = "Kurulum duraklatıldı. Bilgisayar yeniden başladığında kaldığı adımdan otomatik devam edecek.`r`n`r`n$stats"
            Set-WizardPage 5

            if ($Script:Config.AutoReboot -ne $false) {
                & shutdown.exe /r /t $countdown /c "Computer Maintenance Pro: Kurulum devam icin yeniden baslama." | Out-Null
                $r = [System.Windows.Forms.MessageBox]::Show("Bilgisayar $countdown saniye içinde yeniden başlatılacak.`r`n`r`nİptal etmek için 'İptal' seçin (kurulum bir sonraki oturum açılışında devam eder).", "Yeniden Başlatma", [System.Windows.Forms.MessageBoxButtons]::OKCancel, [System.Windows.Forms.MessageBoxIcon]::Warning)
                if ($r -eq [System.Windows.Forms.DialogResult]::Cancel) {
                    & shutdown.exe /a | Out-Null
                    $lblNavStatus.Text = "Yeniden başlatma iptal edildi. Kurulum sonraki oturum açılışında devam edecek."
                }
            } else {
                $r = [System.Windows.Forms.MessageBox]::Show("Kuruluma devam etmek için yeniden başlatma gerekiyor. Şimdi yeniden başlatılsın mı?", "Yeniden Başlatma", [System.Windows.Forms.MessageBoxButtons]::YesNo, [System.Windows.Forms.MessageBoxIcon]::Question)
                if ($r -eq [System.Windows.Forms.DialogResult]::Yes) { & shutdown.exe /r /t 5 | Out-Null }
            }
            return
        }
    }
    Set-WizardPage 5
}

# Telemetry: ONE long-lived sampler runspace keeps the hardware cache and the (rate based)
# performance counters alive between samples. The 250ms UI timer only drains its queue.
function Start-TelemetrySampler {
    $Script:TelemetryJob = Start-ScriptBlockAsync -ScriptBlock {
        param($path, $queue, $ctl)
        try {
            . $path
            [void](Initialize-HardwareMonitorEngine)
        } catch {
            return
        }
        while (-not $ctl.Stop) {
            if ($ctl.Active -or $ctl.RefreshNow) {
                $ctl.RefreshNow = $false
                try { $queue.Enqueue((Get-LiveTelemetrySample)) } catch {}
                $drop = $null
                while ($queue.Count -gt 3) { [void]$queue.TryDequeue([ref]$drop) }
            }
            # Sleep in small slices so Stop / RefreshNow react quickly
            $waited = 0
            while ($waited -lt $ctl.IntervalMs -and -not $ctl.Stop -and -not $ctl.RefreshNow) {
                Start-Sleep -Milliseconds 100
                $waited += 100
            }
        }
    } -ArgumentList @($Script:HwMonEnginePath, $Script:TelemetryQueue, $Script:TelemetryControl)
}

function Stop-TelemetrySampler {
    $Script:TelemetryControl.Stop = $true
    if ($Script:TelemetryJob) {
        $deadline = (Get-Date).AddSeconds(2)
        while (-not $Script:TelemetryJob.AsyncResult.IsCompleted -and (Get-Date) -lt $deadline) { Start-Sleep -Milliseconds 50 }
        Stop-ScriptBlockAsync $Script:TelemetryJob
        $Script:TelemetryJob = $null
    }
}

$telemetryTimer = New-Object System.Windows.Forms.Timer
$telemetryTimer.Interval = 250

$telemetryTimer.Add_Tick({
    # Sample only while the monitoring tab is visible (plus the very first sample)
    $Script:TelemetryControl.Active = ($Script:ActiveTab -eq "Monitoring" -or $Script:LastTelemetryUpdate -eq [DateTime]::MinValue)

    $s = $null
    $next = $null
    while ($Script:TelemetryQueue.TryDequeue([ref]$next)) { $s = $next }

    if ($s) {
        $Script:LastTelemetryUpdate = Get-Date

        # CPU
        $cardCpu.ValueLabel.Text   = "$($s.CpuLoadPct) %"
        $cardCpu.ProgressBar.Value = [Math]::Min(100, [Math]::Max(0, [int]$s.CpuLoadPct))
        $tempStr = if ($s.CpuTempC) { "$($s.CpuTempC) °C" } else { "Sensör Yok" }
        $cardCpu.SubLabel.Text     = "Sıcaklık: $tempStr | Saat: $($s.CpuClockGhz) GHz`r`n$($s.CpuCores) Çekirdek / $($s.CpuThreads) İzlek"
        if ($s.CpuTempC -gt 80) { $cardCpu.ValueLabel.ForeColor = $Theme.AccentRed }
        elseif ($s.CpuTempC -gt 65) { $cardCpu.ValueLabel.ForeColor = $Theme.AccentAmber }
        else { $cardCpu.ValueLabel.ForeColor = $Theme.AccentCyan }

        # RAM
        $cardRam.ValueLabel.Text   = "$($s.RamLoadPct) %"
        $cardRam.ProgressBar.Value = [Math]::Min(100, [Math]::Max(0, [int]$s.RamLoadPct))
        $cardRam.SubLabel.Text     = "Kullanılan: $($s.RamUsedGB) GB / $($s.RamTotalGB) GB`r`nBoş Bellek: $($s.RamFreeGB) GB"

        # Discrete GPU
        $dgpu = $s.GPUs | Where-Object { $_.IsDiscrete } | Select-Object -First 1
        if ($dgpu) {
            $cardGpuD.ValueLabel.Text   = "$($dgpu.LoadPercentage) %"
            $cardGpuD.ProgressBar.Value = [Math]::Min(100, [Math]::Max(0, [int]$dgpu.LoadPercentage))
            $gTemp = if ($dgpu.TemperatureC) { "$($dgpu.TemperatureC) °C" } else { "--" }
            $cardGpuD.SubLabel.Text     = "$($dgpu.Name)`r`nSıcaklık: $gTemp | VRAM: $($dgpu.VramUsedMB) / $($dgpu.VramTotalMB) MB"
        } else {
            $cardGpuD.ValueLabel.Text = "Yok"
            $cardGpuD.SubLabel.Text   = "Harici grafik kartı algılanmadı"
        }

        # Integrated GPU
        $igpu = $s.GPUs | Where-Object { -not $_.IsDiscrete } | Select-Object -First 1
        if ($igpu) {
            $cardGpuI.ValueLabel.Text   = "$($igpu.LoadPercentage) %"
            $cardGpuI.ProgressBar.Value = [Math]::Min(100, [Math]::Max(0, [int]$igpu.LoadPercentage))
            $cardGpuI.SubLabel.Text     = "$($igpu.Name)`r`nVRAM: $($igpu.VramTotalMB) MB"
        } else {
            $cardGpuI.ValueLabel.Text = "--"
            $cardGpuI.SubLabel.Text   = "Dahili grafik yok"
        }

        # Storage (Primary C: drive)
        $cDrive = $s.Disks | Where-Object { $_.DriveLetter -like "C*" } | Select-Object -First 1
        if ($cDrive) {
            $cardDisk.ValueLabel.Text   = "$($cDrive.LoadPercentage) %"
            $cardDisk.ProgressBar.Value = [Math]::Min(100, [Math]::Max(0, [int]$cDrive.LoadPercentage))
            $diskLines = ($s.Disks | ForEach-Object { "$($_.DriveLetter) Boş: $($_.FreeGB)/$($_.TotalGB) GB" }) -join " | "
            $cardDisk.SubLabel.Text     = "$diskLines"
        }

        # Battery
        if ($s.Battery.HasBattery) {
            $cardBat.ValueLabel.Text   = "$($s.Battery.ChargePct) %"
            $cardBat.ProgressBar.Value = [Math]::Min(100, [Math]::Max(0, [int]$s.Battery.ChargePct))
            $cardBat.SubLabel.Text     = "Durum: $($s.Battery.Status)`r`nAC Adaptör / Mobil Çalışma"
        } else {
            $cardBat.ValueLabel.Text   = "AC Güç"
            $cardBat.ProgressBar.Value = 100
            $cardBat.SubLabel.Text     = "Masaüstü İş İstasyonu (Pil Yok)"
        }

        $lblMonStatus.Text = "Canlı Donanım & Performans Telemetrisi (Yenilenme: 2 sn | $($s.Timestamp))"
    }
})

$btnRefreshMon.Add_Click({
    $lblMonStatus.Text = "Canlı Donanım & Performans Telemetrisi (Yenileniyor...)"
    if (-not $Script:TelemetryJob -or $Script:TelemetryJob.AsyncResult.IsCompleted) {
        if ($Script:TelemetryJob) { Stop-ScriptBlockAsync $Script:TelemetryJob }
        $Script:TelemetryControl.Stop = $false
        Start-TelemetrySampler
    }
    $Script:TelemetryControl.RefreshNow = $true
})
#endregion

#region --- Standard Button Handlers & Form Lifecycle ---
$btnOpenLog.Add_Click({
    $logPath = $Script:LogFile
    if (Test-Path $logPath) { Start-Process "notepad.exe" -ArgumentList "`"$logPath`"" }
})

$btnClose.Add_Click({
    $form.Close()
})

$form.Add_FormClosing({
    param($formObj, $closeEvent)
    if ($Script:IsRunning) {
        $r = [System.Windows.Forms.MessageBox]::Show("Kurulum süreci devam ediyor. Kapatmak istediğinizden emin misiniz?", "Uyarı", [System.Windows.Forms.MessageBoxButtons]::YesNo, [System.Windows.Forms.MessageBoxIcon]::Question)
        if ($r -eq [System.Windows.Forms.DialogResult]::No) {
            $closeEvent.Cancel = $true
            return
        }
    }

    try { $uiTimer.Stop() } catch {}
    try { $telemetryTimer.Stop() } catch {}

    # Each cleanup step is isolated: an exception escaping a WinForms event handler
    # surfaces as the .NET "unhandled exception" dialog instead of a clean exit.
    try { Stop-TelemetrySampler } catch {}
    # NOTE: never use @() on a List[object] here - Windows PowerShell 5.1 throws
    # "Argument types do not match" (PSToObjectArrayBinder). ToArray() is safe.
    try {
        foreach ($job in $Script:BackgroundJobs.ToArray()) { Stop-ScriptBlockAsync $job }
        $Script:BackgroundJobs.Clear()
    } catch {}

    try {
        if ($Script:SpecsJob) {
            Stop-ScriptBlockAsync $Script:SpecsJob
            $Script:SpecsJob = $null
        }
    } catch {}

    try {
        if ($Script:WorkerPS) { $Script:WorkerPS.Stop(); $Script:WorkerPS.Dispose() }
        if ($Script:WorkerRS) { $Script:WorkerRS.Close(); $Script:WorkerRS.Dispose() }
    } catch {
        [System.Diagnostics.Trace]::WriteLine("Form closing cleanup warning: $($_.Exception.Message)")
    }
    try { $Script:InstanceMutex.ReleaseMutex(); $Script:InstanceMutex.Dispose() } catch {}
})

$form.Add_FormClosed({
    try { $uiTimer.Stop(); $uiTimer.Dispose() } catch {}
    try { $telemetryTimer.Stop(); $telemetryTimer.Dispose() } catch {}
    try { [System.Windows.Forms.Application]::ExitThread() } catch {}
    [System.Diagnostics.Process]::GetCurrentProcess().Kill()
})
#endregion

# Startup automation
if ($Resume -or $Auto) {
    $form.Add_Shown({
        Switch-AppTab -TabName "Wizard"
        Start-Sleep -Milliseconds 600
        for ($i = 0; $i -lt $clbSteps.Items.Count; $i++) { $clbSteps.SetItemChecked($i, $true) }
        # -Resume: engine continues the persisted session and restores its original step selection
        Start-InstallationProcess -Resume:$Resume
    })
} else {
    Switch-AppTab -TabName "Monitoring"
    Set-WizardPage 1
}

$form.WindowState = [System.Windows.Forms.FormWindowState]::Normal
$form.ShowInTaskbar = $true
$form.TopMost = $true
$form.Add_Shown({
    Write-UiTrace "Pencere gosterildi."
    $form.Activate()
    $form.BringToFront()
    $form.Focus()
    $form.TopMost = $false
})

Write-UiTrace "Form hazir, mesaj dongusu baslatiliyor."
$uiTimer.Start()
Start-TelemetrySampler
$telemetryTimer.Start()
[System.Windows.Forms.Application]::Run($form)
[System.Environment]::Exit(0)
