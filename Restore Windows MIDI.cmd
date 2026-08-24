@echo off
setlocal
set "FIX=%~dp0EQL-Audio-Fix.ps1"
if not exist "%FIX%" (
  echo Missing: %FIX%
  pause
  exit /b 1
)
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%FIX%" -Mode Recover
set "RC=%ERRORLEVEL%"
if not "%RC%"=="0" pause
endlocal & exit /b %RC%
