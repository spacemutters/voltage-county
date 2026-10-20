@echo off
rem Opens the published Voltage County place (cloud, Team Create) in Roblox Studio and starts the code sync.
rem After Studio loads: Plugins > Rojo > Connect.
cd /d "%~dp0.."
start "Voltage County - syncing to Studio" "%~dp0..\Sync to Studio.bat"
for /f "delims=" %%v in ('dir /b /ad /o-d "%LOCALAPPDATA%\Roblox\Versions\version-*"') do (
	if exist "%LOCALAPPDATA%\Roblox\Versions\%%v\RobloxStudioBeta.exe" (
		start "" "%LOCALAPPDATA%\Roblox\Versions\%%v\RobloxStudioBeta.exe" -task EditPlace -placeId 75289525823483 -universeId 10772006656
		goto :eof
	)
)
echo Roblox Studio not found.
pause
