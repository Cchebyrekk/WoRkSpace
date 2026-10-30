@echo off
rem Work mode "the PC draws" (2, branch pc-render): the PC app draws the headset's
rem eyes itself and streams them to the headset app (headset/src/player.gd), which
rem sends back its poses. Run by the hidden watchdog (link_server_watch.ps1): it
rem starts the app with WORKPLACE_REMOTE and --xr-mode on, again if it ends, and
rem stops the link server first (the SYSTEM agent serves one program at a time).
rem Keep Quest Link off. Stop with tools\link_server_stop.cmd.
rem Log: %LOCALAPPDATA%\WoRkPlace\remote_render.log (not godot.log: the link server writes that one)
start "" powershell -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "%~dp0link_server_watch.ps1" -Mode 2
