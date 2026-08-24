@echo off
setlocal
set "FIX=%~dp0support\EQL-Audio-Fix.ps1"

if not exist "%FIX%" (
  echo Missing support file: %FIX%
  pause
  exit /b 1
)

echo Checking for an interrupted workaround transaction...
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%FIX%" -RecoverOnly
set "RC=%ERRORLEVEL%"

if not "%RC%"=="0" (
  echo.
  echo Recovery did not complete. Read the error above before changing Windows MIDI settings manually.
  pause
)

endlocal & exit /b %RC%
