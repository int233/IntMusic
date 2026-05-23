@echo off
setlocal

set "INTMUSIC_HOME=%~dp0"
set "INTMUSIC_CLIENT=%INTMUSIC_HOME%client\IntMusic.exe"

sc start IntMusicCore >nul 2>nul

if exist "%INTMUSIC_CLIENT%" (
  start "" "%INTMUSIC_CLIENT%"
) else (
  echo IntMusic client was not found at "%INTMUSIC_CLIENT%".
  pause
)
