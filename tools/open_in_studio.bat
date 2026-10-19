@echo off
rem Builds the place file from this folder and opens it in Roblox Studio (no start page, no dialogs).
cd /d "%~dp0.."
set "PATH=%USERPROFILE%\.rokit\bin;%PATH%"
if not exist Packages wally install
if not exist build mkdir build
rojo build -o build\VoltageCounty.rbxl
for /f "delims=" %%v in ('dir /b /ad /o-d "%LOCALAPPDATA%\Roblox\Versions\version-*"') do (
	if exist "%LOCALAPPDATA%\Roblox\Versions\%%v\RobloxStudioBeta.exe" (
		start "" "%LOCALAPPDATA%\Roblox\Versions\%%v\RobloxStudioBeta.exe" -task EditFile -localPlaceFile "%CD%\build\VoltageCounty.rbxl"
		goto :eof
	)
)
echo Roblox Studio not found.
pause
