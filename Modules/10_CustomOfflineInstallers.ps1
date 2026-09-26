#Requires -Version 5.1
<#
.SYNOPSIS
    10_CustomOfflineInstallers.ps1 - Automated execution of custom offline installers
.DESCRIPTION
    Scans <suite root>\Installers for any user-provided .exe, .msi, .msix, .appx files.
    Utilizes SilentDetector.ps1 to automatically inspect and identify silent command line
    arguments, executing each installer silently with timeout and exit code monitoring.
#>
[CmdletBinding()]
param(
    [string]$InstallersDirectory = "",
    [string[]]$SelectedFileNames = @()
)

$ErrorActionPreference = "Continue"
# PS 5.1 leaves $PSScriptRoot empty inside script param() defaults, so resolve here
if (-not $InstallersDirectory) { $InstallersDirectory = Join-Path (Split-Path -Parent $PSScriptRoot) "Installers" }

Write-Output "[INFO] 10_CustomOfflineInstallers: Ozel ve cevrimdisi yukleyiciler taranıyor..."

. (Join-Path (Split-Path -Parent $PSScriptRoot) "Tools\Common.ps1")
$detectorScript = Join-Path (Get-SuiteRoot) "Tools\SilentDetector.ps1"

# Selection made in the UI wizard (page 3). Missing file = install everything.
if ($SelectedFileNames.Count -eq 0) {
    $selectionFile = Join-Path (Split-Path -Parent (Get-SuiteConfig).StateFile) "OfflineSelection.json"
    if (Test-Path $selectionFile) {
        try {
            $sel = Get-Content -LiteralPath $selectionFile -Raw -Encoding UTF8 | ConvertFrom-Json
            $SelectedFileNames = @($sel.Files)
            Write-Output "[INFO] Sihirbaz secimi uygulaniyor: $($SelectedFileNames.Count) yukleyici secili."
            if ($SelectedFileNames.Count -eq 0) {
                Write-Output "[SUCCESS] Hicbir cevrimdisi yukleyici secilmedi. Adim atlandi."
                exit 0
            }
        } catch {
            Write-Output "[WARN] Secim dosyasi okunamadi ($selectionFile): $_. Tum yukleyiciler kurulacak."
        }
    }
}
$rebootRequired = $false
if (-not (Test-Path $detectorScript)) {
    Write-Output "[WARN] SilentDetector.ps1 bulunamadi ($detectorScript). Varsayilan parametreler kullanilacak."
} else {
    . $detectorScript
}

if (-not (Test-Path $InstallersDirectory)) {
    Write-Output "[INFO] Yukleyici dizini ($InstallersDirectory) bulunamadi. Atlandi."
    exit 0
}

$installers = Get-CustomInstallersList -Directory $InstallersDirectory

if ($installers.Count -eq 0) {
    Write-Output "[INFO] '$InstallersDirectory' dizininde ek kurulum dosyasi (exe/msi/msix) bulunamadi."
    Write-Output "[NOTE] Buraya eklediginiz tum kurulum dosyalari otomatik algilanip sessizce kurulacaktir."
    Write-Output "[SUCCESS] 10_CustomOfflineInstallers tamamlandi (0 dosya)."
    exit 0
}

Write-Output "[INFO] $($installers.Count) adet ozel yukleyici tespit edildi."

foreach ($item in $installers) {
    # If a filter list is passed, skip unselected
    if ($SelectedFileNames.Count -gt 0 -and $SelectedFileNames -notcontains $item.FileName) {
        Write-Output "[INFO] Atlaniyor (Secilmedi): $($item.FileName)"
        continue
    }

    Write-Output "[INFO] ========================================================"
    Write-Output "[INFO] Kurulum: $($item.FileName) ($($item.SizeMB) MB)"
    Write-Output "[INFO] Tespit Edilen Tur: $($item.DetectedType)"
    Write-Output "[INFO] Sessiz Parametre : $($item.SilentArgs)"
    Write-Output "[INFO] ========================================================"

    $filePath = $item.FullPath
    $installerTimeoutSec = 900 # 15 dakika maksimum zaman asimi

    try {
        $execFile = ""
        $execArgs = ""

        if ($item.IsMsi) {
            $execFile = "msiexec.exe"
            $execArgs = "/i `"$filePath`" /qn /norestart ALLUSERS=1"
        } elseif ($item.IsAppx) {
            $execFile = "powershell.exe"
            $execArgs = "-NoProfile -ExecutionPolicy Bypass -Command Add-AppxPackage -Path `"$filePath`" -DeferRegistrationWhenPackagesAreInUse"
        } else {
            $execFile = $filePath
            $execArgs = $item.SilentArgs
        }

        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName         = $execFile
        $psi.Arguments        = $execArgs
        $psi.UseShellExecute  = $false
        $psi.CreateNoWindow   = $true

        $proc = New-Object System.Diagnostics.Process
        $proc.StartInfo = $psi
        $proc.Start() | Out-Null

        $finished = $proc.WaitForExit($installerTimeoutSec * 1000)
        if (-not $finished) {
            Write-Output "[ERROR] $($item.FileName) $installerTimeoutSec saniye icinde tamamlanamadi (Zaman Asimi). Surec sonlandirildi."
            try { $proc.Kill() } catch {}
            $exitCode = 1460
        } else {
            $exitCode = $proc.ExitCode
        }

        switch ($exitCode) {
            0 {
                Write-Output "[SUCCESS] $($item.FileName) basariyla kuruldu (Exit: 0)."
            }
            { $_ -in @(3010, 1641) } {
                Write-Output "[SUCCESS] $($item.FileName) kuruldu. Yeniden baslatma gerekiyor (Exit: $exitCode)."
                $rebootRequired = $true
            }
            1638 {
                Write-Output "[SUCCESS] $($item.FileName) zaten kurulu (Exit: 1638)."
            }
            default {
                Write-Output "[WARN] $($item.FileName) cikis kodu: $exitCode (Detaylar icin uygulama loglarini inceleyin)."
            }
        }
    } catch {
        Write-Output "[ERROR] $($item.FileName) kurulum sureci sirasinda hata: $_"
    }
}

if ($rebootRequired) {
    Write-Output "[WARN] 10_CustomOfflineInstallers tamamlandi - yeniden baslatma gerekiyor."
    exit 3010
}
Write-Output "[SUCCESS] 10_CustomOfflineInstallers tamamlandi."
exit 0
