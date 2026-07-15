@echo off
setlocal
chcp 65001 >nul
title Device Log Capture - HAR e Console
cd /d "%~dp0"
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0DeviceLogCapture.ps1"
set "EXIT_CODE=%ERRORLEVEL%"
exit /b %EXIT_CODE%
