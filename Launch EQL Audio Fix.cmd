@echo off
setlocal
set "FIX=%~dp0support\EQL-Audio-Fix.ps1"

if not exist "%FIX%" (
  echo Missing support file: %FIX%
  pause
  exit /b 1
)

echo Checking compatibility and rollback safety...
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%FIX%" -SelfTest
if errorlevel 1 goto :failed

powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%FIX%" -DryRun
if errorlevel 1 goto :failed

if /I "%~1"=="--check-only" (
  echo.
  echo Compatibility and safety checks passed. No settings were changed.
  endlocal
  exit /b 0
)

echo.
echo Opening the official EQL LaunchPad. Approve UAC, then click PLAY.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%FIX%"
if errorlevel 1 goto :failed

endlocal
exit /b 0

:failed
echo.
echo The workaround stopped safely. No unverified registry state was accepted.
echo See the error above and README.md.
pause
endlocal
exit /b 1
