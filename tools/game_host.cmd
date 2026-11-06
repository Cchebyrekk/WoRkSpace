@echo off
rem PC VR games over the own link (slice q1): the game host next to the WoRkPlace
rem SteamVR driver. The headset app finds it like "the PC draws" (same ports), so
rem stop that mode and the link server first (tools\link_server_stop.cmd). Start
rem SteamVR yourself (with the WoRkPlace driver, tools\install_steamvr_driver.ps1).
rem Log: %LOCALAPPDATA%\WoRkPlace\game_host.log. Close its window to stop it.
if not exist "%LOCALAPPDATA%\WoRkPlace" mkdir "%LOCALAPPDATA%\WoRkPlace"
start "WoRkPlace games" /min cmd /c ""C:\Program Files (x86)\Steam\steamapps\common\Godot Engine\godot.windows.opt.tools.64.exe" --headless --xr-mode off --path "%~dp0.." --log-file "%LOCALAPPDATA%\WoRkPlace\game_host.log" res://scenes/game_host.tscn"
