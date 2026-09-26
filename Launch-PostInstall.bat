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
echo ======================================================================
echo   Computer Maintenance Pro - Enterprise System Care Suite v4.0
echo ======================================================================
echo [BILGI] Uygulama baslatiliyor, lutfen bekleyin...
echo.

if exist "%~dp0PostInstall.exe" (
    "%~dp0PostInstall.exe" %*
) else (
    powershell.exe -NoProfile -Sta -ExecutionPolicy Bypass -File "%~dp0PostInstallUI.ps1" %*
)

if %errorLevel% neq 0 (
    echo.
    echo [HATA] Uygulama cikis kodu ile sonlandi: %errorLevel%
    echo Sorun gidermek icin herhangi bir tusa basin...
    pause >nul
)

exit /b %errorLevel%
