# The WoRkPlace PC watchdog (slice o6; branch all-modes, 30.10.2026), started
# hidden by link_server.cmd, remote_render.cmd, the autostart task and the app
# itself when it switches modes. It runs what the chosen work mode needs and
# starts it again when it ends, until link_server_stop.cmd leaves the stop file:
#   work_mode.txt 1 (world in the headset): the link server (Godot, headless)
#   work_mode.txt 2 (the PC draws):         the PC app with WORKPLACE_REMOTE
#   work_mode.txt 0 (OpenXR on the PC):     nothing; the app is started by hand
# The file is %LOCALAPPDATA%\WoRkPlace\work_mode.txt (src/work_mode.gd). When it
# changes, what runs gets a few seconds to end by itself, then it is stopped:
# only one may run, the SYSTEM agent serves one program at a time.
# 29.10.2026 the server ended while the user worked and every screen in the
# headset was gone until it was started by hand.
#
# -Mode N writes the file first (a watchdog already running picks it up).
#
# Keep this file ASCII-only: Windows PowerShell 5.1 reads a BOM-less script as ANSI.
param([int]$Mode = -1)

$Godot = 'C:\Program Files (x86)\Steam\steamapps\common\Godot Engine\godot.windows.opt.tools.64.exe'
$Root = Split-Path -Parent $PSScriptRoot
$Dir = Join-Path $env:LOCALAPPDATA 'WoRkPlace'
$StopFile = Join-Path $Dir 'link_server.stop'
$ModeFile = Join-Path $Dir 'work_mode.txt'
$Log = Join-Path $Dir 'link_server_watch.log'
$RemoteLog = Join-Path $Dir 'remote_render.log'
New-Item -ItemType Directory -Force -Path $Dir | Out-Null

function Write-Log([string]$text) {
    Add-Content -Path $Log -Value ((Get-Date -Format 'dd.MM HH:mm:ss') + ' ' + $text)
}

# Without the file: the link server, as before there were modes.
function Read-Mode {
    try {
        $text = (Get-Content -Path $ModeFile -TotalCount 1 -ErrorAction Stop).Trim()
        if ($text -match '^[0-2]$') { return [int]$text }
    } catch {}
    return 1
}

if ($Mode -ge 0 -and $Mode -le 2) {
    Set-Content -Path $ModeFile -Value $Mode -Encoding ASCII
}

# One watchdog at a time: a second start does nothing (beyond -Mode).
$mutex = New-Object System.Threading.Mutex($false, 'Local\WoRkPlaceLinkServerWatch')
if (-not $mutex.WaitOne(0)) { exit }
Remove-Item -Force -ErrorAction SilentlyContinue $StopFile

function Start-ForMode([int]$mode) {
    if ($mode -eq 1) {
        return Start-Process -FilePath $Godot -WorkingDirectory $Root -PassThru `
            -ArgumentList '--headless', '--xr-mode', 'off', '--path', ('"' + $Root + '"'), 'res://scenes/link_server.tscn'
    }
    # --xr-mode on: Godot builds its two-eye shaders only then; without a headset
    # on the PC's OpenXR it fails at once and stays out of the way.
    $env:WORKPLACE_REMOTE = '1'
    $env:WORKPLACE_WATCHED = '1'
    try {
        return Start-Process -FilePath $Godot -WorkingDirectory $Root -PassThru `
            -ArgumentList '--xr-mode', 'on', '--log-file', ('"' + $RemoteLog + '"'), '--path', ('"' + $Root + '"')
    } finally {
        Remove-Item Env:WORKPLACE_REMOTE, Env:WORKPLACE_WATCHED -ErrorAction SilentlyContinue
    }
}

# Something that keeps ending at once is started less and less often (up to a minute).
$delay = 3
$idle = $false
while (-not (Test-Path $StopFile)) {
    $mode = Read-Mode
    if ($mode -eq 0) {
        if (-not $idle) { Write-Log 'mode 0 (OpenXR on the PC): nothing to run' }
        $idle = $true
        Start-Sleep -Seconds 2
        continue
    }
    $idle = $false
    $started = Get-Date
    $process = Start-ForMode $mode
    $null = $process.Handle
    Write-Log ('mode ' + $mode + ': started, pid ' + $process.Id)
    while (-not $process.WaitForExit(2000)) {
        if ((Read-Mode) -ne $mode -or (Test-Path $StopFile)) {
            Write-Log ('mode ' + (Read-Mode) + ' chosen, waiting for pid ' + $process.Id)
            if (-not $process.WaitForExit(8000)) {
                Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue
                Write-Log ('pid ' + $process.Id + ' stopped')
            }
            break
        }
    }
    if (Test-Path $StopFile) {
        Write-Log 'stopped by link_server_stop.cmd'
        break
    }
    if ((Read-Mode) -ne $mode) { $delay = 3; continue }
    $code = $process.ExitCode
    if ($code -eq 0 -or ((Get-Date) - $started).TotalSeconds -gt 60) { $delay = 3 } else { $delay = [Math]::Min($delay * 2, 60) }
    Write-Log ('mode ' + $mode + ': ended (exit code ' + $code + '), again in ' + $delay + ' s')
    Start-Sleep -Seconds $delay
}
Remove-Item -Force -ErrorAction SilentlyContinue $StopFile
