@echo off
rem =========================================================================
rem  stop.bat - stops the IP rotator, disconnects the VPN and checks that your
rem  normal internet works again. The work is done by stop.ps1.
rem
rem  "-ExecutionPolicy Bypass" applies to this one PowerShell process only;
rem  your system's execution policy is never changed.
rem =========================================================================
title IP Rotator - Stop
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0stop.ps1"
echo.
pause
