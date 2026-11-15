# Registers the WoRkPlace SteamVR driver (slice q1: PC VR games over the own link)
# with SteamVR: vrpathreg adddriver native\steamvr_driver\workplace (built by SCons
# in native\). -Uninstall removes it. Close SteamVR first.
# Another headset driver (ALVR) stays registered: turn it off in SteamVR
# (Settings > Startup/Shutdown > Manage add-ons), else SteamVR may pick that one.
param([switch]$Uninstall)

$ErrorActionPreference = 'Stop'
$driver = (Resolve-Path (Join-Path $PSScriptRoot '..\native\steamvr_driver\workplace')).Path
$paths = Join-Path $env:LOCALAPPDATA 'openvr\openvrpaths.vrpath'
if (-not (Test-Path $paths)) {
    throw "SteamVR is not set up ($paths not found): start SteamVR once"
}
$runtime = (Get-Content $paths -Raw | ConvertFrom-Json).runtime[0]
$vrpathreg = Join-Path $runtime 'bin\win64\vrpathreg.exe'
if (-not (Test-Path $vrpathreg)) {
    throw "vrpathreg.exe not found in $runtime"
}
if (Get-Process vrserver -ErrorAction SilentlyContinue) {
    Write-Warning 'SteamVR is running: the change takes effect after it restarts'
}
if ($Uninstall) {
    & $vrpathreg removedriver $driver
    Write-Output "removed: $driver"
} else {
    if (-not (Test-Path (Join-Path $driver 'bin\win64\driver_workplace.dll'))) {
        throw 'driver_workplace.dll is not built (py -3.12 -m SCons ... in native\)'
    }
    & $vrpathreg adddriver $driver
    Write-Output "registered: $driver"
}
& $vrpathreg show
