@echo off
setlocal

set "INTMUSIC_HOME=%~dp0"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%INTMUSIC_HOME%Start-IntMusic.ps1" -InstallDir "%INTMUSIC_HOME%"
