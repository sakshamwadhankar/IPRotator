@echo off
rem =========================================================================
rem  setup.bat - one-time setup: checks Windows and OpenVPN GUI, creates the
rem  configs folder, unblocks the scripts, saves your Proton OpenVPN
rem  credentials and creates Desktop shortcuts. The work is done by setup.ps1.
rem
rem  "-ExecutionPolicy Bypass" applies to this one PowerShell process only;
rem  your system's execution policy is never changed.
rem =========================================================================
title IP Rotator - Setup
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0setup.ps1"
echo.
pause
