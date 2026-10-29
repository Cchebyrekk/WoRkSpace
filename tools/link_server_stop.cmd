@echo off
rem Stops the WoRkPlace link server started by link_server.cmd (only that Godot).
powershell -NoProfile -Command "Get-CimInstance Win32_Process -Filter \"Name like 'godot%%'\" | Where-Object { $_.CommandLine -like '*link_server.tscn*' } | ForEach-Object { Stop-Process -Id $_.ProcessId -Force }"
