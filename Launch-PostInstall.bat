@echo off
setlocal EnableDelayedExpansion
title Computer Maintenance Pro Launcher v4.0

:: Yonetici Yetkisi Kontrolu
net session >nul 2>&1
if %errorLevel% neq 0 (
    echo [BILGI] Yonetici haklari talep ediliyor...
    powershell -Command "Start-Process cmd.exe -ArgumentList '/c \"\"%~f0\" %*\"' -Verb RunAs"
    exit /b
)

:: Yonetici olarak calisiyor - Script dizinine konumlan
cd /d "%~dp0"

start "" powershell.exe -NoProfile -Sta -ExecutionPolicy Bypass -File "%~dp0PostInstallUI.ps1" %*
exit /b 0
