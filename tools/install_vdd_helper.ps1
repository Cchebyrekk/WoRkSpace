#Requires -RunAsAdministrator
# One-time setup, run by hand from an elevated PowerShell:
#   .\tools\install_vdd_helper.ps1            install or update
#   .\tools\install_vdd_helper.ps1 -Uninstall remove
#
# Copies vdd_helper.ps1 to Program Files (so an unelevated process cannot edit
# what later runs elevated) and registers a scheduled task that runs it with the
# highest privileges. The app starts that task instead of raising a UAC prompt,
# which could not be answered from inside the headset.
#
# Keep this file ASCII-only: Windows PowerShell 5.1 reads a BOM-less script as ANSI.
param([switch]$Uninstall)

$ErrorActionPreference = 'Stop'
$TaskName = 'WoRkPlaceVddHelper'
$InstallDir = Join-Path $env:ProgramFiles 'WoRkPlace'
$ExchangeDir = Join-Path $env:ProgramData 'WoRkPlace\vdd'
$Target = Join-Path $InstallDir 'vdd_helper.ps1'

if ($Uninstall) {
    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue
    if (Test-Path $Target) { Remove-Item $Target -Force }
    Write-Host "Removed task $TaskName and $Target."
    exit 0
}

New-Item -ItemType Directory -Force $InstallDir | Out-Null
New-Item -ItemType Directory -Force $ExchangeDir | Out-Null
Copy-Item (Join-Path $PSScriptRoot 'vdd_helper.ps1') $Target -Force

# The unelevated app has to write requests into the exchange directory.
$acl = Get-Acl $ExchangeDir
$users = New-Object System.Security.Principal.SecurityIdentifier('S-1-5-32-545')
$rule = New-Object System.Security.AccessControl.FileSystemAccessRule($users, 'Modify', 'ContainerInherit,ObjectInherit', 'None', 'Allow')
$acl.AddAccessRule($rule)
Set-Acl $ExchangeDir $acl

$action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument "-NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$Target`""
$principal = New-ScheduledTaskPrincipal -UserId ([System.Security.Principal.WindowsIdentity]::GetCurrent().Name) -LogonType Interactive -RunLevel Highest
$settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit (New-TimeSpan -Minutes 5)
Register-ScheduledTask -TaskName $TaskName -Action $action -Principal $principal -Settings $settings -Force | Out-Null

Write-Host "Done: helper copied to $Target, task $TaskName registered."
