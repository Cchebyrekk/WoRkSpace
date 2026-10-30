@echo off
rem The WoRkPlace link server for the headset app (slice o5): no VR, no window
rem of its own. Start it with a double click; at every sign-in after
rem tools\install_link_server_autostart.ps1 (slice o7). Stop it with tools\link_server_stop.cmd.
rem No console: a console window of its own got the focus after a UAC prompt,
rem and keys typed from the headset (Ctrl+C) closed the server (29.10.2026).
rem Branch all-modes: chooses the work mode "world in the headset" (1) for the
rem hidden watchdog (link_server_watch.ps1, its log
rem %LOCALAPPDATA%\WoRkPlace\link_server_watch.log), which starts it again if it ends
rem and stops what ran for another mode.
rem The server's log: %APPDATA%\Godot\app_userdata\WoRkPlace\logs\godot.log
start "" powershell -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "%~dp0link_server_watch.ps1" -Mode 1
