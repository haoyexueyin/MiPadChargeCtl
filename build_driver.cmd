@echo off
setlocal
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Build-And-Sign.ps1"
exit /b %errorlevel%
