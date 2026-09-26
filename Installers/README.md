# Offline Installers Directory

Place offline installation packages (`.exe`, `.msi`, `.msix`) into this folder.
The suite will automatically detect their installer type (MSI, InnoSetup, NSIS, InstallShield, WiX, Burn)
and run them silently during module `10_CustomOfflineInstallers.ps1`.

> Note: Heavy binaries are excluded from Git version control via `.gitignore`.
