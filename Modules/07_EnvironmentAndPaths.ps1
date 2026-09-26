#Requires -Version 5.1
<#
.SYNOPSIS
    07_EnvironmentAndPaths.ps1 - Universal Environment Variables & System PATH Configuration
.DESCRIPTION
    Dynamically configures system and user paths on ANY machine:
    1. Discovers and synchronizes standard tool directories (Git, 7-Zip, Python, Node, PostInstall, PS7) into Machine PATH
    2. Configures user developer environment variables dynamically using $env:USERPROFILE
    3. Broadcasts WM_SETTINGCHANGE (Environment) to all top-level windows for instant system-wide recognition
    4. Refreshes live PowerShell session $env:Path
#>
[CmdletBinding()]
param()

$ErrorActionPreference = "Continue"

Write-Output "[INFO] 07_EnvironmentAndPaths: Sistem PATH ve ortam degiskenleri yapilandiriliyor..."

# 1. Candidate standard developer & tool directories
$candidatePaths = @(
    "C:\Program Files\Git\cmd",
    "C:\Program Files\Git\bin",
    "C:\Program Files\7-Zip",
    "C:\PostInstall",
    "$env:ProgramFiles\PowerShell\7",
    "$env:LOCALAPPDATA\Programs\Python\Python312",
    "$env:LOCALAPPDATA\Programs\Python\Python312\Scripts",
    "$env:ProgramFiles\Python312",
    "$env:ProgramFiles\Python312\Scripts",
    "$env:ProgramFiles\nodejs"
)

# Dynamically discover any other installed Python versions
try {
    $pyDirs = Get-ChildItem -Path "$env:LOCALAPPDATA\Programs\Python", "$env:ProgramFiles\Python*" -Directory -ErrorAction SilentlyContinue
    foreach ($py in $pyDirs) {
        $candidatePaths += $py.FullName
        $scriptsDir = Join-Path $py.FullName "Scripts"
        if (Test-Path $scriptsDir) { $candidatePaths += $scriptsDir }
    }
} catch {}

# Synchronize into Machine PATH
try {
    $currentMachinePath = [Environment]::GetEnvironmentVariable("Path", [EnvironmentVariableTarget]::Machine)
    $paths = if ($currentMachinePath) { $currentMachinePath -split ";" | Where-Object { $_.Trim() -ne "" } } else { @() }
    $updated = $false

    foreach ($p in ($candidatePaths | Select-Object -Unique)) {
        if (Test-Path $p) {
            if ($paths -notcontains $p) {
                $paths += $p
                $updated = $true
                Write-Output "[INFO] Machine PATH degiskenine eklendi: $p"
            }
        }
    }

    if ($updated) {
        $newPath = ($paths | Select-Object -Unique) -join ";"
        if ($newPath.Length -gt 2048) {
            Write-Output "[WARN] Machine PATH uzunlugu 2048 karakter sinirina yaklasti ($($newPath.Length) karakter). Win32 uyumlulugu icin dikkat edilmeli."
        }
        [Environment]::SetEnvironmentVariable("Path", $newPath, [EnvironmentVariableTarget]::Machine)
        Write-Output "[SUCCESS] Sistem Machine PATH degiskeni basariyla guncellendi (Toplam: $($paths.Count) dizin, $($newPath.Length) karakter)."
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
    Add-Type -Namespace Win32 -Name NativeMethods -MemberDefinition @"
    [System.Runtime.InteropServices.DllImport("user32.dll", SetLastError = true, CharSet = System.Runtime.InteropServices.CharSet.Auto)]
    public static extern System.IntPtr SendMessageTimeout(
        System.IntPtr hWnd,
        uint Msg,
        System.UIntPtr wParam,
        string lParam,
        uint fuFlags,
        uint uTimeout,
        out System.UIntPtr lpdwResult);
"@ -ErrorAction SilentlyContinue

    $HWND_BROADCAST = [System.IntPtr]0xffff
    $WM_SETTINGCHANGE = 0x1a
    $result = [System.UIntPtr]::Zero
    [Win32.NativeMethods]::SendMessageTimeout($HWND_BROADCAST, $WM_SETTINGCHANGE, [System.UIntPtr]::Zero, "Environment", 2, 5000, [ref]$result) | Out-Null
    Write-Output "[INFO] Windows Explorer & Sistem ortam degiskeni yayini (WM_SETTINGCHANGE) gonderildi."
} catch {
    Write-Output "[WARN] WM_SETTINGCHANGE yayini uyarisi: $_"
}

# 4. Live session PATH refresh
try {
    $m = [Environment]::GetEnvironmentVariable("Path", [EnvironmentVariableTarget]::Machine)
    $u = [Environment]::GetEnvironmentVariable("Path", [EnvironmentVariableTarget]::User)
    $env:Path = "$m;$u"
    Write-Output "[SUCCESS] Oturum `$env:Path degiskeni guncellendi."
} catch {}

Write-Output "[SUCCESS] 07_EnvironmentAndPaths adimi tamamlandi."
exit 0
