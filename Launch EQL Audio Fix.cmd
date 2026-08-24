@echo off
setlocal
set "FIX=%~dp0EQL-Audio-Fix.ps1"
if not exist "%FIX%" (
  echo Missing: %FIX%
  pause
  exit /b 1
)
set "MODE=Launch"
if /I "%~1"=="--check-only" set "MODE=Check"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%FIX%" -Mode %MODE%
set "RC=%ERRORLEVEL%"
if not "%RC%"=="0" pause
endlocal & exit /b %RC%
