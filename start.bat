@echo off
rem =========================================================================
rem  start.bat - double-click to start changing your public IP.
rem  Asks how often to change it, then runs the rotator as a hidden background
rem  process. Closing this window or pressing Ctrl+C afterwards does NOT stop
rem  it; use stop.bat for that. The first run downloads Tor automatically.
rem
rem  From a terminal you can skip the questions:
rem      start.bat 300       change IP every 300 seconds
rem      start.bat 300 2     ... and stop by itself after 2 hours
rem
rem  "-ExecutionPolicy Bypass" applies to this one PowerShell process only;
rem  your system's execution policy is never changed.
rem =========================================================================
title IP Rotator - Start
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0start.ps1" %*
if not "%~1"=="" exit /b %ERRORLEVEL%
echo.
pause
