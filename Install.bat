@echo off
setlocal enabledelayedexpansion
title Tobii IS5 Watchdog - Installer

:: --- self-elevate (needs admin to register tasks / change USB power) ---
net session >nul 2>&1
if %errorlevel% neq 0 (
    echo Requesting administrator permission...
    powershell -NoProfile -Command "Start-Process -Verb RunAs -FilePath '%~f0'"
    exit /b
)

echo.
echo ==== Tobii IS5 Eye Tracker Watchdog - Install ====
echo.

:: --- copy the tool into C:\Scripts (where the scripts expect to live) ---
if /I not "%~dp0"=="C:\Scripts\" (
    if not exist "C:\Scripts" mkdir "C:\Scripts"
    echo Copying files to C:\Scripts ...
    for %%F in (Tobii-Watchdog.ps1 Tobii-Monitor.ps1 Tobii-Tray.ps1 Tobii-Tray.vbs Install-TobiiWatchdog.ps1 Uninstall-TobiiWatchdog.ps1 FINDINGS.md) do (
        if exist "%~dp0%%F" copy /Y "%~dp0%%F" "C:\Scripts\%%F" >nul
    )
)

:: --- run the PowerShell installer ---
powershell -NoProfile -ExecutionPolicy Bypass -File "C:\Scripts\Install-TobiiWatchdog.ps1"

echo.
echo ==== Done. Look for a GREEN dot near your clock (system tray). ====
echo Right-click it for: Reconnect now / Pause / Health report.
echo.
pause
