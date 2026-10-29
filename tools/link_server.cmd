@echo off
rem The WoRkPlace link server for the headset app (slice o5): no VR, no window
rem of its own. Start it with a double click, or put a shortcut to it into the
rem Startup folder (shell:startup). Stop it with tools\link_server_stop.cmd.
rem Started without a console: a console window of its own got the focus after
rem a UAC prompt, and keys typed from the headset (Ctrl+C) closed the server
rem (29.10.2026). Its log: %APPDATA%\Godot\app_userdata\WoRkPlace\logs\godot.log
cd /d "%~dp0.."
start "" "C:\Program Files (x86)\Steam\steamapps\common\Godot Engine\godot.windows.opt.tools.64.exe" --headless --xr-mode off --path . res://scenes/link_server.tscn
