# Select SteamVR for OpenXR games started outside WoRkPlace. Run as administrator.
# -Restore restores only the saved ActiveRuntime value, not the whole registry key.
param([switch]$Restore)
$ErrorActionPreference = 'Stop'
$key = 'HKLM:\SOFTWARE\Khronos\OpenXR\1'
$dir = Join-Path $env:LOCALAPPDATA 'WoRkPlace'
$backup = Join-Path $dir 'openxr_runtime_before.json'
New-Item -ItemType Directory -Force $dir | Out-Null
if ($Restore) {
    $saved = Get-Content $backup -Raw | ConvertFrom-Json
    Set-ItemProperty -Path $key -Name ActiveRuntime -Value ([string]$saved.runtime)
} else {
    $paths = Get-Content (Join-Path $env:LOCALAPPDATA 'openvr\openvrpaths.vrpath') -Raw | ConvertFrom-Json
    $runtime = Join-Path $paths.runtime[0] 'steamxr_win64.json'
    if (!(Test-Path $runtime)) { throw 'SteamVR OpenXR manifest not found' }
    $previous = [string](Get-ItemProperty $key -Name ActiveRuntime).ActiveRuntime
    if (!(Test-Path $backup) -and $previous -ne $runtime) {
        @{runtime=$previous} | ConvertTo-Json | Set-Content $backup -Encoding UTF8
    }
    Set-ItemProperty -Path $key -Name ActiveRuntime -Value $runtime
}
Write-Output ([string](Get-ItemProperty $key -Name ActiveRuntime).ActiveRuntime)
