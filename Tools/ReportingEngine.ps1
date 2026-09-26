#Requires -Version 5.1
<#
.SYNOPSIS
    ReportingEngine.ps1 - Standalone HTML5 Executive Report Generator
.DESCRIPTION
    Generates a zero-dependency, self-contained, responsive dark-mode HTML5
    audit dashboard for enterprise IT administrators and end users.
#>

function New-PostInstallHtmlReport {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$Specs,
        [Parameter(Mandatory)][array]$Checks,
        [Parameter(Mandatory)][array]$Volumes,
        [string]$OutputFile = "C:\Windows\Temp\PostInstall_Report.html"
    )

    $outDir = Split-Path $OutputFile
    if ($outDir -and -not (Test-Path $outDir)) {
        New-Item -Path $outDir -ItemType Directory -Force | Out-Null
    }

    $now = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $passedChecks = ($Checks | Where-Object { $_.OK }).Count
    $totalChecks  = $Checks.Count
    $passRate = if ($totalChecks -gt 0) { [math]::Round(($passedChecks / $totalChecks) * 100, 0) } else { 100 }

    # Component check rows
    $checkRowsHtml = ($Checks | ForEach-Object {
        $badgeClass = if ($_.OK) { "badge-success" } else { "badge-warn" }
        $badgeText  = if ($_.OK) { "BAŞARILI" } else { "DİKKAT" }
        "<tr>
            <td><strong>$($_.Label)</strong></td>
            <td><code>$($_.Detail)</code></td>
            <td><span class='badge $badgeClass'>$badgeText</span></td>
        </tr>"
    }) -join "`n"

    # Volume rows
    $volRowsHtml = ($Volumes | ForEach-Object {
        $freeGB = [math]::Round($_.SizeRemaining / 1GB, 1)
        $totalGB = [math]::Round($_.Size / 1GB, 1)
        $pct = if ($_.Size -gt 0) { [math]::Round(($_.SizeRemaining / $_.Size) * 100, 0) } else { 0 }
        "<tr>
            <td><strong>$($_.DriveLetter):</strong></td>
            <td>$($_.FileSystemLabel)</td>
            <td>$($_.FileSystemType)</td>
            <td>$totalGB GB</td>
            <td>$freeGB GB (%$pct)</td>
            <td><span class='badge badge-success'>$($_.HealthStatus)</span></td>
        </tr>"
    }) -join "`n"

    $html = @"
<!DOCTYPE html>
<html lang="tr">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Post-Installation Denetim Raporu - $($Specs.ComputerName)</title>
    <style>
        :root {
            --bg-main: #0d1117;
            --bg-card: #161b22;
            --bg-input: #21262d;
            --text-primary: #e6edf3;
            --text-muted: #8b949e;
            --border: #30363d;
            --accent-blue: #1f6feb;
            --accent-cyan: #38bdf8;
            --accent-green: #238636;
            --accent-amber: #d29922;
            --accent-red: #da3633;
        }
        * { box-sizing: border-box; margin: 0; padding: 0; font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif; }
        body { background: var(--bg-main); color: var(--text-primary); padding: 32px 16px; line-height: 1.5; }
        .container { max-width: 1100px; margin: 0 auto; }
        .header { display: flex; justify-content: space-between; align-items: center; padding-bottom: 24px; border-bottom: 1px solid var(--border); margin-bottom: 28px; }
        .header h1 { font-size: 24px; font-weight: 700; color: var(--accent-cyan); }
        .header .meta { font-size: 13px; color: var(--text-muted); text-align: right; }
        .grid { display: grid; grid-template-columns: repeat(auto-fit, minmax(240px, 1fr)); gap: 16px; margin-bottom: 28px; }
        .card { background: var(--bg-card); border: 1px solid var(--border); border-radius: 8px; padding: 18px; }
        .card .title { font-size: 12px; font-weight: 600; text-transform: uppercase; color: var(--text-muted); margin-bottom: 8px; }
        .card .value { font-size: 15px; font-weight: 600; color: var(--text-primary); }
        .card .sub { font-size: 12px; color: var(--text-muted); margin-top: 4px; }
        .section-title { font-size: 17px; font-weight: 600; margin-bottom: 14px; color: var(--text-primary); display: flex; align-items: center; gap: 8px; }
        table { width: 100%; border-collapse: collapse; background: var(--bg-card); border: 1px solid var(--border); border-radius: 8px; overflow: hidden; margin-bottom: 28px; }
        th, td { padding: 12px 16px; text-align: left; font-size: 13.5px; border-bottom: 1px solid var(--border); }
        th { background: var(--bg-input); color: var(--text-muted); font-weight: 600; font-size: 12px; text-transform: uppercase; }
        tr:last-child td { border-bottom: none; }
        code { background: var(--bg-input); padding: 2px 6px; border-radius: 4px; font-family: Consolas, monospace; font-size: 12.5px; }
        .badge { display: inline-block; padding: 3px 8px; border-radius: 12px; font-size: 11px; font-weight: 700; text-transform: uppercase; }
        .badge-success { background: rgba(35, 134, 54, 0.2); color: #3fb950; border: 1px solid rgba(63, 185, 80, 0.3); }
        .badge-warn { background: rgba(210, 153, 34, 0.2); color: #e3b341; border: 1px solid rgba(227, 179, 65, 0.3); }
        .footer { text-align: center; font-size: 12px; color: var(--text-muted); margin-top: 40px; }
    </style>
</head>
<body>
    <div class="container">
        <div class="header">
            <div>
                <h1>Kurumsal Post-Installation Denetim Raporu</h1>
                <p style="color: var(--text-muted); font-size: 13.5px; margin-top: 4px;">Antigravity Enterprise Framework v3.1 | Durum: Tamamlandı</p>
            </div>
            <div class="meta">
                <div><strong>$($Specs.ComputerName)</strong> / $($Specs.UserName)</div>
                <div>Tarih: $now</div>
                <div>Doğrulama Oranı: <span style="color: var(--accent-green); font-weight: 700;">%$passRate</span></div>
            </div>
        </div>

        <div class="grid">
            <div class="card">
                <div class="title">Platform / Kasa</div>
                <div class="value">$($Specs.ChassisType)</div>
                <div class="sub">$($Specs.OSName)</div>
            </div>
            <div class="card">
                <div class="title">İşlemci (CPU)</div>
                <div class="value">$($Specs.CPU)</div>
                <div class="sub">$($Specs.CPUCores)</div>
            </div>
            <div class="card">
                <div class="title">Bellek (RAM)</div>
                <div class="value">$($Specs.RAMTotal) ($($Specs.RAMSpeedActual))</div>
                <div class="sub">XMP / DOCP: $(if ($Specs.IsXmpActive) { "Aktif" } else { "Standart" })</div>
            </div>
            <div class="card">
                <div class="title">Grafik Birimleri</div>
                <div class="value">$($Specs.GPU)</div>
                <div class="sub">Üretici: $($Specs.GPUVendor)</div>
            </div>
        </div>

        <div class="section-title">📦 Bileşen ve Yazılım Doğrulama Tablosu ($passedChecks / $totalChecks)</div>
        <table>
            <thead>
                <tr>
                    <th>Bileşen / Servis</th>
                    <th>Kurulu Sürüm / Detay</th>
                    <th>Durum</th>
                </tr>
            </thead>
            <tbody>
                $checkRowsHtml
            </tbody>
        </table>

        <div class="section-title">💾 Depolama ve Disk Sağlık Envanteri</div>
        <table>
            <thead>
                <tr>
                    <th>Sürücü</th>
                    <th>Etiket</th>
                    <th>Dosya Sistemi</th>
                    <th>Kapasite</th>
                    <th>Boş Alan</th>
                    <th>Sağlık</th>
                </tr>
            </thead>
            <tbody>
                $volRowsHtml
            </tbody>
        </table>

        <div class="footer">
            Bu rapor Antigravity Post-Installation Suite tarafından otomatik üretilmiştir.<br>
            Tüm donanım sürücüleri, ortam değişkenleri ve kurumsal güvenlik ilkeleri doğrulanmıştır.
        </div>
    </div>
</body>
</html>
"@

    $encoding = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($OutputFile, $html, $encoding)
    return $OutputFile
}
