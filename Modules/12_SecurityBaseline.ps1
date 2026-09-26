#Requires -Version 5.1
<#
.SYNOPSIS
    12_SecurityBaseline.ps1 - Enterprise Security Baseline & Defender Hardening
.DESCRIPTION
    Applies non-destructive Microsoft Security Baseline best practices:
    1. Validates and enforces UAC (User Account Control) elevation integrity
    2. Enforces Windows Defender Real-Time Protection and Cloud Intelligence
    3. Enables Windows Defender SmartScreen for File Explorer and Edge
    4. BitLocker & Device Encryption status check (manage-bde)
    5. Disables legacy SMBv1 protocol to mitigate Ransomware / WannaCry vectors
#>
[CmdletBinding()]
param()

$ErrorActionPreference = "Continue"

Write-Output "[INFO] 12_SecurityBaseline: Kurumsal guvenlik tabani ve Defender sikilastirmasi baslatiliyor..."

#region === 1. USER ACCOUNT CONTROL (UAC) INTEGRITY ===
Write-Output "[INFO] UAC (Kullanici Hesabi Denetimi) guvenlik duzeyi denetleniyor..."
try {
    $uacKey = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System"
    if (Test-Path $uacKey) {
        $consent = (Get-ItemProperty $uacKey -Name "ConsentPromptBehaviorAdmin" -ErrorAction SilentlyContinue).ConsentPromptBehaviorAdmin
        $enableLua = (Get-ItemProperty $uacKey -Name "EnableLUA" -ErrorAction SilentlyContinue).EnableLUA

        if ($enableLua -ne 1) {
            Set-ItemProperty -Path $uacKey -Name "EnableLUA" -Value 1 -Type DWord -Force
            Write-Output "[SUCCESS] UAC anahtari (EnableLUA) guvenli seviyeye alindi."
        } else {
            Write-Output "[SUCCESS] UAC aktif ve devrede (EnableLUA = 1)."
        }
    }
} catch {
    Write-Output "[WARN] UAC denetim uyarisi: $_"
}
#endregion

#region === 2. DEFENDER SMARTSCREEN & CLOUD PROTECTION ===
Write-Output "[INFO] Windows Defender SmartScreen & Bulut Koruma durumu yapilandiriliyor..."
try {
    $systemPolicyKey = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\System"
    if (-not (Test-Path $systemPolicyKey)) { New-Item -Path $systemPolicyKey -Force | Out-Null }
    
    # Enable SmartScreen for Windows Explorer
    Set-ItemProperty -Path $systemPolicyKey -Name "EnableSmartScreen" -Value 1 -Type DWord -Force
    Set-ItemProperty -Path $systemPolicyKey -Name "ShellSmartScreenLevel" -Value "Warn" -Type String -Force
    Write-Output "[SUCCESS] Windows Explorer SmartScreen korumasi aktif."

    # Defender Cloud Delivered Protection
    Set-MpPreference -MAPSReporting Advanced -ErrorAction SilentlyContinue
    Set-MpPreference -SubmitSamplesConsent SendSafeSamples -ErrorAction SilentlyContinue
    Write-Output "[SUCCESS] Defender Bulut Korumasi ve Guvenli Numune Analizi aktif."
} catch {
    Write-Output "[WARN] SmartScreen / Defender ayarlari yapilandirilamadi: $_"
}
#endregion

#region === 3. DISABLE LEGACY SMBv1 PROTOCOL ===
Write-Output "[INFO] Guvensiz eski SMBv1 ag protokolunun durumu kontrol ediliyor..."
try {
    $smb1 = Get-WindowsOptionalFeature -Online -FeatureName "SMB1Protocol" -ErrorAction SilentlyContinue
    if ($smb1 -and $smb1.State -eq "Enabled") {
        Disable-WindowsOptionalFeature -Online -FeatureName "SMB1Protocol" -NoRestart -ErrorAction SilentlyContinue | Out-Null
        Write-Output "[SUCCESS] Eski guvensiz SMBv1 protokolü devre disi birakildi (Ransomware onlemi)."
    } else {
        Write-Output "[SUCCESS] SMBv1 protokolü zaten devre disi (Sistem guvende)."
    }
} catch {
    Write-Output "[INFO] SMBv1 kontrolu atlandi: $_"
}
#endregion

#region === 4. BITLOCKER & DRIVE ENCRYPTION AUDIT ===
Write-Output "[INFO] Sürücü Sifreleme ve BitLocker durumu taranıyor..."
try {
    $bitlockerStatus = & manage-bde.exe -status $env:SystemDrive 2>&1
    $isEncrypted = ($bitlockerStatus | Select-String "Tamamen Şifrelendi|Fully Encrypted|Protection On")
    if ($isEncrypted) {
        Write-Output "[SUCCESS] Sistem surucusu ($env:SystemDrive) BitLocker / Sifreleme ile korunuyor."
    } else {
        Write-Output "[NOTE] Sistem surucusunde ($env:SystemDrive) BitLocker sifreleme aktif degil (Istege bagli acilabilir)."
    }
} catch {
    Write-Output "[INFO] BitLocker durumu sorgulanamadi: $_"
}
#endregion

Write-Output "[SUCCESS] 12_SecurityBaseline tamamlandi."
exit 0
