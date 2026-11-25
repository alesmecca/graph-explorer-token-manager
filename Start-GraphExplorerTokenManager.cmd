@echo off
where pwsh.exe >nul 2>nul
if errorlevel 1 (
  echo Installare PowerShell 7.4 o successivo: https://aka.ms/powershell
  pause
  exit /b 1
)
pwsh.exe -NoLogo -NoProfile -STA -File "%~dp0scripts\Start-TokenManager.ps1"
if errorlevel 1 pause
