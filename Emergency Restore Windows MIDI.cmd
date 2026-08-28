@echo off
setlocal
set "FIX=%~dp0EQL-Audio-Fix.ps1"
if not exist "%FIX%" (
  echo Missing: %FIX%
  pause
  exit /b 1
)
set "EQL_AUDIO_FIX_SOURCE=%FIX%"
set "EQL_AUDIO_FIX_MODE=Recover"
set "POWERSHELL=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
if defined PROCESSOR_ARCHITEW6432 set "POWERSHELL=%SystemRoot%\Sysnative\WindowsPowerShell\v1.0\powershell.exe"
if not exist "%POWERSHELL%" (
  echo Required 64-bit Windows PowerShell was not found: %POWERSHELL%
  pause
  exit /b 1
)
"%POWERSHELL%" -NoProfile -ExecutionPolicy Bypass -Command "$ErrorActionPreference='Stop'; $utf8=New-Object Text.UTF8Encoding($false,$true); $source=[IO.Path]::GetFullPath($env:EQL_AUDIO_FIX_SOURCE); $bytes=[IO.File]::ReadAllBytes($source); $algorithm=[Security.Cryptography.SHA256]::Create(); try{$hash=-join($algorithm.ComputeHash($bytes)|ForEach-Object{$_.ToString('x2')})}finally{$algorithm.Dispose()}; $global:EqlAudioFixTrustedBytes=$bytes; $block=[ScriptBlock]::Create($utf8.GetString($bytes)); & $block -Mode $env:EQL_AUDIO_FIX_MODE -ExpectedScriptSha256 $hash -TrustedSourcePath $source"
set "RC=%ERRORLEVEL%"
if not "%RC%"=="0" pause
endlocal & exit /b %RC%
