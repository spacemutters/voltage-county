@echo off
rem Keeps Roblox Studio in sync with this folder.
rem Leave this window open, then in Studio click Plugins > Rojo > Connect.
title Voltage County - syncing to Studio
cd /d "%~dp0"
set "PATH=%USERPROFILE%\.rokit\bin;%PATH%"
if not exist Packages wally install
rojo serve
pause
