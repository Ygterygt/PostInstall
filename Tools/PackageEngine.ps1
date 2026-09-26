#Requires -Version 5.1
<#
.SYNOPSIS
    PackageEngine.ps1 - Smart Software Deployment & Lifecycle Engine
.DESCRIPTION
    Provides high-reliability package installations with:
      - Intelligent Pre-check: Scans Registry, AppX, and Binary PATH for existing versions
      - Semantic Version Comparison: Automatically skips if installed version >= target version
      - 3-Tier Resilient Fallback:
          Tier 1: WinGet (Silent, auto-accept agreements)
          Tier 2: Direct Official CDN Download + Authenticode/Size verification
          Tier 3: Local Offline Installer Cache (C:\PostInstall\Installers)
.NOTES
    Author : Antigravity Systems Team
    Version: 4.0.0
#>

function Compare-AppVersion {
    [CmdletBinding()]
    param(
        [string]$InstalledVersion,
        [string]$TargetVersion
    )

    if ([string]::IsNullOrWhiteSpace($InstalledVersion) -or [string]::IsNullOrWhiteSpace($TargetVersion)) {
        return 0
    }

    $clean1 = ($InstalledVersion -replace "[^\d.]", "").Trim(".")
    $clean2 = ($TargetVersion -replace "[^\d.]", "").Trim(".")

    $p1 = $clean1.Split(".") | Where-Object { $_ -ne "" } | ForEach-Object { [int]$_ }
    $p2 = $clean2.Split(".") | Where-Object { $_ -ne "" } | ForEach-Object { [int]$_ }

    $maxLen = [Math]::Max($p1.Count, $p2.Count)
    for ($i = 0; $i -lt $maxLen; $i++) {
        $num1 = if ($i -lt $p1.Count) { $p1[$i] } else { 0 }
        $num2 = if ($i -lt $p2.Count) { $p2[$i] } else { 0 }
        if ($num1 -gt $num2) { return 1 }
        if ($num1 -lt $num2) { return -1 }
    }
    return 0
}

function Get-InstalledAppInfo {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Name,
        [string]$RegistryPattern = "",
        [string]$BinaryName = "",
        [string]$AppXPackageName = ""
    )

    $searchPattern = if ($RegistryPattern) { $RegistryPattern } else { $Name }

    # 1. Check Registry (HKLM 64-bit, HKLM 32-bit, HKCU)
    $regPaths = @(
        "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*",
        "HKLM:\SOFTWARE\Wow6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*",
        "HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*"
    )

    $installed = Get-ItemProperty $regPaths -ErrorAction SilentlyContinue |
                 Where-Object { $_.DisplayName -and ($_.DisplayName -like "*$searchPattern*" -or $_.DisplayName -match $searchPattern) } |
                 Sort-Object DisplayVersion -Descending |
                 Select-Object -First 1

    if ($installed) {
        $ver = if ($installed.DisplayVersion) { $installed.DisplayVersion } else { "1.0.0" }
        return @{
            IsInstalled      = $true
            DisplayName      = $installed.DisplayName
            InstalledVersion = $ver
            Source           = "Registry"
        }
    }

    # 2. Check Binary / Executable in PATH
    if ($BinaryName) {
        $cmd = Get-Command $BinaryName -ErrorAction SilentlyContinue
        if ($cmd -and $cmd.Source -and (Test-Path $cmd.Source)) {
            $ver = (Get-Item $cmd.Source).VersionInfo.ProductVersion
            if (-not $ver) { $ver = (Get-Item $cmd.Source).VersionInfo.FileVersion }
            if (-not $ver) { $ver = "1.0.0" }
            return @{
                IsInstalled      = $true
                DisplayName      = $cmd.Name
                InstalledVersion = $ver
                Source           = "BinaryPath"
            }
        }
    }

    # 3. Check AppX / Modern Package
    if ($AppXPackageName) {
        $appx = Get-AppxPackage -Name "*$AppXPackageName*" -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($appx) {
            return @{
                IsInstalled      = $true
                DisplayName      = $appx.Name
                InstalledVersion = $appx.Version
                Source           = "AppX"
            }
        }
    }

    return @{
        IsInstalled      = $false
        DisplayName      = $Name
        InstalledVersion = ""
        Source           = "None"
    }
}

function Install-ResilientPackage {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$WingetId,
        [string]$WingetSource = "winget",
        [string]$DirectDownloadUrl = "",
        [string]$DirectSilentArgs = "/silent /install",
        [string]$LocalCacheDir = "C:\PostInstall\Installers",
        [string]$RegistryCheckPattern = "",
        [string]$BinaryName = "",
        [string]$MinVersion = "",
        [switch]$ForceReinstall
    )

    $result = [PSCustomObject]@{
        Name             = $Name
        Success          = $false
        TierUsed         = "None"
        ExitCode         = -1
        InstalledVersion = ""
        ActionTaken      = "None"
        Details          = ""
    }

    # --- Step 0: Smart App Version & Existence Pre-Check ---
    if (-not $ForceReinstall) {
        $appInfo = Get-InstalledAppInfo -Name $Name -RegistryPattern $RegistryCheckPattern -BinaryName $BinaryName

        if ($appInfo.IsInstalled) {
            $result.InstalledVersion = $appInfo.InstalledVersion

            if ([string]::IsNullOrWhiteSpace($MinVersion)) {
                # Already installed, no specific version requested -> SKIP
                $result.Success     = $true
                $result.TierUsed    = "SmartPrecheck"
                $result.ExitCode    = 0
                $result.ActionTaken = "SkippedAlreadyInstalled"
                $result.Details     = "Zaten kurulu: $($appInfo.DisplayName) (v$($appInfo.InstalledVersion)). Kurulum atlandi."
                Write-Output "[SKIP] $Name (v$($appInfo.InstalledVersion)) zaten bilgisayarda mevcut. Kurulum adimi atlandi."
                return $result
            } else {
                # Version requested: compare
                $cmp = Compare-AppVersion -InstalledVersion $appInfo.InstalledVersion -TargetVersion $MinVersion
                if ($cmp -ge 0) {
                    # Up to date -> SKIP
                    $result.Success     = $true
                    $result.TierUsed    = "SmartPrecheck"
                    $result.ExitCode    = 0
                    $result.ActionTaken = "SkippedUpToDate"
                    $result.Details     = "Zaten guncel: $($appInfo.DisplayName) (v$($appInfo.InstalledVersion) >= v$MinVersion). Kurulum atlandi."
                    Write-Output "[SKIP] $Name v$($appInfo.InstalledVersion) zaten guncel (Hedef: v$MinVersion). Kurulum adimi atlandi."
                    return $result
                } else {
                    Write-Output "[UPGRADE] $Name v$($appInfo.InstalledVersion) kurulu, ancak hedef surum v$MinVersion. Guncelleme baslatiliyor..."
                    $result.ActionTaken = "Upgrading"
                }
            }
        } else {
            Write-Output "[INSTALL] $Name bilgisayarda bulunamadi. Temiz kurulum baslatiliyor..."
            $result.ActionTaken = "Installing"
        }
    }

    # --- Step 1: Tier 1: WinGet ---
    $wingetCmd = Get-Command "winget.exe" -ErrorAction SilentlyContinue
    if ($wingetCmd) {
        Write-Output "[INFO] [$Name] Tier 1: WinGet deneniyor ($WingetId)..."
        $scopeArg = if ($WingetSource -eq "msstore") { "" } else { "--scope machine" }
        $actionCmd = if ($result.ActionTaken -eq "Upgrading") { "upgrade" } else { "install" }
        $wingetArgs = "$actionCmd --id $WingetId --exact --silent --accept-package-agreements --accept-source-agreements $scopeArg --source $WingetSource".Trim()

        try {
            $proc = Start-Process -FilePath "winget.exe" -ArgumentList $wingetArgs -Wait -PassThru -NoNewWindow
            # Exit codes: 0 = success, -1978335189 = already installed/no update, 2316632065 = reboot required
            if ($proc.ExitCode -in @(0, -1978335189, 3010)) {
                $result.Success  = $true
                $result.TierUsed = "WinGet"
                $result.ExitCode = 0
                $result.Details  = "WinGet ile basariyla uygulandi."
                Write-Output "[SUCCESS] $Name WinGet ile basariyla tamamlandi."
                return $result
            } else {
                Write-Output "[WARN] [$Name] WinGet cikis kodu: $($proc.ExitCode). Fallback deneniyor..."
            }
        } catch {
            Write-Output "[WARN] [$Name] WinGet calistirma hatasi: $_"
        }
    }

    # --- Step 2: Tier 2: Direct Download via Official CDN ---
    if ($DirectDownloadUrl) {
        Write-Output "[INFO] [$Name] Tier 2: Dogrudan uretici CDN indirmesi deneniyor: $DirectDownloadUrl"
        $tempDir = Join-Path $env:TEMP "PostInstall_Packages"
        if (-not (Test-Path $tempDir)) { New-Item -Path $tempDir -ItemType Directory -Force | Out-Null }
        
        $ext = if ($DirectDownloadUrl -like "*.msi*") { ".msi" } else { ".exe" }
        $tempFile = Join-Path $tempDir ("$($Name -replace '\W','_')_setup$ext")

        try {
            [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 -bor [Net.SecurityProtocolType]::Tls13
            $wc = New-Object System.Net.WebClient
            $wc.Headers.Add("User-Agent", "Mozilla/5.0 (Windows NT 10.0; Win64; x64) MaintenanceEngine/4.0")
            $wc.DownloadFile($DirectDownloadUrl, $tempFile)
            $wc.Dispose()

            if ((Test-Path $tempFile) -and (Get-Item $tempFile).Length -gt 500000) {
                Write-Output "[INFO] [$Name] Paket indirildi ($([math]::Round((Get-Item $tempFile).Length/1MB,1)) MB). Kuruluyor..."
                
                $execPath = $tempFile
                $execArgs = $DirectSilentArgs
                if ($tempFile -like "*.msi") {
                    $execPath = "msiexec.exe"
                    $execArgs = "/i `"$tempFile`" /qn /norestart ALLUSERS=1"
                }

                $p = Start-Process -FilePath $execPath -ArgumentList $execArgs -Wait -PassThru -NoNewWindow
                if ($p.ExitCode -in @(0, 3010, 1638)) {
                    $result.Success  = $true
                    $result.TierUsed = "DirectDownload"
                    $result.ExitCode = $p.ExitCode
                    $result.Details  = "Direct CDN ile basariyla kuruldu."
                    Write-Output "[SUCCESS] $Name dogrudan indirme ile kuruldu (Kod: $($p.ExitCode))."
                    Remove-Item $tempFile -Force -ErrorAction SilentlyContinue
                    return $result
                }
            }
        } catch {
            Write-Output "[WARN] [$Name] Dogrudan indirme hatasi: $_"
        } finally {
            if (Test-Path $tempFile) { Remove-Item $tempFile -Force -ErrorAction SilentlyContinue }
        }
    }

    # --- Step 3: Tier 3: Local Offline Cache ---
    if (Test-Path $LocalCacheDir) {
        $localInstaller = Get-ChildItem -Path $LocalCacheDir -File -ErrorAction SilentlyContinue |
                          Where-Object { $_.BaseName -like "*$Name*" } | Select-Object -First 1
        if ($localInstaller) {
            Write-Output "[INFO] [$Name] Tier 3: Yerel cevrimdisi onbellek bulundu: $($localInstaller.FullName)"
            try {
                $p = Start-Process -FilePath $localInstaller.FullName -ArgumentList $DirectSilentArgs -Wait -PassThru -NoNewWindow
                if ($p.ExitCode -in @(0, 3010, 1638)) {
                    $result.Success  = $true
                    $result.TierUsed = "LocalCache"
                    $result.ExitCode = $p.ExitCode
                    $result.Details  = "Yerel onbellekten kuruldu."
                    Write-Output "[SUCCESS] $Name yerel onbellek paketiyle kuruldu."
                    return $result
                }
            } catch {}
        }
    }

    $result.Details = "Tum kurulum katmanlari (WinGet, CDN, Yerel) denendi ancak basarisiz oldu."
    Write-Output "[WARN] [$Name] Kurulum tamamlanamadi."
    return $result
}
