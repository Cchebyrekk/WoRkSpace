# q3: owned by link_server_watch.ps1. ASCII, Windows PowerShell 5.1.
$ErrorActionPreference = 'Stop'
$Root = Split-Path -Parent $PSScriptRoot
$Dir = Join-Path $env:LOCALAPPDATA 'WoRkPlace'
$ModeFile = Join-Path $Dir 'work_mode.txt'
$StopFile = Join-Path $Dir 'link_server.stop'
$Godot = 'C:\Program Files (x86)\Steam\steamapps\common\Godot Engine\godot.windows.opt.tools.64.exe'
$Adb = 'C:\Android\Sdk\platform-tools\adb.exe'
$hostProcess = $null
function Write-SessionLog([string]$message) {
    Add-Content (Join-Path $Dir 'game_session.log') ((Get-Date).ToString('s')+' '+$message)
}
function In-Games {
    return (!(Test-Path $StopFile) -and (Get-Content $ModeFile -ErrorAction SilentlyContinue | Select-Object -First 1) -eq '3')
}
function Reverse-Usb {
	if (!(In-Games)) { return }
    if (!(Test-Path $Adb)) { return }
    foreach ($line in ((Adb-Call 'devices') -split "`n")) {
        if ($line.Trim() -match '^([A-Za-z0-9_-]+)\s+device$') {
            $serial = $Matches[1]
            foreach ($port in @(47902,47903,47920)) {
				if (!(In-Games)) { return }
                Adb-Call "-s $serial reverse tcp:$port tcp:$port" | Out-Null
            }
        }
    }
}
function Adb-Call([string]$arguments) {
    $p = New-Object System.Diagnostics.Process
    $p.StartInfo.FileName = $Adb
    $p.StartInfo.Arguments = $arguments
    $p.StartInfo.UseShellExecute = $false
    $p.StartInfo.CreateNoWindow = $true
    $p.StartInfo.RedirectStandardOutput = $true
    $p.StartInfo.RedirectStandardError = $true
    try {
        $null = $p.Start()
        if (!$p.WaitForExit(3000)) { $p.Kill(); return '' }
        return $p.StandardOutput.ReadToEnd()
    } finally { $p.Dispose() }
}
try {
    Write-SessionLog 'Starting game host and SteamVR'
    $hostProcess = Start-Process $Godot -WorkingDirectory $Root -WindowStyle Hidden -PassThru `
        -ArgumentList '--headless','--xr-mode','off','--path',('"'+$Root+'"'),'--log-file',('"'+(Join-Path $Dir 'game_host.log')+'"'),'res://scenes/game_host.tscn'
    $paths = Get-Content (Join-Path $env:LOCALAPPDATA 'openvr\openvrpaths.vrpath') -Raw | ConvertFrom-Json
    $startup = Join-Path $paths.runtime[0] 'bin\win64\vrstartup.exe'
    if (!(Get-Process vrserver -ErrorAction SilentlyContinue)) { Start-Process $startup -WindowStyle Hidden }
    $deadline = (Get-Date).AddSeconds(45)
    while ((In-Games) -and !(Get-Process vrserver -ErrorAction SilentlyContinue) -and (Get-Date) -lt $deadline) { Start-Sleep 1 }
    Write-SessionLog 'SteamVR process started; waiting for driver/video is logged by game_host'
    $nextUsb = Get-Date
    while (In-Games) {
        if ($hostProcess.HasExited -or !(Get-Process vrserver -ErrorAction SilentlyContinue)) { break }
        if ((Get-Date) -ge $nextUsb) { Reverse-Usb; $nextUsb = (Get-Date).AddSeconds(5) }
        Start-Sleep 1
    }
} catch {
    Add-Content (Join-Path $Dir 'game_session.log') ((Get-Date).ToString('s')+' '+$_.Exception.Message)
} finally {
    if ($hostProcess -and !$hostProcess.HasExited) { Stop-Process -Id $hostProcess.Id -Force -ErrorAction SilentlyContinue }
    Write-SessionLog 'Session ended; returning to selected mode'
    # Only this mode owns the WoRkPlace SteamVR session. Leave other modes alone.
    Get-Process vrmonitor,vrserver,vrcompositor,vrstartup -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
    if ((Get-Content $ModeFile -ErrorAction SilentlyContinue | Select-Object -First 1) -eq '3') {
        $previous = Get-Content (Join-Path $Dir 'before_games.txt') -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($previous -notmatch '^[0-2]$') { $previous = '1' }
        Set-Content $ModeFile $previous -Encoding ASCII
    }
}
