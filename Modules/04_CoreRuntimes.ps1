#Requires -Version 5.1
<#
.SYNOPSIS
    04_CoreRuntimes.ps1 - Universal Runtimes (Visual C++, WebView2, DirectX, .NET)
.DESCRIPTION
    Installs and verifies essential Windows runtime environments:
    1. Microsoft Visual C++ Redistributable All-In-One (2015-2022, 2013, 2012 x86 & x64)
    2. Microsoft Edge WebView2 Evergreen Runtime
    3. DirectX End-User Runtimes (Legacy DX9/DX10/DX11 API verification)
    4. Modern .NET Desktop Runtime & .NET Framework 4.8+ detection
#>
[CmdletBinding()]
param()

$ErrorActionPreference = "Continue"

#region --- Helper: Test if VC++ already installed ---
function Test-VCRedistInstalled {
    param(
        [string]$Architecture,  # "x64" or "x86"
        [string]$YearPattern = "2015-20"
    )

    $regPaths = @(
        "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*",
        "HKLM:\SOFTWARE\Wow6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*"
    )

    $found = Get-ItemProperty $regPaths -ErrorAction SilentlyContinue |
             Where-Object { $_.DisplayName -like "Microsoft Visual C++ *$YearPattern*" -and
                            $_.DisplayName -like "*$Architecture*" } |
             Select-Object -First 1

    if ($found) {
        return $found.DisplayVersion
    }
    return $null
}
#endregion

#region --- Helper: Download with retry using BITS or WebClient ---
function Get-FileWithRetry {
    param(
        [string]$Uri,
        [string]$Destination,
        [int]$MaxRetries = 3,
        [string]$Description = "Dosya"
    )

    for ($attempt = 1; $attempt -le $MaxRetries; $attempt++) {
        Write-Output "[INFO] $Description indiriliyor (Deneme $attempt / $MaxRetries)..."
        try {
            $bitsJob = Start-BitsTransfer -Source $Uri -Destination $Destination -DisplayName $Description -ErrorAction Stop
            if ($bitsJob.JobState -eq "Transferred") {
                Complete-BitsTransfer -BitsJob $bitsJob
            }
        } catch {
            Write-Output "[WARN] BITS gecilemedi: $_. WebClient deneniyor..."
            try {
                $wc = New-Object System.Net.WebClient
                $wc.Headers.Add("User-Agent", "Mozilla/5.0 (Windows NT 10.0; Win64; x64) PostInstall/3.0")
                [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 -bor [Net.SecurityProtocolType]::Tls13
                $wc.DownloadFile($Uri, $Destination)
                $wc.Dispose()
            } catch {
                Write-Output "[WARN] Deneme $attempt basarisiz: $_"
                if (Test-Path $Destination) { Remove-Item $Destination -Force -ErrorAction SilentlyContinue }
                if ($attempt -lt $MaxRetries) { Start-Sleep -Seconds (2 * $attempt) }
                continue
            }
        }

        if (Test-Path $Destination) {
            $fileLen = (Get-Item $Destination).Length
            if ($fileLen -lt 512000) {
                Write-Output "[WARN] $Description boyutu beklenenden cok kucuk ($fileLen bayt). Tekrar denenecek."
                Remove-Item $Destination -Force -ErrorAction SilentlyContinue
                continue
            }

            # Never execute a downloaded runtime without a valid Microsoft Authenticode signature
            $sig = $null
            try { $sig = Get-AuthenticodeSignature -FilePath $Destination -ErrorAction Stop } catch {}
            if ($sig -and $sig.Status -eq "Valid" -and $sig.SignerCertificate.Subject -like "*Microsoft*") {
                Write-Output "[SUCCESS] Dijital Imza Gecerli (Authenticode): $($sig.SignerCertificate.Subject)"
            } else {
                $sigStatus = if ($sig) { $sig.Status } else { "Okunamadi" }
                Write-Output "[ERROR] $Description dijital imzasi dogrulanamadi ($sigStatus). Dosya silindi, calistirilmayacak."
                Remove-Item $Destination -Force -ErrorAction SilentlyContinue
                return $false
            }

            $sizeMB = [math]::Round($fileLen / 1MB, 1)
            Write-Output "[SUCCESS] $Description basariyla dogrulandi ve hazirlandi ($sizeMB MB)."
            return $true
        }
    }
    return $false
}
#endregion

#region --- Helper: Install VC++ runtime ---
function Install-VCRedist {
    param(
        [string]$Architecture,
        [string]$YearLabel,
        [string]$YearPattern,
        [string]$DownloadUrl,
        [string]$SilentArgs,
        [string]$TempDir
    )

    Write-Output "[INFO] === Visual C++ $YearLabel ($Architecture) ==="

    $installedVer = Test-VCRedistInstalled -Architecture $Architecture -YearPattern $YearPattern
    if ($installedVer) {
        Write-Output "[SUCCESS] VC++ $YearLabel ($Architecture) zaten kurulu. Surum: $installedVer - Atlaniyor."
        return 0
    }

    $destFile = Join-Path $TempDir "vc_redist.$YearLabel.$Architecture.exe"

    if (-not (Get-FileWithRetry -Uri $DownloadUrl -Destination $destFile -Description "VC++ Redist $YearLabel $Architecture")) {
        Write-Output "[ERROR] VC++ $YearLabel $Architecture indirilemedi."
        return -1
    }

    Write-Output "[INFO] VC++ $YearLabel $Architecture sessiz kurulum baslatiliyor..."
    try {
        $proc = Start-Process -FilePath $destFile `
                              -ArgumentList $SilentArgs `
                              -Wait -PassThru -NoNewWindow
        $code = $proc.ExitCode
        Write-Output "[INFO] VC++ $YearLabel $Architecture cikis kodu: $code"

        switch ($code) {
            0    { Write-Output "[SUCCESS] VC++ $YearLabel $Architecture basariyla kuruldu." }
            1638 { Write-Output "[SUCCESS] VC++ $YearLabel $Architecture zaten kurulu (MSI kodu 1638)." }
            3010 { Write-Output "[WARN] VC++ $YearLabel $Architecture kuruldu - YENIDEN BASLAMA gerekiyor." }
            1602 { Write-Output "[WARN] VC++ $YearLabel $Architecture kullanici tarafindan iptal edildi." }
            default { Write-Output "[WARN] VC++ $YearLabel $Architecture cikis kodu: $code" }
        }
        return $code
    } catch {
        Write-Output "[ERROR] VC++ $YearLabel $Architecture kurulum surec hatasi: $_"
        return -999
    } finally {
        if (Test-Path $destFile) { Remove-Item $destFile -Force -ErrorAction SilentlyContinue }
    }
}
#endregion

Write-Output "[INFO] 04_CoreRuntimes: Evrensel calisma zamanlari kontrol ve kurulum baslatiliyor..."

$tempDir = "C:\Windows\Temp\PostInstall_Runtimes"
if (-not (Test-Path $tempDir)) { New-Item -Path $tempDir -ItemType Directory -Force | Out-Null }

$rebootRequired = $false

# 1. Visual C++ 2015-2022 (x64 & x86)
$codeX64 = Install-VCRedist -Architecture "x64" -YearLabel "2015-2022" -YearPattern "2015-20" `
    -DownloadUrl "https://aka.ms/vs/17/release/vc_redist.x64.exe" -SilentArgs "/install /quiet /norestart" -TempDir $tempDir
if ($codeX64 -eq 3010) { $rebootRequired = $true }

$codeX86 = Install-VCRedist -Architecture "x86" -YearLabel "2015-2022" -YearPattern "2015-20" `
    -DownloadUrl "https://aka.ms/vs/17/release/vc_redist.x86.exe" -SilentArgs "/install /quiet /norestart" -TempDir $tempDir
if ($codeX86 -eq 3010) { $rebootRequired = $true }

# 2. Visual C++ 2013 (x64 & x86)
$code2013x64 = Install-VCRedist -Architecture "x64" -YearLabel "2013" -YearPattern "2013" `
    -DownloadUrl "https://download.microsoft.com/download/2/E/6/2E61CFA4-993B-4DD4-91DA-3737CD5CD6E3/vcredist_x64.exe" -SilentArgs "/install /quiet /norestart" -TempDir $tempDir
if ($code2013x64 -eq 3010) { $rebootRequired = $true }

$code2013x86 = Install-VCRedist -Architecture "x86" -YearLabel "2013" -YearPattern "2013" `
    -DownloadUrl "https://download.microsoft.com/download/2/E/6/2E61CFA4-993B-4DD4-91DA-3737CD5CD6E3/vcredist_x86.exe" -SilentArgs "/install /quiet /norestart" -TempDir $tempDir
if ($code2013x86 -eq 3010) { $rebootRequired = $true }

# 3. Visual C++ 2012 (x64 & x86)
$code2012x64 = Install-VCRedist -Architecture "x64" -YearLabel "2012" -YearPattern "2012" `
    -DownloadUrl "https://download.microsoft.com/download/1/6/B/16B06F60-3B20-4FF2-B699-5E9B7962F921/vcredist_x64.exe" -SilentArgs "/install /quiet /norestart" -TempDir $tempDir
if ($code2012x64 -eq 3010) { $rebootRequired = $true }

$code2012x86 = Install-VCRedist -Architecture "x86" -YearLabel "2012" -YearPattern "2012" `
    -DownloadUrl "https://download.microsoft.com/download/1/6/B/16B06F60-3B20-4FF2-B699-5E9B7962F921/vcredist_x86.exe" -SilentArgs "/install /quiet /norestart" -TempDir $tempDir
if ($code2012x86 -eq 3010) { $rebootRequired = $true }

# 4. Microsoft Edge WebView2 Evergreen Runtime Check & Install
Write-Output "[INFO] === Microsoft Edge WebView2 Evergreen Runtime ==="
$wv2Installed = $false
try {
    $wv2Reg = Get-ItemProperty "HKLM:\SOFTWARE\WOW6432Node\Microsoft\EdgeUpdate\Clients\{F3017226-F501-47EC-9A48-C250257F37C0}",
                               "HKLM:\SOFTWARE\Microsoft\EdgeUpdate\Clients\{F3017226-F501-47EC-9A48-C250257F37C0}" -ErrorAction SilentlyContinue |
              Where-Object { $_.pv } | Select-Object -First 1
    if ($wv2Reg) {
        $wv2Installed = $true
        Write-Output "[SUCCESS] Microsoft Edge WebView2 kurulu. Surum: $($wv2Reg.pv)"
    }
} catch {}

if (-not $wv2Installed) {
    Write-Output "[INFO] WebView2 Runtime eksik. Resmi Microsoft bootstrapper ile kuruluyor..."
    $wv2Bootstrapper = Join-Path $tempDir "MicrosoftEdgeWebview2Setup.exe"
    if (Get-FileWithRetry -Uri "https://go.microsoft.com/fwlink/p/?LinkId=2124703" -Destination $wv2Bootstrapper -Description "Edge WebView2 Bootstrapper") {
        try {
            $p = Start-Process -FilePath $wv2Bootstrapper -ArgumentList "/silent /install" -Wait -PassThru -NoNewWindow
            if ($p.ExitCode -eq 0) {
                Write-Output "[SUCCESS] Microsoft Edge WebView2 basariyla kuruldu."
            } else {
                Write-Output "[WARN] WebView2 kurulum cikis kodu: $($p.ExitCode)"
            }
        } catch {
            Write-Output "[WARN] WebView2 kurulum hatasi: $_"
        } finally {
            if (Test-Path $wv2Bootstrapper) { Remove-Item $wv2Bootstrapper -Force -ErrorAction SilentlyContinue }
        }
    }
}

# 4. DirectX Legacy End-User Runtimes Check (DX9/DX10/DX11 d3dx9, xinput1_3)
Write-Output "[INFO] === DirectX Legacy Calisma Zamani Taramasi ==="
$dxDll1 = Join-Path $env:SystemRoot "System32\d3dx9_43.dll"
$dxDll2 = Join-Path $env:SystemRoot "SysWOW64\d3dx9_43.dll"
if ((Test-Path $dxDll1) -or (Test-Path $dxDll2)) {
    Write-Output "[SUCCESS] DirectX End-User Runtimes (d3dx9_43.dll) sistemde mevcut."
} else {
    Write-Output "[NOTE] DirectX Legacy Runtimes bulunamadi. Eski 3D oyunlar ve tasarim araclari icin DirectX End-User Runtime gerekebilir."
}

# 5. .NET Framework & .NET Desktop Runtimes
Write-Output "[INFO] === .NET Framework & Modern .NET Desktop Runtime ==="
try {
    $ndpKey = Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\NET Framework Setup\NDP\v4\Full" -ErrorAction Stop
    $release = $ndpKey.Release
    $friendlyVer = switch ($release) {
        { $_ -ge 533320 } { ".NET Framework 4.8.1+" }
        { $_ -ge 528040 } { ".NET Framework 4.8"    }
        { $_ -ge 461808 } { ".NET Framework 4.7.2"  }
        default           { ".NET Framework 4.x ($release)" }
    }
    Write-Output "[SUCCESS] $friendlyVer kurulu (Release: $release)"
} catch {
    Write-Output "[WARN] .NET Framework bilgisi okunamadi: $_"
}

# Modern .NET Desktop Runtime check
try {
    $dotnetExe = Get-Command "dotnet" -ErrorAction SilentlyContinue
    if ($dotnetExe) {
        $runtimes = & dotnet --list-runtimes 2>&1
        $desktopRuntimes = $runtimes | Where-Object { $_ -like "*Microsoft.WindowsDesktop.App*" }
        if ($desktopRuntimes) {
            Write-Output "[SUCCESS] Modern .NET Desktop Runtime: $($desktopRuntimes -join ', ')"
        } else {
            Write-Output "[INFO] .NET SDK/CLI mevcut ancak WindowsDesktop.App calisma zamani yok."
        }
    } else {
        Write-Output "[INFO] dotnet CLI kurulu degil (Gelistirici araclarinda opsiyonel temin edilebilir)."
    }
} catch {}

# Cleanup
try { Remove-Item $tempDir -Recurse -Force -ErrorAction SilentlyContinue } catch {}

if ($rebootRequired) {
    Write-Output "[WARN] Kurulum tamamlandi ancak yeniden baslama gerekiyor."
    exit 3010
}

Write-Output "[SUCCESS] 04_CoreRuntimes tamamlandi."
exit 0
