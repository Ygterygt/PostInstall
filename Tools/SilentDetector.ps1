#Requires -Version 5.1
<#
.SYNOPSIS
    SilentDetector.ps1 - Enterprise Installer Type & Silent Switch Detection Engine
.DESCRIPTION
    Analyzes .exe, .msi, .msix, .appx installer packages by inspecting PE headers,
    file signatures, publisher metadata, and embedded string tables to automatically
    determine the installer framework (InnoSetup, NSIS, MSI, WiX, InstallShield, etc.)
    and return the optimal silent / unattended installation switches.
#>

function Get-InstallerSignature {
    param([string]$FilePath)

    if (-not (Test-Path $FilePath)) {
        return @{
            Type        = "NotFound"
            SilentArgs  = ""
            Command     = ""
            Description = "Dosya bulunamadi"
        }
    }

    $ext = [System.IO.Path]::GetExtension($FilePath).ToLower()
    $fi  = Get-Item $FilePath

    # 1. MSI Package
    if ($ext -eq ".msi") {
        return @{
            Type        = "MSI (Windows Installer)"
            Installer   = "msiexec.exe"
            SilentArgs  = "/i `"$FilePath`" /qn /norestart ALLUSERS=1"
            Command     = "msiexec.exe /i `"$FilePath`" /qn /norestart ALLUSERS=1"
            Description = "Standart Windows Installer Paketi"
            IsMsi       = $true
        }
    }

    # 2. MSIX / AppX Package
    if ($ext -in @(".msix", ".appx", ".msixbundle", ".appxbundle")) {
        return @{
            Type        = "MSIX / AppX Package"
            Installer   = "powershell.exe"
            SilentArgs  = "Add-AppxPackage -Path `"$FilePath`" -DeferRegistrationWhenPackagesAreInUse"
            Command     = "powershell.exe -Command Add-AppxPackage -Path `"$FilePath`" -DeferRegistrationWhenPackagesAreInUse"
            Description = "Modern Windows Uygulama Paketi"
            IsAppx      = $true
        }
    }

    # 3. EXE Analysis via FileVersionInfo and Binary Signature Scanning
    if ($ext -eq ".exe") {
        $fvi = [System.Diagnostics.FileVersionInfo]::GetVersionInfo($FilePath)
        $desc = "$($fvi.FileDescription) $($fvi.ProductName) $($fvi.CompanyName) $($fvi.Comments)"

        # Read beginning and chunk of binary for string analysis
        $bytesToRead = [math]::Min([long]$fi.Length, 1048576) # Read up to 1MB
        $bytes = New-Object byte[] $bytesToRead
        try {
            $fs = [System.IO.File]::OpenRead($FilePath)
            $null = $fs.Read($bytes, 0, $bytesToRead)
            $fs.Close()
            $fs.Dispose()
        } catch {
            $bytes = New-Object byte[] 0
        }

        $asciiString = [System.Text.Encoding]::ASCII.GetString($bytes)

        # NVIDIA packages (NVIDIA App, display drivers) are 7-Zip SFX wrappers around NVIDIA's own
        # setup.exe: the generic 7-Zip switches would only extract and then open the setup UI.
        if ($fvi.CompanyName -like "*NVIDIA*") {
            return @{
                Type        = "NVIDIA Installer (7-Zip SFX)"
                Installer   = $FilePath
                SilentArgs  = "-s -noreboot"
                Command     = "`"$FilePath`" -s -noreboot"
                Description = "NVIDIA Kurulum Paketi"
            }
        }

        # Inno Setup Detection
        if ($desc -like "*Inno Setup*" -or $asciiString -like "*Inno Setup*" -or $asciiString -like "*jr.InnoSetup*") {
            return @{
                Type        = "Inno Setup"
                Installer   = $FilePath
                SilentArgs  = "/VERYSILENT /SUPPRESSMSGBOXES /NORESTART /SP-"
                Command     = "`"$FilePath`" /VERYSILENT /SUPPRESSMSGBOXES /NORESTART /SP-"
                Description = "Inno Setup Kurulum Paketi"
            }
        }

        # NSIS (Nullsoft Scriptable Install System) Detection
        if ($desc -like "*Nullsoft*" -or $asciiString -like "*Nullsoft.NSIS*" -or $asciiString -like "*NSIS.Library*" -or $asciiString -like "*Nullsoft Install System*") {
            return @{
                Type        = "NSIS (Nullsoft)"
                Installer   = $FilePath
                SilentArgs  = "/S"
                Command     = "`"$FilePath`" /S"
                Description = "Nullsoft Scriptable Install System"
            }
        }

        # WiX Burn Bootstrapper Detection
        if ($desc -like "*WiX*" -or $asciiString -like "*WixBundleVersion*" -or $asciiString -like "*WIX_BURN_CONTAINER*" -or $asciiString -like "*BurnPipe.*") {
            return @{
                Type        = "WiX Bootstrapper (Burn)"
                Installer   = $FilePath
                SilentArgs  = "/quiet /norestart"
                Command     = "`"$FilePath`" /quiet /norestart"
                Description = "Windows Installer XML (WiX) Paketleyicisi"
            }
        }

        # InstallShield Detection
        if ($desc -like "*InstallShield*" -or $asciiString -like "*InstallShield*" -or $asciiString -like "*ISSetup.dll*") {
            return @{
                Type        = "InstallShield"
                Installer   = $FilePath
                SilentArgs  = "/s /v`"/qn /norestart`""
                Command     = "`"$FilePath`" /s /v`"/qn /norestart`""
                Description = "InstallShield Kurulum Paketi"
            }
        }

        # Advanced Installer Detection
        if ($asciiString -like "*Advanced Installer*" -or $desc -like "*Advanced Installer*") {
            return @{
                Type        = "Advanced Installer"
                Installer   = $FilePath
                SilentArgs  = "/exenoui /qn /norestart"
                Command     = "`"$FilePath`" /exenoui /qn /norestart"
                Description = "Advanced Installer Paketi"
            }
        }

        # Microsoft Visual C++ / VC Redist
        if ($desc -like "*Visual C++*" -or $desc -like "*VC Redist*" -or $fvi.InternalName -like "*vcredist*") {
            return @{
                Type        = "Microsoft VC++ Redistributable"
                Installer   = $FilePath
                SilentArgs  = "/quiet /norestart"
                Command     = "`"$FilePath`" /quiet /norestart"
                Description = "Microsoft Visual C++ Çalışma Zamanı"
            }
        }

        # 7-Zip SFX
        if ($asciiString -like "*7-Zip*" -or $asciiString -like "*7zS.sfx*") {
            return @{
                Type        = "7-Zip SFX Archive"
                Installer   = $FilePath
                SilentArgs  = "-y /gm2"
                Command     = "`"$FilePath`" -y /gm2"
                Description = "7-Zip Kendini Açan Arşiv"
            }
        }

        # Squirrel / Electron Installer
        if ($asciiString -like "*Squirrel.Windows*" -or $asciiString -like "*Update.exe --processStart*") {
            return @{
                Type        = "Squirrel / Electron"
                Installer   = $FilePath
                SilentArgs  = "--silent"
                Command     = "`"$FilePath`" --silent"
                Description = "Squirrel / Electron Kurulum Paketi"
            }
        }

        # Default fallback for generic executable
        return @{
            Type        = "Generic Executable (Tahmini)"
            Installer   = $FilePath
            SilentArgs  = "/silent /quiet /norestart"
            Command     = "`"$FilePath`" /silent /quiet /norestart"
            Description = "Genel Yürütülebilir Kurulum Dosyası"
        }
    }

    # 4. Unknown File Type
    return @{
        Type        = "Bilinmeyen Dosya Türü"
        Installer   = $FilePath
        SilentArgs  = ""
        Command     = "`"$FilePath`""
        Description = "Desteklenmeyen veya tanımlanamayan dosya"
    }
}

function Get-InstallerInstallState {
    <#
    .SYNOPSIS
        Compares an installer's ProductName/ProductVersion with what is already installed
        (Uninstall registry + AppX), so re-runs don't reinstall the same or older version.
    #>
    param([Parameter(Mandatory)][string]$FilePath)

    $state = [PSCustomObject]@{ ProductName = ""; ProductVersion = ""; IsInstalled = $false; InstalledVersion = "" }
    if ([System.IO.Path]::GetExtension($FilePath) -ne ".exe") { return $state }   # MSI reports 1638 itself

    $fvi = [System.Diagnostics.FileVersionInfo]::GetVersionInfo($FilePath)
    $state.ProductName    = "$($fvi.ProductName)".Trim()
    $state.ProductVersion = "$($fvi.ProductVersion)".Trim()

    # Generic bootstrapper names would match unrelated software
    if ($state.ProductName.Length -lt 4 -or $state.ProductName -match '^(setup|installer|install|bootstrapper|update)$') { return $state }

    if (-not (Get-Command Get-InstalledAppInfo -ErrorAction SilentlyContinue)) {
        . (Join-Path $PSScriptRoot "PackageEngine.ps1")
    }
    $info = Get-InstalledAppInfo -Name $state.ProductName -RegistryPattern $state.ProductName
    if ($info.IsInstalled) {
        $state.InstalledVersion = $info.InstalledVersion
        # Only "installed" when the installed build is the same or newer than the package
        $state.IsInstalled = (-not $state.ProductVersion) -or ((Compare-AppVersion -InstalledVersion $info.InstalledVersion -TargetVersion $state.ProductVersion) -ge 0)
    }
    return $state
}

function Get-CustomInstallersList {
    param(
        [string]$Directory = (Join-Path (Split-Path -Parent $PSScriptRoot) "Installers")
    )

    if (-not (Test-Path $Directory)) {
        return @()
    }

    $extensions = @("*.exe", "*.msi", "*.msix", "*.appx", "*.msixbundle", "*.appxbundle")
    $files = Get-ChildItem -Path $Directory -Include $extensions -Recurse -ErrorAction SilentlyContinue | Sort-Object Name

    $list = @()
    foreach ($f in $files) {
        $sig = Get-InstallerSignature -FilePath $f.FullName
        $sizeMB = [math]::Round($f.Length / 1MB, 2)
        $inst = Get-InstallerInstallState -FilePath $f.FullName

        $list += [PSCustomObject]@{
            FileName         = $f.Name
            FullPath         = $f.FullName
            SizeMB           = $sizeMB
            DetectedType     = $sig.Type
            SilentArgs       = $sig.SilentArgs
            Description      = $sig.Description
            ProductName      = $inst.ProductName
            ProductVersion   = $inst.ProductVersion
            IsInstalled      = $inst.IsInstalled
            InstalledVersion = $inst.InstalledVersion
            Selected         = (-not $inst.IsInstalled)
            IsMsi            = [bool]$sig.IsMsi
            IsAppx           = [bool]$sig.IsAppx
        }
    }

    return $list
}