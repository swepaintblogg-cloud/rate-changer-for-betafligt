@echo off
cd /d "%~dp0"
if not exist "%~dp0Start.ps1" (
  echo Packa upp hela ZIP-filen med Extrahera alla och starta sedan igen.
  pause
  exit /b 1
)
"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -STA -ExecutionPolicy Bypass -File "%~dp0Start.ps1"
if errorlevel 1 pause
