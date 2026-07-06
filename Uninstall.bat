@echo off
title Tobii IS5 Watchdog - Uninstaller

:: --- self-elevate ---
net session >nul 2>&1
if %errorlevel% neq 0 (
    echo Requesting administrator permission...
    powershell -NoProfile -Command "Start-Process -Verb RunAs -FilePath '%~f0'"
    exit /b
)

echo.
echo ==== Tobii IS5 Eye Tracker Watchdog - Uninstall ====
echo.

set "UN=C:\Scripts\Uninstall-TobiiWatchdog.ps1"
if not exist "%UN%" set "UN=%~dp0Uninstall-TobiiWatchdog.ps1"
powershell -NoProfile -ExecutionPolicy Bypass -File "%UN%"

echo.
echo Removed the watchdog tasks and tray autostart.
echo (Left the copied scripts in C:\Scripts and the USB power tweak in place - both harmless.)
echo.
pause
