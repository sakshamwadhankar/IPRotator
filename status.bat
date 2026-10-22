@echo off
rem =========================================================================
rem  status.bat - shows whether the rotator is running, the interval, your
rem  current public IP, the server in use, the time until the next switch and
rem  the last 10 log lines. The work is done by status.ps1.
rem
rem  "-ExecutionPolicy Bypass" applies to this one PowerShell process only;
rem  your system's execution policy is never changed.
rem =========================================================================
title IP Rotator - Status
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0status.ps1"
echo.
pause
