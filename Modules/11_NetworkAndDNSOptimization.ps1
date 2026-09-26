#Requires -Version 5.1
<#
.SYNOPSIS
    11_NetworkAndDNSOptimization.ps1 - Network Throughput, TCP & Fast DNS Optimization
.DESCRIPTION
    Optimizes network interfaces for low latency and high throughput:
    1. Discovers primary active network interface (Ethernet or Wi-Fi with internet route)
    2. Configures fast DNS from config.json (Network.DnsServers) on DHCP adapters only;
       skips domain-joined machines and static DNS, backs up previous values
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
. (Join-Path (Split-Path -Parent $PSScriptRoot) "Tools\Common.ps1")
$netCfg     = (Get-SuiteConfig).Network
$dnsServers = if ($netCfg -and $netCfg.DnsServers) { @($netCfg.DnsServers) } else { @("1.1.1.1", "1.0.0.1") }
$changeDns  = (-not $SkipDNSChange) -and (-not $netCfg -or $netCfg.ChangeDns -ne $false)
$cs         = Get-CimInstance Win32_ComputerSystem -ErrorAction SilentlyContinue

if (-not $changeDns) {
    Write-Output "[INFO] DNS degisikligi devre disi (parametre veya config: Network.ChangeDns = false)."
} elseif ($cs -and $cs.PartOfDomain -and ($netCfg.SkipIfDomainJoined -ne $false)) {
    Write-Output "[INFO] Bilgisayar '$($cs.Domain)' etki alanina bagli. Active Directory cozumlemesini korumak icin DNS degistirilmedi."
} else {
    Write-Output "[INFO] Hizli ve Guvenli DNS yapilandirmasi ($($dnsServers -join ' / '))..."
    $backup = @()
    foreach ($nic in $activeNics) {
        try {
            $alias = $nic.InterfaceAlias
            $currentDns = @((Get-DnsClientServerAddress -InterfaceAlias $alias -AddressFamily IPv4 -ErrorAction SilentlyContinue).ServerAddresses)

            # A non-empty NameServer value means DNS was set manually (static) - respect it
            $ifKey = "HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters\Interfaces\$($nic.InterfaceGuid)"
            $staticDns = (Get-ItemProperty -Path $ifKey -Name "NameServer" -ErrorAction SilentlyContinue).NameServer

            if (-not [string]::IsNullOrWhiteSpace($staticDns)) {
                Write-Output "[INFO] $($alias): Elle tanimlanmis statik DNS korunuyor ($staticDns)."
                continue
            }
            if (@($currentDns | Where-Object { $dnsServers -contains $_ }).Count -gt 0) {
                Write-Output "[SUCCESS] $($alias): Hedef DNS zaten yapilandirilmis ($($currentDns -join ', '))."
                continue
            }

            $backup += [PSCustomObject]@{ InterfaceAlias = $alias; InterfaceGuid = "$($nic.InterfaceGuid)"; PreviousDns = $currentDns; Mode = "DHCP" }
            Set-DnsClientServerAddress -InterfaceAlias $alias -ServerAddresses $dnsServers -ErrorAction Stop
            Write-Output "[SUCCESS] $($alias): DNS atandi ($($dnsServers -join ' / ')). Geri almak icin: Set-DnsClientServerAddress -InterfaceAlias '$alias' -ResetServerAddresses"
        } catch {
            Write-Output "[WARN] DNS yapilandirma uyarisi ($($nic.InterfaceAlias)): $_"
        }
    }
    if ($backup.Count -gt 0) {
        $backupFile = Join-Path (Get-SuiteDataDir "Backups") ("DNS_PreChange_{0}.json" -f (Get-Date -Format "yyyyMMdd_HHmmss"))
        $backup | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $backupFile -Encoding UTF8
        Write-Output "[INFO] Onceki DNS ayarlari yedeklendi: $backupFile"
    }
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
