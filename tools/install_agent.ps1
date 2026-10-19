#Requires -RunAsAdministrator
# One-time setup, run by hand from an elevated PowerShell (outside VR):
#   .\tools\install_agent.ps1                 install or update
#   .\tools\install_agent.ps1 -Uninstall      remove everything again
#   -AllowedClient <exe>                      the program that may use the agent
#                                             (default: Godot from Steam)
#
# Installs the WoRkPlaceAgent service. It runs bin\workplace_agent.exe as SYSTEM
# in the console user's session, so that the app's clicks and keys reach elevated
# windows and the secure desktop (UAC prompts, the lock screen, Ctrl+Alt+Del).
# The exe is copied to Program Files: what runs as SYSTEM must not be writable by
# a normal user. Only the allowed program may connect (registry
# HKLM\SOFTWARE\WoRkPlace\Agent\AllowedClients).
#
# Keep this file ASCII-only: Windows PowerShell 5.1 reads a BOM-less script as ANSI.
param(
    [switch]$Uninstall,
    [string]$AllowedClient = 'C:\Program Files (x86)\Steam\steamapps\common\Godot Engine\godot.windows.opt.tools.64.exe'
)

$ErrorActionPreference = 'Stop'
$ServiceName = 'WoRkPlaceAgent'
$InstallDir = Join-Path $env:ProgramFiles 'WoRkPlace'
$Target = Join-Path $InstallDir 'workplace_agent.exe'
$Source = Join-Path $PSScriptRoot '..\bin\workplace_agent.exe'
$LogDir = Join-Path $env:ProgramData 'WoRkPlace\agent'
$RegistryKey = 'HKLM:\SOFTWARE\WoRkPlace\Agent'

function Stop-Agent {
    if (Get-Service $ServiceName -ErrorAction SilentlyContinue) {
        Stop-Service $ServiceName -Force -ErrorAction SilentlyContinue
    }
    # Also any agent started by hand (it would hold the pipe name).
    Get-Process workplace_agent -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
    Start-Sleep -Milliseconds 500
}

if ($Uninstall) {
    Stop-Agent
    if (Get-Service $ServiceName -ErrorAction SilentlyContinue) { & sc.exe delete $ServiceName | Out-Null }
    if (Test-Path $Target) { Remove-Item $Target -Force }
    if (Test-Path $RegistryKey) { Remove-Item $RegistryKey -Recurse -Force }
    Write-Host "Removed service $ServiceName, $Target and $RegistryKey."
    exit 0
}

if (-not (Test-Path $Source)) { throw "$Source not found: build the native module first (see CLAUDE.md)" }
if (-not (Test-Path $AllowedClient)) { throw "$AllowedClient not found: pass -AllowedClient <path to the Godot exe>" }

Stop-Agent
New-Item -ItemType Directory -Force $InstallDir | Out-Null
Copy-Item $Source $Target -Force

# The log folder is written by SYSTEM: admins and SYSTEM only (a folder a user can
# write into would let them redirect SYSTEM's writes with a link). Users may read.
if (Test-Path $LogDir) { Remove-Item $LogDir -Recurse -Force }
New-Item -ItemType Directory -Force $LogDir | Out-Null
$acl = New-Object System.Security.AccessControl.DirectorySecurity
$acl.SetAccessRuleProtection($true, $false)
$inherit = 'ContainerInherit,ObjectInherit'
foreach ($entry in @(@('S-1-5-18', 'FullControl'), @('S-1-5-32-544', 'FullControl'), @('S-1-5-32-545', 'ReadAndExecute'))) {
    $sid = New-Object System.Security.Principal.SecurityIdentifier($entry[0])
    $acl.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule($sid, $entry[1], $inherit, 'None', 'Allow')))
}
Set-Acl $LogDir $acl

New-Item -Path $RegistryKey -Force | Out-Null
New-ItemProperty -Path $RegistryKey -Name 'AllowedClients' -PropertyType MultiString -Value @($AllowedClient) -Force | Out-Null

if (-not (Get-Service $ServiceName -ErrorAction SilentlyContinue)) {
    New-Service -Name $ServiceName -BinaryPathName "`"$Target`" --service" -DisplayName 'WoRkPlace input agent' `
        -Description 'Lets the WoRkPlace VR app click elevated windows and the secure desktop (UAC, lock screen).' -StartupType Automatic | Out-Null
}
# Restart after a crash: 5 s, 5 s, then 30 s; the failure count resets after a day.
& sc.exe failure $ServiceName reset= 86400 actions= restart/5000/restart/5000/restart/30000 | Out-Null
Start-Service $ServiceName
Start-Sleep -Seconds 2

$agents = @(Get-CimInstance Win32_Process -Filter "Name = 'workplace_agent.exe'" | Where-Object { $_.CommandLine -like '*--agent*' })
Write-Host "Done: service $ServiceName is $((Get-Service $ServiceName).Status), agent processes: $($agents.Count)."
Write-Host "Allowed client: $AllowedClient"
Write-Host "Log: $LogDir\agent.log"
