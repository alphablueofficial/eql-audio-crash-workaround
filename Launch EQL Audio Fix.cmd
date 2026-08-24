@echo off
setlocal
set "FIX=%~dp0EQL-Audio-Fix.ps1"
if not exist "%FIX%" (
  echo Missing: %FIX%
  pause
  exit /b 1
)
set "EQL_AUDIO_FIX_SOURCE=%FIX%"
set "EQL_AUDIO_FIX_MODE=Launch"
if /I "%~1"=="--check-only" set "EQL_AUDIO_FIX_MODE=Check"
powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "$ErrorActionPreference='Stop'; $utf8=New-Object Text.UTF8Encoding($false,$true); $source=[IO.Path]::GetFullPath($env:EQL_AUDIO_FIX_SOURCE); $bytes=[IO.File]::ReadAllBytes($source); $algorithm=[Security.Cryptography.SHA256]::Create(); try{$hash=-join($algorithm.ComputeHash($bytes)|ForEach-Object{$_.ToString('x2')})}finally{$algorithm.Dispose()}; $global:EqlAudioFixTrustedBytes=$bytes; $block=[ScriptBlock]::Create($utf8.GetString($bytes)); & $block -Mode $env:EQL_AUDIO_FIX_MODE -ExpectedScriptSha256 $hash -TrustedSourcePath $source"
set "RC=%ERRORLEVEL%"
if not "%RC%"=="0" pause
endlocal & exit /b %RC%
