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
Copy-Item (Join-Path $PSScriptRoot 'vdd_helper.ps1') $Target -Force

# Folders the elevated helper writes into must not be replaceable by a user (a
# junction would redirect its writes): owned by administrators, with only the
# rights listed here. Any process can create folders in ProgramData, so an
# existing one is taken over and reset rather than trusted.
$system = New-Object System.Security.Principal.SecurityIdentifier('S-1-5-18')
$admins = New-Object System.Security.Principal.SecurityIdentifier('S-1-5-32-544')
$users = New-Object System.Security.Principal.SecurityIdentifier('S-1-5-32-545')
function New-Rule($who, $rights, $inherit, $propagate) {
    New-Object System.Security.AccessControl.FileSystemAccessRule($who, $rights, $inherit, $propagate, 'Allow')
}
function Set-Folder([string]$Path, $extraRules) {
    $item = Get-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
    if ($null -ne $item -and ($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint)) {
        # Removes the link itself; Remove-Item in PowerShell 5.1 may walk into its target.
        [System.IO.Directory]::Delete($Path)
    }
    New-Item -ItemType Directory -Force $Path | Out-Null
    $acl = New-Object System.Security.AccessControl.DirectorySecurity
    $acl.SetOwner($admins)
    $acl.SetAccessRuleProtection($true, $false)
    $acl.AddAccessRule((New-Rule $system 'FullControl' 'ContainerInherit,ObjectInherit' 'None'))
    $acl.AddAccessRule((New-Rule $admins 'FullControl' 'ContainerInherit,ObjectInherit' 'None'))
    foreach ($rule in $extraRules) { $acl.AddAccessRule($rule) }
    Set-Acl -LiteralPath $Path $acl
}
$parent = Split-Path $ExchangeDir
Set-Folder $parent @((New-Rule $users 'ReadAndExecute' 'ContainerInherit,ObjectInherit' 'None'))
# Exchange: users may list the folder, create files in it and change or delete the
# files (request.txt, response.txt), but not rename, delete or re-point the folder.
Set-Folder $ExchangeDir @(
    (New-Rule $users 'ReadAndExecute, CreateFiles' 'None' 'None'),
    (New-Rule $users 'Modify' 'ObjectInherit' 'InheritOnly'))
foreach ($name in 'request.txt', 'response.txt', 'helper.log') {
    Remove-Item -LiteralPath (Join-Path $ExchangeDir $name) -Force -ErrorAction SilentlyContinue
}
# Log: only administrators write, users read.
Set-Folder (Join-Path $parent 'vdd-log') @((New-Rule $users 'ReadAndExecute' 'ContainerInherit,ObjectInherit' 'None'))

$action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument "-NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$Target`""
$principal = New-ScheduledTaskPrincipal -UserId ([System.Security.Principal.WindowsIdentity]::GetCurrent().Name) -LogonType Interactive -RunLevel Highest
$settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit (New-TimeSpan -Minutes 5)
Register-ScheduledTask -TaskName $TaskName -Action $action -Principal $principal -Settings $settings -Force | Out-Null

Write-Host "Done: helper copied to $Target, task $TaskName registered."
