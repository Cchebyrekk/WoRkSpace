@echo off
rem The WoRkPlace link server for the headset app (slice o5): no VR, no window
rem of its own. Start it with a double click, or put a shortcut to it into the
rem Startup folder (shell:startup). Close this window to stop it.
title WoRkPlace link server
cd /d "%~dp0.."
"C:\Program Files (x86)\Steam\steamapps\common\Godot Engine\godot.windows.opt.tools.64.exe" --headless --xr-mode off --path . res://scenes/link_server.tscn
