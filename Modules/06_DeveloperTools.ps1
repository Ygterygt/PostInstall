#Requires -Version 5.1
<#
.SYNOPSIS
    06_DeveloperTools.ps1 - Developer tools, AI assistants & applications installation
.DESCRIPTION
    Installs packages with intelligent pre-checking and semantic versioning:
    Skips immediately if the application is already installed and up-to-date.
    AI Assistants: Antigravity, Claude, ChatGPT
    Browsers     : Google Chrome, Opera GX
    Gaming       : Xbox App
    Dev Tools    : Git, Python 3.12, Node.js LTS, VS Code, PowerShell 7+, 7-Zip, Notepad++
.NOTES
    Author : Antigravity Systems Team
    Version: 4.0.0
#>
[CmdletBinding()]
param()

$ErrorActionPreference = "Continue"

Write-Output "[INFO] 06_DeveloperTools: Akilli surum kontrolu ve paket kurulumu baslatiliyor..."

$engineRoot = Split-Path -Parent $PSScriptRoot
$packageEngine = Join-Path $engineRoot "Tools\PackageEngine.ps1"
if (Test-Path $packageEngine) {
    . $packageEngine
} else {
    Write-Output "[ERROR] PackageEngine.ps1 bulunamadi: $packageEngine"
    exit 1
}

$results = New-Object System.Collections.Generic.List[object]

#region === 1. DEV TOOLS ===
Write-Output "[INFO] ===== 1. GELISTIRICI ARACLARI & PROGRAMLAMA ====="

$devPackages = @(
    @{
        Name            = "7-Zip"
        WingetId        = "7zip.7zip"
        RegistryPattern = "7-Zip"
        BinaryName      = "7z"
        MinVersion      = "23.01"
    },
    @{
        Name            = "Git for Windows"
        WingetId        = "Git.Git"
        RegistryPattern = "Git"
        BinaryName      = "git"
        MinVersion      = "2.40.0"
        DirectUrl       = "https://github.com/git-for-windows/git/releases/download/v2.47.1.windows.1/Git-2.47.1-64-bit.exe"
        DirectArgs      = "/VERYSILENT /NORESTART /NOCANCEL /SP- /CLOSEAPPLICATIONS /RESTARTAPPLICATIONS"
    },
    @{
        Name            = "Python 3.12"
        WingetId        = "Python.Python.3.12"
        RegistryPattern = "Python 3.12"
        BinaryName      = "python"
        MinVersion      = "3.12.0"
        DirectUrl       = "https://www.python.org/ftp/python/3.12.8/python-3.12.8-amd64.exe"
        DirectArgs      = "/quiet InstallAllUsers=1 PrependPath=1"
    },
    @{
        Name            = "Node.js LTS"
        WingetId        = "OpenJS.NodeJS.LTS"
        RegistryPattern = "Node.js"
        BinaryName      = "node"
        MinVersion      = "20.0.0"
        DirectUrl       = "https://nodejs.org/dist/v22.12.0/node-v22.12.0-x64.msi"
    },
    @{
        Name            = "Visual Studio Code"
        WingetId        = "Microsoft.VisualStudioCode"
        RegistryPattern = "Visual Studio Code"
        BinaryName      = "code"
        MinVersion      = "1.85.0"
        DirectUrl       = "https://update.code.visualstudio.com/latest/win32-x64/stable"
        DirectArgs      = "/VERYSILENT /NORESTART /MERGETASKS=!runcode,addcontextmenufiles,addcontextmenufolders,associatewithfiles,addtopath"
    },
    @{
        Name            = "PowerShell 7+"
        WingetId        = "Microsoft.PowerShell"
        RegistryPattern = "PowerShell 7"
        BinaryName      = "pwsh"
        MinVersion      = "7.4.0"
        DirectUrl       = "https://github.com/PowerShell/PowerShell/releases/download/v7.4.6/PowerShell-7.4.6-win-x64.msi"
    },
    @{
        Name            = "Notepad++"
        WingetId        = "Notepad++.Notepad++"
        RegistryPattern = "Notepad\+\+"
        BinaryName      = "notepad++"
        MinVersion      = "8.6.0"
        DirectUrl       = "https://github.com/notepad-plus-plus/notepad-plus-plus/releases/download/v8.7.4/npp.8.7.4.Installer.x64.exe"
        DirectArgs      = "/S"
    }
)

foreach ($pkg in $devPackages) {
    Install-ResilientPackage `
        -Name $pkg.Name `
        -WingetId $pkg.WingetId `
        -RegistryCheckPattern $pkg.RegistryPattern `
        -BinaryName $pkg.BinaryName `
        -MinVersion $pkg.MinVersion `
        -DirectDownloadUrl $pkg.DirectUrl `
        -DirectSilentArgs $pkg.DirectArgs | ForEach-Object { $results.Add($_) }
}
#endregion

#region === 2. AI ASSISTANTS ===
Write-Output "`n[INFO] ===== 2. YAPAY ZEKA ASISTANLARI ====="

Install-ResilientPackage `
    -Name "Antigravity (Google AGY)" `
    -WingetId "Google.Antigravity" `
    -RegistryCheckPattern "Antigravity" `
    -BinaryName "agy" | ForEach-Object { $results.Add($_) }

Install-ResilientPackage `
    -Name "Claude (Anthropic)" `
    -WingetId "Anthropic.Claude" `
    -RegistryCheckPattern "Claude" | ForEach-Object { $results.Add($_) }

Install-ResilientPackage `
    -Name "ChatGPT (OpenAI)" `
    -WingetId "9PLM9XGG6VKS" `
    -WingetSource "msstore" `
    -RegistryCheckPattern "ChatGPT" | ForEach-Object { $results.Add($_) }
#endregion

#region === 3. WEB & GAMING APPS ===
Write-Output "`n[INFO] ===== 3. TARAYICI & OYUN UYGULAMALARI ====="

# Google Chrome
Install-ResilientPackage `
    -Name "Google Chrome" `
    -WingetId "Google.Chrome" `
    -RegistryCheckPattern "Google Chrome" `
    -BinaryName "chrome" `
    -MinVersion "120.0.0" `
    -DirectDownloadUrl "https://dl.google.com/chrome/install/latest/chrome_installer.exe" `
    -DirectSilentArgs "/silent /install" | ForEach-Object { $results.Add($_) }

# Opera GX
Install-ResilientPackage `
    -Name "Opera GX" `
    -WingetId "XPDBZ4MPRKNN30" `
    -WingetSource "msstore" `
    -RegistryCheckPattern "Opera GX" | ForEach-Object { $results.Add($_) }

# Xbox App
Install-ResilientPackage `
    -Name "Xbox (Microsoft Gaming)" `
    -WingetId "9MV0B5HZVK9Z" `
    -WingetSource "msstore" `
    -RegistryCheckPattern "Xbox" | ForEach-Object { $results.Add($_) }
#endregion

# Refresh session environment PATH
try {
    $machinePath = [Environment]::GetEnvironmentVariable("Path", [EnvironmentVariableTarget]::Machine)
    $userPath    = [Environment]::GetEnvironmentVariable("Path", [EnvironmentVariableTarget]::User)
    $env:Path    = "$machinePath;$userPath"
    Write-Output "`n[INFO] Oturum PATH ortam degiskenleri yenilendi."
} catch {}

# Summary
$ok      = @($results | Where-Object { $_.Success })
$failed  = @($results | Where-Object { -not $_.Success })
$skipped = @($ok | Where-Object { $_.ActionTaken -like "Skipped*" })
Write-Output "`n[INFO] ===== PAKET OZETI ====="
Write-Output "[INFO] Toplam: $($results.Count) | Kuruldu/Guncellendi: $($ok.Count - $skipped.Count) | Zaten kurulu: $($skipped.Count) | Basarisiz: $($failed.Count)"
foreach ($item in $failed) { Write-Output "[WARN]   Basarisiz: $($item.Name) - $($item.Details)" }

if (@($results | Where-Object { $_.RebootRequired }).Count -gt 0) {
    Write-Output "[WARN] 06_DeveloperTools tamamlandi - bazi paketler yeniden baslatma istiyor."
    exit 3010
}
Write-Output "[SUCCESS] 06_DeveloperTools tamamlandi."
exit 0