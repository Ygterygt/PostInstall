#Requires -Version 5.1
<#
.SYNOPSIS
    New-ReleasePackage.ps1 - Builds the end-user zip (ComputerMaintenancePro-vX.Y.Z.zip) + SHA256 file
.DESCRIPTION
    Developer / CI tool (not shipped). Uses an allow-list, so tests, docs, dev tools, CI files and local
    installers never end up in the package. PostInstall.exe is rebuilt from Program.cs with the version
    from config.json. With -Tag (e.g. "v4.2.0" or "v4.2.0-beta.1") the tag must match config.json.
.EXAMPLE
    powershell -ExecutionPolicy Bypass -File Tools\New-ReleasePackage.ps1
#>
[CmdletBinding()]
param(
    [string]$OutputDir = "",
    [string]$Tag = ""
)

$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSScriptRoot
# PS 5.1 leaves $PSScriptRoot empty inside script param() defaults, so resolve here
if (-not $OutputDir) { $OutputDir = Join-Path $root "dist" }

$version = (Get-Content (Join-Path $root "config.json") -Raw -Encoding UTF8 | ConvertFrom-Json).Version
if ($Tag) {
    $tagVersion = ($Tag -replace '^v', '') -replace '-.*$', ''
    if ($tagVersion -ne $version) { throw "Etiket ($Tag) ile config.json surumu ($version) uyusmuyor." }
}
$label = if ($Tag) { $Tag -replace '^v', '' } else { $version }

# Files shipped to end users (paths relative to the repo root). Folders take *.ps1 only.
$files = @(
    "Launch-PostInstall.bat", "PostInstallUI.ps1", "PostInstallEngine.ps1",
    "config.json", "steps.json", "gpu_compatibility.json",
    "CHANGELOG.md", "Installers\README.md"
)
$folders = @{
    "Modules" = @()
    "Tools"   = @("Build-Launcher.ps1", "Enforce-Encoding.ps1", "New-ReleasePackage.ps1")   # dev-only tools
}

$packageName = "ComputerMaintenancePro"
$staging = Join-Path $env:TEMP ("CMP_Release_{0}" -f [Guid]::NewGuid().ToString("N").Substring(0, 8))
$pkgRoot = Join-Path $staging $packageName
New-Item -ItemType Directory -Path $pkgRoot -Force | Out-Null

try {
    foreach ($rel in $files) {
        $src = Join-Path $root $rel
        if (-not (Test-Path -LiteralPath $src)) { throw "Paket dosyasi eksik: $rel" }
        $dst = Join-Path $pkgRoot $rel
        New-Item -ItemType Directory -Path (Split-Path -Parent $dst) -Force | Out-Null
        Copy-Item -LiteralPath $src -Destination $dst
    }
    foreach ($folder in $folders.Keys) {
        New-Item -ItemType Directory -Path (Join-Path $pkgRoot $folder) -Force | Out-Null
        Get-ChildItem -Path (Join-Path $root $folder) -Filter "*.ps1" -File |
            Where-Object { $_.Name -notin $folders[$folder] } |
            ForEach-Object { Copy-Item -LiteralPath $_.FullName -Destination (Join-Path $pkgRoot "$folder\$($_.Name)") }
    }
    # End-user guide sits at the package root
    Copy-Item -LiteralPath (Join-Path $root "docs\KULLANIM.md") -Destination (Join-Path $pkgRoot "KULLANIM.md")

    & (Join-Path $PSScriptRoot "Build-Launcher.ps1") -OutputPath (Join-Path $pkgRoot "PostInstall.exe") | Out-Null

    New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null
    $zipPath = Join-Path $OutputDir "$packageName-v$label.zip"
    if (Test-Path -LiteralPath $zipPath) { Remove-Item -LiteralPath $zipPath -Force }
    Compress-Archive -Path $pkgRoot -DestinationPath $zipPath -CompressionLevel Optimal

    $hash = (Get-FileHash -LiteralPath $zipPath -Algorithm SHA256).Hash
    $shaPath = "$zipPath.sha256"
    [System.IO.File]::WriteAllText($shaPath, "$hash  $(Split-Path -Leaf $zipPath)`n")

    $count = @(Get-ChildItem -LiteralPath $pkgRoot -Recurse -File).Count
    Write-Host ("[SUCCESS] {0} ({1} dosya, {2:N1} MB)" -f $zipPath, $count, ((Get-Item -LiteralPath $zipPath).Length / 1MB)) -ForegroundColor Green
    Write-Host "[INFO] SHA256: $hash"
    [PSCustomObject]@{ ZipPath = $zipPath; Sha256Path = $shaPath; Sha256 = $hash; Version = $label; FileCount = $count }
} finally {
    Remove-Item -LiteralPath $staging -Recurse -Force -ErrorAction SilentlyContinue
}
