@echo off
rem The WoRkPlace link server for the headset app (slice o5): no VR, no window
rem of its own. Start it with a double click, or put a shortcut to it into the
rem Startup folder (shell:startup). Stop it with tools\link_server_stop.cmd.
rem No console: a console window of its own got the focus after a UAC prompt,
rem and keys typed from the headset (Ctrl+C) closed the server (29.10.2026).
rem A hidden watchdog starts it again if it ends (slice o6, link_server_watch.ps1,
rem its log %LOCALAPPDATA%\WoRkPlace\link_server_watch.log).
rem The server's log: %APPDATA%\Godot\app_userdata\WoRkPlace\logs\godot.log
start "" powershell -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "%~dp0link_server_watch.ps1"
