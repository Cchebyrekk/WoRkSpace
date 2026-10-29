# The WoRkPlace link server's watchdog (slice o6), started hidden by
# link_server.cmd: runs the server (Godot, headless, no console of its own) and
# starts it again when it ends, until link_server_stop.cmd leaves the stop file.
# 29.10.2026 the server ended while the user worked and every screen in the
# headset was gone until it was started by hand.
#
# Keep this file ASCII-only: Windows PowerShell 5.1 reads a BOM-less script as ANSI.
$Godot = 'C:\Program Files (x86)\Steam\steamapps\common\Godot Engine\godot.windows.opt.tools.64.exe'
$Root = Split-Path -Parent $PSScriptRoot
$Dir = Join-Path $env:LOCALAPPDATA 'WoRkPlace'
$StopFile = Join-Path $Dir 'link_server.stop'
$Log = Join-Path $Dir 'link_server_watch.log'
New-Item -ItemType Directory -Force -Path $Dir | Out-Null

# One watchdog at a time: a second start of link_server.cmd does nothing.
$mutex = New-Object System.Threading.Mutex($false, 'Local\WoRkPlaceLinkServerWatch')
if (-not $mutex.WaitOne(0)) { exit }
Remove-Item -Force -ErrorAction SilentlyContinue $StopFile

function Write-Log([string]$text) {
    Add-Content -Path $Log -Value ((Get-Date -Format 'dd.MM HH:mm:ss') + ' ' + $text)
}

# A server that keeps ending at once is started less and less often (up to a minute).
$delay = 3
while ($true) {
    $started = Get-Date
    $process = Start-Process -FilePath $Godot -WorkingDirectory $Root -PassThru `
        -ArgumentList '--headless', '--xr-mode', 'off', '--path', ('"' + $Root + '"'), 'res://scenes/link_server.tscn'
    Write-Log ('server started, pid ' + $process.Id)
    $process.WaitForExit()
    if (Test-Path $StopFile) {
        Write-Log 'server stopped by link_server_stop.cmd'
        break
    }
    if (((Get-Date) - $started).TotalSeconds -gt 60) { $delay = 3 } else { $delay = [Math]::Min($delay * 2, 60) }
    Write-Log ('server ended (exit code ' + $process.ExitCode + '), again in ' + $delay + ' s')
    Start-Sleep -Seconds $delay
}
Remove-Item -Force -ErrorAction SilentlyContinue $StopFile
