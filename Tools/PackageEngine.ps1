#Requires -Version 5.1
<#
.SYNOPSIS
    PackageEngine.ps1 - Smart Software Deployment & Lifecycle Engine
.DESCRIPTION
    Provides high-reliability package installations with:
      - Intelligent Pre-check: WinGet (exact id), Registry (word-boundary match), AppX and Binary PATH
      - Semantic Version Comparison: Automatically skips if installed version >= target version
      - 3-Tier Resilient Fallback:
          Tier 1: WinGet (Silent, auto-accept agreements, official return codes)
          Tier 2: Direct Official CDN Download + mandatory Authenticode verification
          Tier 3: Local Offline Installer Cache (<suite>\Installers)
.NOTES
    Author : Antigravity Systems Team
    Version: 4.1.0
    WinGet return codes: https://github.com/microsoft/winget-cli/blob/master/doc/windows/package-manager/winget/returnCodes.md
#>

$Script:PackageEngineRoot = Split-Path -Parent $PSScriptRoot

# Official WinGet return codes (decimal form of the 0x8A15xxxx HRESULTs)
$Script:WingetCodes = @{
    UpdateNotApplicable    = -1978335189  # 0x8A15002B No applicable update found
    NoApplicationsFound    = -1978335212  # 0x8A150014 No packages found
    NoApplicableInstaller  = -1978335216  # 0x8A150010 No applicable installer (e.g. scope mismatch)
    PackageAlreadyInstalled= -1978335135  # 0x8A150061 Found at least one version installed
    InstallAlreadyInstalled= -1978334963  # 0x8A15010D Another version already installed
    RebootRequiredToFinish = -1978334967  # 0x8A150109 Restart to finish installation
    RebootInitiated        = -1978334965  # 0x8A15010B PC will restart to finish installation
}
$Script:WingetSuccessCodes = @(0, $Script:WingetCodes.UpdateNotApplicable, $Script:WingetCodes.PackageAlreadyInstalled, $Script:WingetCodes.InstallAlreadyInstalled)
$Script:WingetRebootCodes  = @(3010, 1641, $Script:WingetCodes.RebootRequiredToFinish, $Script:WingetCodes.RebootInitiated)

function ConvertTo-VersionParts {
    param([string]$Version)
    $clean = ($Version -replace "[^\d.]", "").Trim(".")
    $parts = @()
    foreach ($seg in ($clean.Split(".") | Where-Object { $_ -ne "" })) {
        $n = [long]0
        if ([long]::TryParse($seg, [ref]$n)) { $parts += $n }
    }
    return ,$parts
}

function Write-PackageLog {
    # Host stream keeps Install-ResilientPackage's return value clean; still reaches module stdout / engine log
    param([string]$Message)
    Write-Host $Message
}

function Compare-AppVersion {
    [CmdletBinding()]
    param(
        [string]$InstalledVersion,
        [string]$TargetVersion
    )

    if ([string]::IsNullOrWhiteSpace($InstalledVersion) -or [string]::IsNullOrWhiteSpace($TargetVersion)) {
        return 0
    }

    $p1 = ConvertTo-VersionParts $InstalledVersion
    $p2 = ConvertTo-VersionParts $TargetVersion

    $maxLen = [Math]::Max($p1.Count, $p2.Count)
    for ($i = 0; $i -lt $maxLen; $i++) {
        $num1 = if ($i -lt $p1.Count) { $p1[$i] } else { 0 }
        $num2 = if ($i -lt $p2.Count) { $p2[$i] } else { 0 }
        if ($num1 -gt $num2) { return 1 }
        if ($num1 -lt $num2) { return -1 }
    }
    return 0
}

function Test-AppNameMatch {
    <#
    .SYNOPSIS
        Word-boundary aware DisplayName match: "Git" matches "Git" / "Git version 2.x"
        but NOT "GitHub Desktop" or "Digital...". Patterns containing regex escapes are used as regex.
    #>
    param(
        [string]$DisplayName,
        [Parameter(Mandatory)][string]$Pattern
    )
    if ([string]::IsNullOrWhiteSpace($DisplayName)) { return $false }
    $core = if ($Pattern -match '\\') { $Pattern } else { [regex]::Escape($Pattern) }
    return ($DisplayName -match "(?<![\w])$core(?![\w])")
}

function Get-WingetExe {
    $cmd = Get-Command "winget.exe" -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    # Elevated / SYSTEM sessions often lack the WindowsApps alias on PATH
    $pkg = Get-ChildItem "$env:ProgramFiles\WindowsApps\Microsoft.DesktopAppInstaller_*_x64__8wekyb3d8bbwe\winget.exe" -ErrorAction SilentlyContinue |
           Sort-Object FullName -Descending | Select-Object -First 1
    if ($pkg) { return $pkg.FullName }
    return $null
}

function Test-WingetPackageInstalled {
    param(
        [Parameter(Mandatory)][string]$WingetId,
        [string]$WingetSource = "winget"
    )
    $winget = Get-WingetExe
    if (-not $winget) { return $null }   # unknown
    try {
        $null = & $winget list --id $WingetId --exact --source $WingetSource --accept-source-agreements --disable-interactivity 2>&1
        if ($LASTEXITCODE -eq 0) { return $true }
        if ($LASTEXITCODE -eq $Script:WingetCodes.NoApplicationsFound) { return $false }
    } catch {}
    return $null
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
                 Where-Object { Test-AppNameMatch -DisplayName $_.DisplayName -Pattern $searchPattern } |
                 Sort-Object { ((ConvertTo-VersionParts ([string]$_.DisplayVersion)) | ForEach-Object { $_.ToString("D12") }) -join "." } -Descending |
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
        $cmd = Get-Command $BinaryName -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
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

function Test-TrustedInstaller {
    <#
    .SYNOPSIS
        Downloaded installers must carry a valid Authenticode signature before they are executed.
    #>
    param([Parameter(Mandatory)][string]$Path)
    try {
        $sig = Get-AuthenticodeSignature -FilePath $Path -ErrorAction Stop
        return [PSCustomObject]@{
            IsTrusted = ($sig.Status -eq "Valid")
            Status    = [string]$sig.Status
            Signer    = if ($sig.SignerCertificate) { $sig.SignerCertificate.Subject } else { "" }
        }
    } catch {
        return [PSCustomObject]@{ IsTrusted = $false; Status = "Error: $($_.Exception.Message)"; Signer = "" }
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
        [string]$LocalCacheDir = (Join-Path $Script:PackageEngineRoot "Installers"),
        [string]$RegistryCheckPattern = "",
        [string]$BinaryName = "",
        [string]$MinVersion = "",
        [switch]$ForceReinstall,
        [switch]$AllowUnsignedDownload
    )

    $result = [PSCustomObject]@{
        Name             = $Name
        Success          = $false
        TierUsed         = "None"
        ExitCode         = -1
        InstalledVersion = ""
        ActionTaken      = "None"
        RebootRequired   = $false
        Details          = ""
    }

    # --- Step 0: Smart App Version & Existence Pre-Check ---
    if (-not $ForceReinstall) {
        $appInfo = Get-InstalledAppInfo -Name $Name -RegistryPattern $RegistryCheckPattern -BinaryName $BinaryName

        # WinGet's own inventory is authoritative when no version floor is requested
        if (-not $appInfo.IsInstalled -and [string]::IsNullOrWhiteSpace($MinVersion)) {
            if ((Test-WingetPackageInstalled -WingetId $WingetId -WingetSource $WingetSource) -eq $true) {
                $appInfo = @{ IsInstalled = $true; DisplayName = $Name; InstalledVersion = "winget"; Source = "WinGet" }
            }
        }

        if ($appInfo.IsInstalled) {
            $result.InstalledVersion = $appInfo.InstalledVersion

            if ([string]::IsNullOrWhiteSpace($MinVersion)) {
                # Already installed, no specific version requested -> SKIP
                $result.Success     = $true
                $result.TierUsed    = "SmartPrecheck"
                $result.ExitCode    = 0
                $result.ActionTaken = "SkippedAlreadyInstalled"
                $result.Details     = "Zaten kurulu: $($appInfo.DisplayName) (v$($appInfo.InstalledVersion)). Kurulum atlandi."
                Write-PackageLog "[SKIP] $Name (v$($appInfo.InstalledVersion)) zaten bilgisayarda mevcut. Kurulum adimi atlandi."
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
                    Write-PackageLog "[SKIP] $Name v$($appInfo.InstalledVersion) zaten guncel (Hedef: v$MinVersion). Kurulum adimi atlandi."
                    return $result
                } else {
                    Write-PackageLog "[UPGRADE] $Name v$($appInfo.InstalledVersion) kurulu, ancak hedef surum v$MinVersion. Guncelleme baslatiliyor..."
                    $result.ActionTaken = "Upgrading"
                }
            }
        } else {
            Write-PackageLog "[INSTALL] $Name bilgisayarda bulunamadi. Temiz kurulum baslatiliyor..."
            $result.ActionTaken = "Installing"
        }
    }

    # --- Step 1: Tier 1: WinGet ---
    $winget = Get-WingetExe
    if ($winget) {
        Write-PackageLog "[INFO] [$Name] Tier 1: WinGet deneniyor ($WingetId)..."
        $actionCmd = if ($result.ActionTaken -eq "Upgrading") { "upgrade" } else { "install" }
        $baseArgs  = @($actionCmd, "--id", $WingetId, "--exact", "--silent", "--accept-package-agreements",
                       "--accept-source-agreements", "--disable-interactivity", "--source", $WingetSource)

        # msstore packages have no machine scope; for winget packages try machine scope first,
        # then fall back to the installer's default scope (user-only installers reject --scope machine)
        $attempts = New-Object System.Collections.Generic.List[object]
        if ($WingetSource -ne "msstore") { $attempts.Add([string[]]@("--scope", "machine")) }
        $attempts.Add([string[]]@())

        foreach ($extra in $attempts) {
            try {
                $null = & $winget @baseArgs @extra 2>&1
                $code = $LASTEXITCODE
                if ($code -in $Script:WingetSuccessCodes -or $code -in $Script:WingetRebootCodes) {
                    $result.Success        = $true
                    $result.TierUsed       = "WinGet"
                    $result.ExitCode       = $code
                    $result.RebootRequired = ($code -in $Script:WingetRebootCodes)
                    $result.Details        = "WinGet ile basariyla uygulandi (Kod: $code)."
                    $rebootNote = if ($result.RebootRequired) { " Yeniden baslatma gerekiyor." } else { "" }
                    Write-PackageLog "[SUCCESS] $Name WinGet ile basariyla tamamlandi.$rebootNote"
                    return $result
                }
                if ($code -eq $Script:WingetCodes.NoApplicableInstaller -and $extra.Count -gt 0) {
                    Write-PackageLog "[INFO] [$Name] Makine kapsaminda yukleyici yok, varsayilan kapsam deneniyor..."
                    continue
                }
                Write-PackageLog "[WARN] [$Name] WinGet cikis kodu: $code (0x$('{0:X8}' -f $code)). Fallback deneniyor..."
                break
            } catch {
                Write-PackageLog "[WARN] [$Name] WinGet calistirma hatasi: $_"
                break
            }
        }
    }

    # --- Step 2: Tier 2: Direct Download via Official CDN ---
    if ($DirectDownloadUrl) {
        Write-PackageLog "[INFO] [$Name] Tier 2: Dogrudan uretici CDN indirmesi deneniyor: $DirectDownloadUrl"
        $tempDir = Join-Path $env:TEMP "PostInstall_Packages"
        if (-not (Test-Path $tempDir)) { New-Item -Path $tempDir -ItemType Directory -Force | Out-Null }

        $ext = if ($DirectDownloadUrl -like "*.msi*") { ".msi" } else { ".exe" }
        $tempFile = Join-Path $tempDir ("$($Name -replace '\W','_')_setup$ext")

        try {
            [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 -bor [Net.SecurityProtocolType]::Tls13
            $wc = New-Object System.Net.WebClient
            $wc.Headers.Add("User-Agent", "Mozilla/5.0 (Windows NT 10.0; Win64; x64) MaintenanceEngine/4.1")
            $wc.DownloadFile($DirectDownloadUrl, $tempFile)
            $wc.Dispose()

            if ((Test-Path $tempFile) -and (Get-Item $tempFile).Length -gt 500000) {
                $trust = Test-TrustedInstaller -Path $tempFile
                if (-not $trust.IsTrusted -and -not $AllowUnsignedDownload) {
                    Write-PackageLog "[ERROR] [$Name] Indirilen dosyanin dijital imzasi gecersiz ($($trust.Status)). Guvenlik nedeniyle calistirilmadi."
                } else {
                    Write-PackageLog "[INFO] [$Name] Paket indirildi ($([math]::Round((Get-Item $tempFile).Length/1MB,1)) MB), imza: $($trust.Signer). Kuruluyor..."

                    $execPath = $tempFile
                    $execArgs = $DirectSilentArgs
                    if ($tempFile -like "*.msi") {
                        $execPath = "msiexec.exe"
                        $execArgs = "/i `"$tempFile`" /qn /norestart ALLUSERS=1"
                    }

                    $p = Start-Process -FilePath $execPath -ArgumentList $execArgs -Wait -PassThru -NoNewWindow
                    if ($p.ExitCode -in @(0, 3010, 1641, 1638)) {
                        $result.Success        = $true
                        $result.TierUsed       = "DirectDownload"
                        $result.ExitCode       = $p.ExitCode
                        $result.RebootRequired = ($p.ExitCode -in @(3010, 1641))
                        $result.Details        = "Direct CDN ile basariyla kuruldu."
                        Write-PackageLog "[SUCCESS] $Name dogrudan indirme ile kuruldu (Kod: $($p.ExitCode))."
                        return $result
                    }
                    Write-PackageLog "[WARN] [$Name] Dogrudan kurulum cikis kodu: $($p.ExitCode)"
                }
            }
        } catch {
            Write-PackageLog "[WARN] [$Name] Dogrudan indirme hatasi: $_"
        } finally {
            if (Test-Path $tempFile) { Remove-Item $tempFile -Force -ErrorAction SilentlyContinue }
        }
    }

    # --- Step 3: Tier 3: Local Offline Cache ---
    if (Test-Path $LocalCacheDir) {
        $localInstaller = Get-ChildItem -Path $LocalCacheDir -File -ErrorAction SilentlyContinue |
                          Where-Object { $_.BaseName -like "*$Name*" } | Select-Object -First 1
        if ($localInstaller) {
            Write-PackageLog "[INFO] [$Name] Tier 3: Yerel cevrimdisi onbellek bulundu: $($localInstaller.FullName)"
            try {
                $p = Start-Process -FilePath $localInstaller.FullName -ArgumentList $DirectSilentArgs -Wait -PassThru -NoNewWindow
                if ($p.ExitCode -in @(0, 3010, 1641, 1638)) {
                    $result.Success        = $true
                    $result.TierUsed       = "LocalCache"
                    $result.ExitCode       = $p.ExitCode
                    $result.RebootRequired = ($p.ExitCode -in @(3010, 1641))
                    $result.Details        = "Yerel onbellekten kuruldu."
                    Write-PackageLog "[SUCCESS] $Name yerel onbellek paketiyle kuruldu."
                    return $result
                }
            } catch {}
        }
    }

    $result.Details = "Tum kurulum katmanlari (WinGet, CDN, Yerel) denendi ancak basarisiz oldu."
    Write-PackageLog "[WARN] [$Name] Kurulum tamamlanamadi."
    return $result
}
