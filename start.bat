@echo off
rem =========================================================================
rem  start.bat - double-click to start changing your public IP.
rem  Asks how often to switch, then starts the rotator as a hidden background
rem  process. Closing this window or pressing Ctrl+C afterwards does NOT stop
rem  it; use stop.bat for that. The questions are handled by start.ps1.
rem
rem  "-ExecutionPolicy Bypass" applies to this one PowerShell process only;
rem  your system's execution policy is never changed.
rem =========================================================================
title IP Rotator - Start
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0start.ps1"
echo.
pause
