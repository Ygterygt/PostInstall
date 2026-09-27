#Requires -Version 5.1
<#
.SYNOPSIS
    07_EnvironmentAndPaths.ps1 - Universal Environment Variables & System PATH Configuration
.DESCRIPTION
    Dynamically configures system and user paths on ANY machine:
    1. Discovers standard tool directories (Git, 7-Zip, Python, Node, PS7, suite root) and appends
       missing ones to Machine PATH. PATH is read/written RAW (REG_EXPAND_SZ) so existing
       %SystemRoot%-style references are preserved instead of being flattened.
    2. Configures user developer environment variables dynamically using $env:USERPROFILE
    3. Broadcasts WM_SETTINGCHANGE (Environment) to all top-level windows
    4. Refreshes live PowerShell session $env:Path
#>
[CmdletBinding()]
param()

$ErrorActionPreference = "Continue"
. (Join-Path (Split-Path -Parent $PSScriptRoot) "Tools\Common.ps1")

Write-Output "[INFO] 07_EnvironmentAndPaths: Sistem PATH ve ortam degiskenleri yapilandiriliyor..."

# 1. Candidate standard developer & tool directories
$candidatePaths = @(
    "$env:ProgramFiles\Git\cmd",
    "$env:ProgramFiles\7-Zip",
    (Get-SuiteRoot),
    "$env:ProgramFiles\PowerShell\7",
    "$env:ProgramFiles\nodejs"
)

# Dynamically discover installed machine-wide Python versions (per-user ones belong to User PATH)
try {
    $pyDirs = Get-ChildItem -Path "$env:ProgramFiles\Python*" -Directory -ErrorAction SilentlyContinue
    foreach ($py in $pyDirs) {
        $candidatePaths += $py.FullName
        $scriptsDir = Join-Path $py.FullName "Scripts"
        if (Test-Path $scriptsDir) { $candidatePaths += $scriptsDir }
    }
} catch {}

$existing = @($candidatePaths | Where-Object { $_ -and (Test-Path $_) })

# Synchronize into Machine PATH
try {
    $rawMachinePath = Get-RawPathValue -Scope Machine
    $merge = Merge-PathEntries -RawPath $rawMachinePath -Entries $existing

    if ($merge.Added.Count -gt 0) {
        foreach ($p in $merge.Added) { Write-Output "[INFO] Machine PATH degiskenine eklendi: $p" }
        if ($merge.Value.Length -gt 4095) {
            Write-Output "[WARN] Machine PATH $($merge.Value.Length) karakter. Bazi eski araclar 4095 karakterden uzun PATH'i kesebilir."
        }
        Set-RawPathValue -Scope Machine -Value $merge.Value
        Write-Output "[SUCCESS] Machine PATH guncellendi (REG_EXPAND_SZ korunarak, $($merge.Value.Length) karakter)."
    } else {
        Write-Output "[SUCCESS] Sistem Machine PATH dizinleri zaten guncel."
    }
} catch {
    Write-Output "[WARN] Sistem Machine PATH kaydedilemedi (yonetici yetkisi gerekebilir): $_"
}

# 2. Dynamic User Workspace Environment Variables
try {
    $userDesktop = if ($env:USERPROFILE) { Join-Path $env:USERPROFILE "Desktop" } else { "C:\Users\$env:USERNAME\Desktop" }
    $workspaceDir = Join-Path $userDesktop "Antigravity"
    $docsDir      = Join-Path $workspaceDir "Docs"

    [Environment]::SetEnvironmentVariable("ANTIGRAVITY_WORKSPACE", $workspaceDir, [EnvironmentVariableTarget]::User)
    [Environment]::SetEnvironmentVariable("DOCS_DIR", $docsDir, [EnvironmentVariableTarget]::User)
    Write-Output "[SUCCESS] Kullanici ortam degiskenleri tanimlandi (Hedef: $workspaceDir)."
} catch {
    Write-Output "[WARN] Kullanici degiskenleri ayarlanamadi: $_"
}

# 3. Broadcast WM_SETTINGCHANGE to top-level windows (Windows OS environment reload)
try {
    Send-EnvironmentChange
    Write-Output "[INFO] Windows Explorer & Sistem ortam degiskeni yayini (WM_SETTINGCHANGE) gonderildi."
} catch {
    Write-Output "[WARN] WM_SETTINGCHANGE yayini uyarisi: $_"
}

# 4. Live session PATH refresh
try {
    Update-SessionPath
    Write-Output "[SUCCESS] Oturum `$env:Path degiskeni guncellendi."
} catch {}

Write-Output "[SUCCESS] 07_EnvironmentAndPaths adimi tamamlandi."
exit 0
