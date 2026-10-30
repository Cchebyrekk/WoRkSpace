@echo off
rem Stops what the WoRkPlace watchdog runs (link_server.cmd, remote_render.cmd):
rem the link server and the PC app of the mode "the PC draws" (only those Godots),
rem and tells the watchdog not to start them again.
if not exist "%LOCALAPPDATA%\WoRkPlace" mkdir "%LOCALAPPDATA%\WoRkPlace"
echo stop> "%LOCALAPPDATA%\WoRkPlace\link_server.stop"
powershell -NoProfile -Command "Get-CimInstance Win32_Process -Filter \"Name like 'godot%%'\" | Where-Object { $_.CommandLine -like '*link_server.tscn*' -or $_.CommandLine -like '*remote_render.log*' } | ForEach-Object { Stop-Process -Id $_.ProcessId -Force }"
