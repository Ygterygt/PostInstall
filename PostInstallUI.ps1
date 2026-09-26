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
$Script:IsRunning     = $false
$Script:CurrentWizardPage = 1
$Script:ActiveTab     = "Monitoring"
#endregion

#region --- Main Window Form ---
$form = New-Object System.Windows.Forms.Form
$form.Text            = "Computer Maintenance Pro - Enterprise System Care & Staging Suite v4.0.0"
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
$lblTitle.Text        = "  COMPUTER MAINTENANCE PRO v4.0"
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
    $lblHdr.Height      = 24
    $lblHdr.UseMnemonic = $false
    $card.Controls.Add($lblHdr)

    $lblVal = New-Object System.Windows.Forms.Label
    $lblVal.Text        = "--"
    $lblVal.Font        = $Theme.FontGaugeVal
    $lblVal.ForeColor   = $Theme.AccentCyan
    $lblVal.Dock        = [System.Windows.Forms.DockStyle]::Top
    $lblVal.Height      = 38
    $lblVal.TextAlign   = [System.Drawing.ContentAlignment]::MiddleLeft
    $lblVal.UseMnemonic = $false
    $card.Controls.Add($lblVal)

    $pb = New-Object System.Windows.Forms.ProgressBar
    $pb.Dock      = [System.Windows.Forms.DockStyle]::Top
    $pb.Height    = 10
    $pb.Maximum   = 100
    $pb.Value     = 0
    $pb.Style     = [System.Windows.Forms.ProgressBarStyle]::Continuous
    $card.Controls.Add($pb)

    $lblSub = New-Object System.Windows.Forms.Label
    $lblSub.Text        = "Yükleniyor..."
    $lblSub.Font        = $Theme.FontCardTxt
    $lblSub.ForeColor   = $Theme.TextMuted
    $lblSub.Dock        = [System.Windows.Forms.DockStyle]::Fill
    $lblSub.TextAlign   = [System.Drawing.ContentAlignment]::MiddleLeft
    $lblSub.UseMnemonic = $false
    $card.Controls.Add($lblSub)

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
    $card.Controls.Add($lbl)

    $lblD = New-Object System.Windows.Forms.Label
    $lblD.Text        = $Desc
    $lblD.Font        = $Theme.FontSub
    $lblD.ForeColor   = $Theme.TextMuted
    $lblD.Dock        = [System.Windows.Forms.DockStyle]::Fill
    $lblD.UseMnemonic = $false
    $card.Controls.Add($lblD)

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
    $card.Controls.Add($btn)

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

$lblP3Title = New-Object System.Windows.Forms.Label
$lblP3Title.Text        = "Çevrimdışı ve Özel Yükleyiciler (C:\PostInstall\Installers)"
$lblP3Title.Font        = $Theme.FontHeader
$lblP3Title.ForeColor   = $Theme.AccentCyan
$lblP3Title.Dock        = [System.Windows.Forms.DockStyle]::Top
$lblP3Title.Height      = 32
$lblP3Title.UseMnemonic = $false
$pnlPage3.Controls.Add($lblP3Title)

$lstOffline = New-Object System.Windows.Forms.ListView
$lstOffline.Dock        = [System.Windows.Forms.DockStyle]::Fill
$lstOffline.BackColor   = $Theme.BgCard
$lstOffline.ForeColor   = $Theme.TextPrimary
$lstOffline.Font        = $Theme.FontSub
$lstOffline.View        = [System.Windows.Forms.View]::Details
$lstOffline.FullRowSelect = $true
$lstOffline.BorderStyle = [System.Windows.Forms.BorderStyle]::None
$lstOffline.Columns.Add("Dosya Adı", 240) | Out-Null
$lstOffline.Columns.Add("Tür", 90) | Out-Null
$lstOffline.Columns.Add("Boyut", 90) | Out-Null
$lstOffline.Columns.Add("Algılanan Sessiz Parametre", 240) | Out-Null
$pnlPage3.Controls.Add($lstOffline)

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

$rtbUnifiedConsole = New-Object System.Windows.Forms.RichTextBox
$rtbUnifiedConsole.Dock        = [System.Windows.Forms.DockStyle]::Fill
$rtbUnifiedConsole.BackColor   = $Theme.BgConsole
$rtbUnifiedConsole.ForeColor   = $Theme.TextPrimary
$rtbUnifiedConsole.Font        = $Theme.FontMono
$rtbUnifiedConsole.BorderStyle = [System.Windows.Forms.BorderStyle]::None
$rtbUnifiedConsole.ReadOnly    = $true
$pnlTabConsole.Controls.Add($rtbUnifiedConsole)
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

    foreach ($btn in $Script:NavTabButtons) {
        if ($btn.Tag -eq $TabName) {
            $btn.BackColor = $Theme.BgHeader
            $btn.ForeColor = $Theme.AccentCyan
        } else {
            $btn.BackColor = $Theme.BgCard
            $btn.ForeColor = $Theme.TextMuted
        }
    }
}

foreach ($btn in $Script:NavTabButtons) {
    $btn.Add_Click({
        Switch-AppTab -TabName $this.Tag
    })
}

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
        3 { $lblNavStatus.Text = "Özel yükleyicileri gözden geçirin ve Başlat'a tıklayın." }
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
try {
    if (Get-Command "Get-SystemSpecsSnapshot" -ErrorAction SilentlyContinue) {
        $specs = Get-SystemSpecsSnapshot
        $boxCpu.Label.Text     = "$($specs.Processor.Name)`r`n$($specs.Processor.Cores) Çekirdek / $($specs.Processor.LogicalProcessors) İş Parçacığı | $($specs.Processor.MaxClockGHz) GHz"
        $gpus = $specs.Display.GPUs
        $gpuText = ($gpus | ForEach-Object { "$($_.Vendor): $($_.Name) ($([math]::Round($_.VRAM_MB/1024,1)) GB)" }) -join "`r`n"
        $boxGpu.Label.Text     = $gpuText
        $boxRam.Label.Text     = "$($specs.Memory.TotalGB) GB ($($specs.Memory.ModuleCount) modül) | $($specs.Memory.Speed) MHz"
        $disks = $specs.Storage.Disks
        $boxDisk.Label.Text    = ($disks | ForEach-Object { "$($_.Index): $($_.Model) ($($_.SizeGB) GB)" }) -join "`r`n"
        $boxMother.Label.Text  = "$($specs.Motherboard.Manufacturer) $($specs.Motherboard.Product)`r`nBIOS: $($specs.Motherboard.BIOSVersion)"
        $boxNetwork.Label.Text = "$($specs.Network.Adapters.Count) Ağ Bağdaştırıcısı Aktif"

        $lblHealthBody.Text = "Form Faktör: $($specs.Platform.FormFactor)`r`n" +
            "Güvenli Önyükleme (Secure Boot): $(if ($specs.Platform.SecureBoot) { 'Aktif' } else { 'Devre Dışı' }) | " +
            "Sanal Makine: $(if ($specs.Platform.IsVirtualMachine) { 'Evet' } else { 'Fiziksel PC' })`r`n" +
            "Windows Sürümü: $($specs.OperatingSystem.Caption) ($($specs.OperatingSystem.BuildNumber))"
    }
} catch {
    [System.Diagnostics.Trace]::WriteLine("System specs rendering warning: $($_.Exception.Message)")
}
#endregion

#region --- GPU Center Cards Population (Tab 4) ---
function Update-GpuCenterCard {
    $flpGpuCards.Controls.Clear()
    $controllers = Get-CimInstance Win32_VideoController -ErrorAction SilentlyContinue

    foreach ($ctrl in $controllers) {
        $gpuName = $ctrl.Name
        $driverVer = $ctrl.DriverVersion

        $card = New-Object System.Windows.Forms.Panel
        $card.Width     = 520
        $card.Height    = 220
        $card.BackColor = $Theme.BgCard
        $card.Margin    = New-Object System.Windows.Forms.Padding(8)
        $card.Padding   = New-Object System.Windows.Forms.Padding(14)

        $lblTitle = New-Object System.Windows.Forms.Label
        $lblTitle.Text        = "🎮 $gpuName"
        $lblTitle.Font        = $Theme.FontCardHdr
        $lblTitle.ForeColor   = $Theme.AccentCyan
        $lblTitle.Dock        = [System.Windows.Forms.DockStyle]::Top
        $lblTitle.Height      = 26
        $lblTitle.UseMnemonic = $false
        $card.Controls.Add($lblTitle)

        # Match with GPU Database
        $vendorKey = "Virtual"
        if ($gpuName -match "NVIDIA|GeForce|RTX|GTX|Quadro") { $vendorKey = "NVIDIA" }
        elseif ($gpuName -match "AMD|Radeon") { $vendorKey = "AMD" }
        elseif ($gpuName -match "Intel") { $vendorKey = "Intel" }

        $recApp = "Standart Sürücü"
        $matchedProfile = $null
        if ($Script:GpuDb -and $Script:GpuDb.Vendors.$vendorKey) {
            $vData = $Script:GpuDb.Vendors.$vendorKey
            foreach ($p in $vData.Profiles) {
                if ($gpuName -match $p.Pattern) { $matchedProfile = $p; break }
            }
            if (-not $matchedProfile) { $matchedProfile = $vData.Profiles | Select-Object -First 1 }
            if ($matchedProfile) { $recApp = $matchedProfile.RecommendedApp }
        }

        # Check installed status
        $isInstalled = $false
        $instVer = ""
        if ($matchedProfile) {
            $chk = Get-InstalledAppInfo -Name $recApp -RegistryPattern $matchedProfile.RegistryDisplayName
            $isInstalled = $chk.IsInstalled
            $instVer = $chk.InstalledVersion
        }

        $lblDetails = New-Object System.Windows.Forms.Label
        $lblDetails.Font        = $Theme.FontCardTxt
        $lblDetails.ForeColor   = $Theme.TextPrimary
        $lblDetails.Dock        = [System.Windows.Forms.DockStyle]::Top
        $lblDetails.Height      = 90
        $lblDetails.Text        = "Üretici         : $vendorKey`r`n" +
                                  "Sürücü Sürümü   : $driverVer`r`n" +
                                  "Önerilen Yazılım: $recApp`r`n" +
                                  "Yazılım Durumu  : $(if ($isInstalled) { "Kurulu (v$instVer)" } else { "Kurulu Değil" })"
        $lblDetails.UseMnemonic = $false
        $card.Controls.Add($lblDetails)

        $btnRow = New-Object System.Windows.Forms.Panel
        $btnRow.Dock      = [System.Windows.Forms.DockStyle]::Bottom
        $btnRow.Height    = 34
        $card.Controls.Add($btnRow)

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

        # Event Handlers
        $capturedProf = $matchedProfile
        $capturedApp  = $recApp
        $maintQueue   = $Script:MaintMsgQueue
        $btnInstallGpu.Add_Click({
            Switch-AppTab -TabName "Maintenance"
            $rtbMaintLog.AppendText("[$((Get-Date).ToString('HH:mm:ss'))] GPU Destek Yazılımı Kurulumu: $capturedApp...`r`n")
            Start-ThreadJob -ScriptBlock {
                param($p, $app, $q)
                if ($p -and $p.WinGetId) {
                    & winget.exe install --id $p.WinGetId --silent --accept-package-agreements --accept-source-agreements
                    $q.Enqueue("[$((Get-Date).ToString('HH:mm:ss'))] [SUCCESS] $app kurulum süreci tamamlandı.")
                }
            } -ArgumentList $capturedProf, $capturedApp, $maintQueue | Out-Null
        })

        $btnExportDrv.Add_Click({
            $rtbMaintLog.AppendText("[$((Get-Date).ToString('HH:mm:ss'))] Sistem sürücüleri C:\PostInstall\Backups\Drivers klasörüne yedekleniyor...`r`n")
            Export-SystemDrivers | Out-Null
            $rtbMaintLog.AppendText("[$((Get-Date).ToString('HH:mm:ss'))] [SUCCESS] Sürücüler başarıyla yedeklendi.`r`n")
        })

        $flpGpuCards.Controls.Add($card)
    }
}
Update-GpuCenterCard
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

    $q = $Script:MaintMsgQueue
    $maintPath = $Script:MaintEnginePath
    $jobBlock = $ActionBlock
    Start-ThreadJob -ScriptBlock {
        param($b, $queue, $name, $path)
        try {
            if (Test-Path $path) { . $path }
            [void](& $b)
            $queue.Enqueue("[SUCCESS] $name başarıyla tamamlandı.")
        } catch {
            $queue.Enqueue("[ERROR] $name sırasında hata: $($_.Exception.Message)")
        }
    } -ArgumentList $jobBlock, $q, $ActionName, $maintPath | Out-Null
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
function Start-InstallationProcess {
    $Script:IsRunning = $true
    Set-WizardPage 4

    $selectedIds = @()
    for ($i = 0; $i -lt $clbSteps.Items.Count; $i++) {
        if ($clbSteps.GetItemChecked($i)) {
            $selectedIds += $Script:Steps[$i].Id
        }
    }

    $capturedEnginePath = $Script:EnginePath
    $capturedMsgQueue   = $Script:MsgQueue
    $capturedStatusQ    = $Script:StatusQueue
    $capturedStepIds    = $selectedIds

    $runspace = [System.Management.Automation.Runspaces.RunspaceFactory]::CreateRunspace()
    $runspace.ApartmentState = [System.Threading.ApartmentState]::STA
    $runspace.ThreadOptions  = [System.Management.Automation.Runspaces.PSThreadOptions]::ReuseThread
    $runspace.Open()

    $ps = [System.Management.Automation.PowerShell]::Create()
    $ps.Runspace = $runspace

    [void]$ps.AddScript({
        param($EnginePath, $MsgQueue, $StatusQueue, $SelectedIds)
        . $EnginePath
        $callback = {
            param($idx, $status)
            $StatusQueue.Enqueue([PSCustomObject]@{ Index = $idx; Status = $status })
        }
        $result = Start-PostInstallProcess -Queue $MsgQueue -StepStatusCallback $callback -SelectedStepIds $SelectedIds
        $finalStatus = switch ($result) {
            "REBOOT"    { "REBOOT_TRIGGERED" }
            "COMPLETED" { "COMPLETED"         }
            default     { "FAILED"            }
        }
        $StatusQueue.Enqueue([PSCustomObject]@{ Index = -1; Status = $finalStatus })
    })

    [void]$ps.AddParameter("EnginePath",  $capturedEnginePath)
    [void]$ps.AddParameter("MsgQueue",    $capturedMsgQueue)
    [void]$ps.AddParameter("StatusQueue", $capturedStatusQ)
    [void]$ps.AddParameter("SelectedIds", $capturedStepIds)

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

    # 2. Maintenance Log Queue
    $mMsg = ""
    while ($Script:MaintMsgQueue.TryDequeue([ref]$mMsg)) {
        if ([string]::IsNullOrEmpty($mMsg)) { continue }
        $rtbMaintLog.SelectionStart  = $rtbMaintLog.TextLength
        $rtbMaintLog.SelectionLength = 0
        $rtbMaintLog.SelectionColor = if ($mMsg -match "\[SUCCESS\]") { $Theme.AccentGreen }
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
                "Running" { $lvi.SubItems[1].Text = ">> Çalışıyor"; $lvi.ForeColor = $Theme.AccentCyan }
                "Success" { $lvi.SubItems[1].Text = "OK Başarılı";  $lvi.ForeColor = $Theme.AccentGreen }
                "Warning" { $lvi.SubItems[1].Text = "!! Uyarı";    $lvi.ForeColor = $Theme.AccentAmber }
                "Skipped" { $lvi.SubItems[1].Text = "-- Atlandı";   $lvi.ForeColor = $Theme.TextMuted }
                "Failed"  { $lvi.SubItems[1].Text = "X Hata";      $lvi.ForeColor = $Theme.AccentRed }
            }
        }

        if ($st -eq "COMPLETED") {
            $Script:IsRunning = $false
            try {
                $stObj = Get-EngineState
                $lblSummaryBody.Text = "Tüm adımlar başarıyla tamamlandı.`r`n`r`n" +
                    "• Toplam Adım    : $($stObj.TotalSteps)`r`n" +
                    "• Başarılı Adım  : $($stObj.CompletedSteps)`r`n" +
                    "• Uyarı / Hata   : $($stObj.FailedSteps)`r`n" +
                    "• Rapor Dosyası  : $($Script:Config.SummaryReport)"
            } catch {
                [System.Diagnostics.Trace]::WriteLine("Summary update warning: $($_.Exception.Message)")
            }
            Set-WizardPage 5
        }
    }
})

# Telemetry Sampling Timer (2000ms)
$telemetryTimer = New-Object System.Windows.Forms.Timer
$telemetryTimer.Interval = 2000

$telemetryTimer.Add_Tick({
    if ($Script:ActiveTab -ne "Monitoring") { return }

    try {
        if (Get-Command "Get-LiveTelemetrySample" -ErrorAction SilentlyContinue) {
            $s = Get-LiveTelemetrySample

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
        }
    } catch {
        [System.Diagnostics.Trace]::WriteLine("Telemetry tick warning: $($_.Exception.Message)")
    }
})

$btnRefreshMon.Add_Click({
    # Force single tick
    $telemetryTimer.Stop()
    $telemetryTimer.Start()
})
#endregion

#region --- Standard Button Handlers ---
$btnOpenLog.Add_Click({
    $logPath = $Script:Config.LogFile
    if (Test-Path $logPath) { Start-Process "notepad.exe" -ArgumentList "`"$logPath`"" }
})

$btnClose.Add_Click({
    if ($Script:IsRunning) {
        $r = [System.Windows.Forms.MessageBox]::Show("Kurulum süreci devam ediyor. Kapatmak istiyor musunuz?", "Uyarı", [System.Windows.Forms.MessageBoxButtons]::YesNo, [System.Windows.Forms.MessageBoxIcon]::Question)
        if ($r -eq [System.Windows.Forms.DialogResult]::No) { return }
    }
    $uiTimer.Stop()
    $telemetryTimer.Stop()
    $form.Close()
})

$form.Add_FormClosing({
    $uiTimer.Stop()
    $telemetryTimer.Stop()
    try {
        if ($Script:WorkerPS) { $Script:WorkerPS.Dispose() }
        if ($Script:WorkerRS) { $Script:WorkerRS.Close(); $Script:WorkerRS.Dispose() }
    } catch {
        [System.Diagnostics.Trace]::WriteLine("Form closing cleanup warning: $($_.Exception.Message)")
    }
})
#endregion

# Startup automation
if ($Resume -or $Auto) {
    $form.Add_Shown({
        Switch-AppTab -TabName "Wizard"
        Start-Sleep -Milliseconds 600
        for ($i = 0; $i -lt $clbSteps.Items.Count; $i++) { $clbSteps.SetItemChecked($i, $true) }
        Start-InstallationProcess
    })
} else {
    Switch-AppTab -TabName "Monitoring"
    Set-WizardPage 1
}

$uiTimer.Start()
$telemetryTimer.Start()
[System.Windows.Forms.Application]::Run($form)
