#Requires -Version 5.1
<#
.SYNOPSIS
    SnapshotEngine.ps1 - Enterprise System Restore Point & Registry Snapshot Engine
.DESCRIPTION
    Creates pre-installation snapshots and manages system rollback:
    1. Windows System Restore Point (Volume Shadow Copy / VSS Checkpoint)
    2. Critical Registry Configuration Export (.reg backup)
    3. Direct launch of Windows System Restore Wizard (rstrui.exe)
#>

function New-SystemSnapshot {
    param(
        [string]$Description = "Antigravity PostInstall Pre-Execution Snapshot",
        [string]$BackupDir   = (Join-Path $env:ProgramData "ComputerMaintenancePro\Backups")
    )

    $result = @{
        RestorePointCreated = $false
        RegistryBackupCreated = $false
        RestorePointSequence = $null
        BackupFiles = @()
        Errors = @()
    }

    if (-not (Test-Path $BackupDir)) {
        New-Item -Path $BackupDir -ItemType Directory -Force | Out-Null
    }

    # 1. Enable System Protection & VSS on System Drive
    try {
        $sysDrive = "$($env:SystemDrive)\"
        
        # Pre-check disk space (VSS requires at least 1 GB to avoid volume lock/starvation)
        $sysVol = Get-Volume -DriveLetter ($env:SystemDrive.TrimEnd(':')) -ErrorAction SilentlyContinue
        if ($sysVol -and $sysVol.SizeRemaining -lt 1073741824) {
            $freeMB = [math]::Round($sysVol.SizeRemaining / 1MB, 0)
            Write-Output "[WARN] Sistem surucusunde ($env:SystemDrive) bos alan kritik ($freeMB MB < 1024 MB). VSS snapshot atlandi."
        } else {
            # Start VSS and System Restore services if stopped
            Start-Service -Name "VSS" -ErrorAction SilentlyContinue
            Start-Service -Name "swprv" -ErrorAction SilentlyContinue

            # Remove 24h cooldown limitation for checkpoint creation
            $srRegPath = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\SystemRestore"
            if (Test-Path $srRegPath) {
                Set-ItemProperty -Path $srRegPath -Name "SystemRestorePointCreationFrequency" -Value 0 -Type DWord -Force -ErrorAction SilentlyContinue
            }

            # Enable Computer Restore on System Drive
            Enable-ComputerRestore -Drive $sysDrive -ErrorAction SilentlyContinue

            # Create Restore Point
            Write-Output "[INFO] Windows Sistem Geri Yukleme Noktasi (VSS Snapshot) olusturuluyor..."
            $sr = Checkpoint-Computer -Description $Description -RestorePointType "APPLICATION_INSTALL" -ErrorAction Stop
            $result.RestorePointCreated = $true
            Write-Output "[SUCCESS] Sistem Geri Yukleme Noktasi basariyla olusturuldu: '$Description'"
        }
    } catch {
        $errMsg = "VSS Snapshot olusturulamadi: $_"
        $result.Errors += $errMsg
        Write-Output "[WARN] $errMsg (Bazi sanal makinelerde veya ozel Windows surumlerinde VSS sinirli olabilir)."
    }

    # 2. Export Critical Registry Settings (.reg & JSON backup)
    try {
        $timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
        $regBackupFile = Join-Path $BackupDir "Registry_PreInstall_$timestamp.reg"
        $envBackupFile = Join-Path $BackupDir "Environment_PreInstall_$timestamp.json"

        # Backup System & User Environment variables to JSON
        $machineEnv = [Environment]::GetEnvironmentVariables([EnvironmentVariableTarget]::Machine)
        $userEnv    = [Environment]::GetEnvironmentVariables([EnvironmentVariableTarget]::User)
        $envData    = @{ Machine = $machineEnv; User = $userEnv; Timestamp = (Get-Date).ToString("o") }
        $envJson    = $envData | ConvertTo-Json -Depth 5
        [System.IO.File]::WriteAllText($envBackupFile, $envJson, (New-Object System.Text.UTF8Encoding($false)))
        $result.BackupFiles += $envBackupFile

        # Export registry sections using reg.exe
        $exportKeys = @(
            "HKLM\SYSTEM\CurrentControlSet\Control\Session Manager\Environment",
            "HKCU\Environment",
            "HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced"
        )

        foreach ($k in $exportKeys) {
            $safeName = $k -replace "\\", "_" -replace ":", ""
            $targetReg = Join-Path $BackupDir "Reg_${safeName}_$timestamp.reg"
            $proc = Start-Process -FilePath "reg.exe" -ArgumentList "export `"$k`" `"$targetReg`" /y" -Wait -PassThru -NoNewWindow
            if ($proc.ExitCode -eq 0) {
                $result.BackupFiles += $targetReg
            }
        }

        $result.RegistryBackupCreated = $true
        Write-Output "[SUCCESS] Kayit Defteri ve Ortam Degiskenleri yedegi alindi ($BackupDir)."
    } catch {
        $result.Errors += "Registry yedegi hatasi: $_"
        Write-Output "[WARN] Kayit defteri yedegi alinirken hata olustu: $_"
    }

    return [PSCustomObject]$result
}

function Restore-RegistrySnapshot {
    param([string]$BackupDir = (Join-Path $env:ProgramData "ComputerMaintenancePro\Backups"))

    Write-Output "[INFO] Kayit Defteri ve Ortam Degiskenleri yedekten geri yukleniyor ($BackupDir)..."
    if (-not (Test-Path $BackupDir)) {
        Write-Output "[ERROR] Yedek dizini bulunamadi: $BackupDir"
        return $false
    }

    $restoredCount = 0
    # Import all recent .reg files
    $regFiles = Get-ChildItem -Path $BackupDir -Filter "Reg_*.reg" -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending
    $importedGroups = @{}

    foreach ($rf in $regFiles) {
        $baseKey = ($rf.Name -split "_\d{8}_\d{6}\.reg")[0]
        if (-not $importedGroups.ContainsKey($baseKey)) {
            $importedGroups[$baseKey] = $true
            Write-Output "[INFO] Iceri aktariliyor: $($rf.Name)"
            $p = Start-Process -FilePath "reg.exe" -ArgumentList "import `"$($rf.FullName)`"" -Wait -PassThru -NoNewWindow
            if ($p.ExitCode -eq 0) {
                $restoredCount++
            }
        }
    }

    # Broadcast WM_SETTINGCHANGE so system refreshes environment
    try {
        Add-Type -Namespace Win32Rollback -Name NativeMethods -MemberDefinition @"
        [System.Runtime.InteropServices.DllImport("user32.dll", SetLastError = true, CharSet = System.Runtime.InteropServices.CharSet.Auto)]
        public static extern System.IntPtr SendMessageTimeout(
            System.IntPtr hWnd, uint Msg, System.UIntPtr wParam, string lParam, uint fuFlags, uint uTimeout, out System.UIntPtr lpdwResult);
"@ -ErrorAction SilentlyContinue
        $HWND_BROADCAST = [System.IntPtr]0xffff
        $WM_SETTINGCHANGE = 0x1a
        $res = [System.UIntPtr]::Zero
        [Win32Rollback.NativeMethods]::SendMessageTimeout($HWND_BROADCAST, $WM_SETTINGCHANGE, [System.UIntPtr]::Zero, "Environment", 2, 5000, [ref]$res) | Out-Null
    } catch {}

    Write-Output "[SUCCESS] Toplam $restoredCount adet kayit defteri bolumu geri yuklendi."
    return ($restoredCount -gt 0)
}

function Start-SystemRollbackWizard {
    Write-Output "[INFO] Windows Sistem Geri Yukleme Sihirbazi (rstrui.exe) baslatiliyor..."
    try {
        Start-Process "rstrui.exe"
        return $true
    } catch {
        Write-Output "[ERROR] rstrui.exe baslatilamadi: $_"
        return $false
    }
}

function Get-SnapshotList {
    try {
        return (Get-ComputerRestorePoint -ErrorAction SilentlyContinue | Sort-Object SequenceNumber -Descending)
    } catch {
        return @()
    }
}
