#Requires -Version 5.1
<#
.SYNOPSIS
    Build-Launcher.ps1 - Compiles Program.cs into PostInstall.exe with the in-box C# compiler
.DESCRIPTION
    Uses the .NET Framework 4.x csc.exe that ships with every Windows 10/11, so no SDK is needed.
    Output is a WinExe (no console window) that self-elevates via UAC and starts PostInstallUI.ps1.
.EXAMPLE
    powershell -ExecutionPolicy Bypass -File Tools\Build-Launcher.ps1
#>
[CmdletBinding()]
param(
    [string]$OutputPath = ""
)

$ErrorActionPreference = "Stop"
$root   = Split-Path -Parent $PSScriptRoot
# PS 5.1 leaves $PSScriptRoot empty inside script param() defaults, so resolve here
if (-not $OutputPath) { $OutputPath = Join-Path $root "PostInstall.exe" }
$source = Join-Path $root "Program.cs"

$csc = Get-ChildItem "$env:WINDIR\Microsoft.NET\Framework64\v4*\csc.exe", "$env:WINDIR\Microsoft.NET\Framework\v4*\csc.exe" -ErrorAction SilentlyContinue |
       Sort-Object FullName -Descending | Select-Object -First 1
if (-not $csc) { throw "csc.exe bulunamadi (.NET Framework 4.x gerekli)." }

# Stamp the exe with the suite version (Explorer > Properties > Details) from config.json
$version = (Get-Content (Join-Path $root "config.json") -Raw -Encoding UTF8 | ConvertFrom-Json).Version
if ($version -notmatch '^\d+\.\d+\.\d+$') { throw "config.json Version gecersiz: '$version' (beklenen: X.Y.Z)" }
$assemblyInfo = Join-Path $env:TEMP ("CMP_AssemblyInfo_{0}.cs" -f [Guid]::NewGuid().ToString("N").Substring(0, 8))
@"
using System.Reflection;
[assembly: AssemblyTitle("Computer Maintenance Pro")]
[assembly: AssemblyProduct("Computer Maintenance Pro")]
[assembly: AssemblyDescription("Windows kurulum sonrasi hazirlik, bakim ve izleme araci")]
[assembly: AssemblyVersion("$version.0")]
[assembly: AssemblyFileVersion("$version.0")]
[assembly: AssemblyInformationalVersion("$version")]
"@ | Set-Content -Path $assemblyInfo -Encoding UTF8

Write-Host "[INFO] Derleyici : $($csc.FullName)"
Write-Host "[INFO] Kaynak    : $source (v$version)"
Write-Host "[INFO] Cikti     : $OutputPath"

try {
    & $csc.FullName /nologo /target:winexe /platform:anycpu /optimize+ /utf8output `
        /reference:System.Windows.Forms.dll "/out:$OutputPath" $source $assemblyInfo
    if ($LASTEXITCODE -ne 0) { throw "Derleme basarisiz (csc exit $LASTEXITCODE)." }
} finally {
    Remove-Item -LiteralPath $assemblyInfo -Force -ErrorAction SilentlyContinue
}

$asm = [System.Reflection.Assembly]::Load([System.IO.File]::ReadAllBytes($OutputPath))
Write-Host "[SUCCESS] PostInstall.exe derlendi ($((Get-Item $OutputPath).Length) bayt, EntryPoint: $($asm.EntryPoint.DeclaringType.FullName).$($asm.EntryPoint.Name))" -ForegroundColor Green
