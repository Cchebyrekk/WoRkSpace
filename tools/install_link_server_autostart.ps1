# The link server starts by itself when the user signs in to Windows (slice o7).
# Branch all-modes: the watchdog runs what the chosen work mode needs (see link_server_watch.ps1).
# Run by hand once, no admin needed:
#   .\tools\install_link_server_autostart.ps1             install or update
#   .\tools\install_link_server_autostart.ps1 -Uninstall  remove again
#
# Registers the scheduled task WoRkPlaceLinkServer for the current user: at sign-in
# (after a short delay, so the network is up) it runs the hidden watchdog
# link_server_watch.ps1, the same that link_server.cmd starts. A task, not a
# shortcut in the Startup folder: files the Claude app writes under AppData are
# virtualized (MSIX) and Windows would not see such a shortcut (29.10.2026).
# Stop the server for this session with link_server_stop.cmd; the next sign-in
# starts it again.
#
# Keep this file ASCII-only: Windows PowerShell 5.1 reads a BOM-less script as ANSI.
param([switch]$Uninstall)

$ErrorActionPreference = 'Stop'
$TaskName = 'WoRkPlaceLinkServer'
$Watch = Join-Path $PSScriptRoot 'link_server_watch.ps1'
$User = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name

if ($Uninstall) {
    if (Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue) {
        Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
    }
    Write-Host "Removed task $TaskName (a running server stays; stop it with link_server_stop.cmd)."
    exit 0
}

if (-not (Test-Path $Watch)) { throw "$Watch not found" }
$action = New-ScheduledTaskAction -Execute 'powershell.exe' -WorkingDirectory (Split-Path -Parent $PSScriptRoot) `
    -Argument ('-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "' + $Watch + '"')
$trigger = New-ScheduledTaskTrigger -AtLogOn -User $User
$trigger.Delay = 'PT10S'
# No time limit (the default would end the server after 3 days), on battery too;
# a second start while the watchdog runs does nothing (it also holds a mutex).
$settings = New-ScheduledTaskSettingsSet -ExecutionTimeLimit ([TimeSpan]::Zero) -AllowStartIfOnBatteries `
    -DontStopIfGoingOnBatteries -MultipleInstances IgnoreNew -StartWhenAvailable
$principal = New-ScheduledTaskPrincipal -UserId $User -LogonType Interactive -RunLevel Limited
Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger -Settings $settings `
    -Principal $principal -Description 'WoRkPlace: link server for the headset app (tools\link_server_watch.ps1)' -Force | Out-Null
Write-Host "Task $TaskName registered: the link server starts at sign-in of $User."
