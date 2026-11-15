@echo off
cd /d "%~dp0.."
powershell.exe -NoProfile -WindowStyle Hidden -Command "Start-Process py.exe -WindowStyle Hidden -WorkingDirectory (Get-Location).Path -ArgumentList '-3.12','-m','internet.desktop'"
