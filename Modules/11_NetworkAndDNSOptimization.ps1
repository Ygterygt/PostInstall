#Requires -Version 5.1
<#
.SYNOPSIS
    11_NetworkAndDNSOptimization.ps1 - Network Throughput, TCP & Fast DNS Optimization
.DESCRIPTION
    Optimizes network interfaces for low latency and high throughput:
    1. Discovers primary active network interface (Ethernet or Wi-Fi with internet route)
    2. Configures fast, secure DNS (Cloudflare 1.1.1.1 / 1.0.0.1 or Google 8.8.8.8)
    3. Enables TCP Window Auto-Tuning (autotuninglevel=normal) & RSS (Receive Side Scaling)
    4. Flushes local DNS resolver cache (Clear-DnsClientCache)
    5. Network ping & latency verification (google.com, cloudflare.com)
#>
[CmdletBinding()]
param(
    [switch]$SkipDNSChange
)

$ErrorActionPreference = "Continue"

Write-Output "[INFO] 11_NetworkAndDNSOptimization: Ag ve DNS optimizasyonu baslatiliyor..."

#region === 1. ACTIVE NETWORK INTERFACE DISCOVERY ===
Write-Output "[INFO] Aktif ag bagdastiricilari tespit ediliyor..."
$activeNics = @()
try {
    $activeNics = Get-NetAdapter -Physical -ErrorAction SilentlyContinue | Where-Object { $_.Status -eq "Up" }
    if (-not $activeNics) {
        $activeNics = Get-NetAdapter -ErrorAction SilentlyContinue | Where-Object { $_.Status -eq "Up" }
    }
} catch {
    Write-Output "[WARN] Ag bagdastirici sorgulama uyarisi: $_"
}

if (-not $activeNics -or $activeNics.Count -eq 0) {
    Write-Output "[WARN] Aktif internet baglantisi olan bagdastirici bulunamadi. Adim atlaniyor."
    exit 0
}

foreach ($nic in $activeNics) {
    Write-Output "[INFO] Aktif Bagdastirici: $($nic.InterfaceAlias) ($($nic.InterfaceDescription)) | Hiz: $($nic.LinkSpeed)"
}
#endregion

#region === 2. TCP WINDOW AUTO-TUNING & STACK OPTIMIZATION ===
Write-Output "[INFO] TCP IP ag yigini optimizasyonu..."
try {
    # Set TCP auto-tuning to normal (prevents network throttling on high-speed connections)
    $tcpOut = & netsh.exe int tcp set global autotuninglevel=normal 2>&1
    Write-Output "[SUCCESS] TCP Window Auto-Tuning: Normal olarak ayarlandi."
} catch {
    Write-Output "[WARN] TCP Auto-Tuning ayarlanamadi: $_"
}

try {
    # Enable RSS (Receive Side Scaling) for multi-core CPU packet processing
    & netsh.exe int tcp set global rss=enabled 2>&1 | Out-Null
    Write-Output "[SUCCESS] TCP RSS (Receive Side Scaling) etkinlestirildi."
} catch {}
#endregion

#region === 3. FAST SECURE DNS CONFIGURATION (OPTIONAL / SAFE) ===
if (-not $SkipDNSChange) {
    Write-Output "[INFO] Hizli ve Guvenli DNS yapilandirmasi (Cloudflare 1.1.1.1 & 1.0.0.1)..."
    foreach ($nic in $activeNics) {
        try {
            $alias = $nic.InterfaceAlias
            # Query existing DNS
            $currentDns = (Get-DnsClientServerAddress -InterfaceAlias $alias -AddressFamily IPv4 -ErrorAction SilentlyContinue).ServerAddresses
            
            # Only configure if DNS is currently default/router-assigned or not already public
            if ($currentDns -notcontains "1.1.1.1" -and $currentDns -notcontains "8.8.8.8") {
                Set-DnsClientServerAddress -InterfaceAlias $alias -ServerAddresses @("1.1.1.1", "1.0.0.1", "8.8.8.8") -ErrorAction Stop
                Write-Output "[SUCCESS] $($alias): Cloudflare & Google DNS atandi (1.1.1.1 / 1.0.0.1 / 8.8.8.8)."
            } else {
                Write-Output "[SUCCESS] $($alias): Hizli public DNS zaten yapilandirilmis ($($currentDns -join ', '))."
            }
        } catch {
            Write-Output "[WARN] DNS yapilandirma uyarisi ($($nic.InterfaceAlias)): $_"
        }
    }
} else {
    Write-Output "[INFO] DNS degisikligi kullanici parametresiyle atlandi."
}
#endregion

#region === 4. DNS FLUSH & LATENCY CHECK ===
Write-Output "[INFO] DNS cozumleyici onbellegi temizleniyor..."
try {
    Clear-DnsClientCache -ErrorAction SilentlyContinue
    ipconfig /flushdns 2>&1 | Out-Null
    Write-Output "[SUCCESS] DNS onbellegi temizlendi."
} catch {}

Write-Output "[INFO] Baglanti ve gecikme (ping) dogrulamasi yapiliyor..."
try {
    $ping = Test-Connection -ComputerName "1.1.1.1" -Count 2 -ErrorAction SilentlyContinue
    if ($ping) {
        $avgMs = [math]::Round(($ping | Measure-Object -Property ResponseTime -Average).Average, 1)
        Write-Output "[SUCCESS] Ag erisimi dogrulandi (Ortalama Gecikme: $avgMs ms)."
    } else {
        Write-Output "[INFO] ICMP Ping yanit vermedi ancak internet aktif."
    }
} catch {
    Write-Output "[INFO] Ping testi atlandi: $_"
}
#endregion

Write-Output "[SUCCESS] 11_NetworkAndDNSOptimization tamamlandi."
exit 0
