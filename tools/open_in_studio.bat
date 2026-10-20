@echo off
rem Opens the Voltage County place in Roblox Studio (no start page, no dialogs).
rem The place file is built from this folder only the first time. After that it is just opened, because it
rem also holds what Studio owns (the map, the car models, the test track) and a rebuild would wipe those.
rem Code reaches Studio through Rojo: keep "Sync to Studio.bat" running and connect the Rojo plugin.
cd /d "%~dp0.."
set "PATH=%USERPROFILE%\.rokit\bin;%PATH%"
if not exist Packages wally install
if not exist build mkdir build
if not exist build\VoltageCounty.rbxl rojo build -o build\VoltageCounty.rbxl
for /f "delims=" %%v in ('dir /b /ad /o-d "%LOCALAPPDATA%\Roblox\Versions\version-*"') do (
	if exist "%LOCALAPPDATA%\Roblox\Versions\%%v\RobloxStudioBeta.exe" (
		start "" "%LOCALAPPDATA%\Roblox\Versions\%%v\RobloxStudioBeta.exe" -task EditFile -localPlaceFile "%CD%\build\VoltageCounty.rbxl"
		goto :eof
	)
)
echo Roblox Studio not found.
pause
