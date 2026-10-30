@echo off
rem Branch pc-render: the PC app draws the headset's eyes itself and streams them
rem to the headset app (headset/src/player.gd), which sends back its poses.
rem --xr-mode on: Godot builds its two-eye shaders only then; without Quest Link
rem OpenXR fails at once and stays out of the way (keep Link off).
rem Log: %LOCALAPPDATA%\WoRkPlace\remote_render.log (not godot.log: the link server writes that one)
rem The SYSTEM agent (admin windows, UAC) serves one program at a time: the link
rem server of the main branch holds it if it runs, so stop it first (it comes back
rem with tools\link_server.cmd or at the next sign-in).
call "%~dp0link_server_stop.cmd"
timeout /t 1 /nobreak >nul
set WORKPLACE_REMOTE=1
start "" "C:\Program Files (x86)\Steam\steamapps\common\Godot Engine\godot.windows.opt.tools.64.exe" --xr-mode on --log-file "%LOCALAPPDATA%\WoRkPlace\remote_render.log" --path "%~dp0.."
