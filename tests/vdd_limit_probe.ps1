# Finds the biggest resolutions the MTT Virtual Display Driver takes.
#
# History (22.10.2026): a settings file with 15992x8104, 13984x1080, 5760x4320 and
# 1920x200 in it left the driver with no screen at all. A first run of this probe
# with 8 instances found widths up to 15360 at 1080 fine, but raising the height
# (1920x4320, then 1920x8640) crashed Windows (bug check 0x10E,
# VIDEO_MEMORY_MANAGEMENT_INTERNAL) and left the settings file full of zero bytes.
#
# This version (the user's wishes): only ONE driver instance while it runs, the
# candidates strictly one at a time, and nothing starts before the result of the
# one before is on the disk. For each candidate (ascending; it stops at the first
# one that fails) the driver's list becomes the known good resolutions plus the
# candidate, the helper task restarts the driver ("apply 1"), and the probe checks
# that the screen came back and that Windows offers the candidate.
#
# If Windows crashes, run it again after the reboot: a step that was started but
# has no result is written down as "crashed", nothing higher is tried, and
# everything is put back. At the end: the good settings file, $Instances
# instances again, the Windows layout and the windows' places.
#
# WARNING: a resolution the driver chokes on can crash all of Windows. Save your
# work and close WoRkPlace first:
#   powershell -ExecutionPolicy Bypass -File tests\vdd_limit_probe.ps1
# Log: %LOCALAPPDATA%\WoRkPlace\vdd_limit.log, state: vdd_limit_state.txt there.

param(
    [int]$Instances = 8,
    # Instances while testing (1 by default; 8 to try a size with all of them).
    [int]$TestInstances = 1,
    [string[]]$Sizes = @('1920x2400', '1920x2880', '1920x3240', '1920x3600', '1920x4320', '1920x6480', '1920x8640')
)

$ErrorActionPreference = 'Stop'
$settings = 'C:\VirtualDisplayDriver\vdd_settings.xml'
$goodCopy = 'C:\VirtualDisplayDriver\vdd_settings.probe-good.xml'
$exchange = Join-Path $env:ProgramData 'WoRkPlace\vdd'
$dataDir = Join-Path $env:LOCALAPPDATA 'WoRkPlace'
$log = Join-Path $dataDir 'vdd_limit.log'
$state = Join-Path $dataDir "vdd_limit_state_$TestInstances.txt"
$topology = Join-Path $PSScriptRoot '..\tools\display_topology.ps1'
$good = @('1920x1080', '2560x1440', '3840x2160')

# Written through to the disk before it returns (a crash right after loses nothing).
function Write-Durable([string]$path, [string]$text, [switch]$Append) {
    $mode = [IO.FileMode]::Create
    if ($Append) { $mode = [IO.FileMode]::Append }
    $stream = New-Object IO.FileStream($path, $mode, [IO.FileAccess]::Write, [IO.FileShare]::Read, 4096, [IO.FileOptions]::WriteThrough)
    try {
        $bytes = (New-Object Text.UTF8Encoding($false)).GetBytes($text)
        $stream.Write($bytes, 0, $bytes.Length)
        $stream.Flush($true)
    }
    finally { $stream.Close() }
}

# A whole file replaced at once: a new copy on the disk first, then swapped in.
function Replace-Durable([string]$path, [string]$text) {
    $fresh = $path + '.probe-new'
    Write-Durable $fresh $text
    # [NullString]::Value: PowerShell would pass $null as "" (no backup file wanted).
    if (Test-Path $path) { [IO.File]::Replace($fresh, $path, [NullString]::Value) } else { [IO.File]::Move($fresh, $path) }
}

function Note([string]$text) {
    $line = (Get-Date -Format 'HH:mm:ss') + ' ' + $text
    Write-Output $line
    Write-Durable $log ($line + "`r`n") -Append
}

function Mark([string]$text) { Write-Durable $state ($text + "`r`n") -Append }

# The known good settings file: kept aside on the first run; a settings file that
# is no settings file (zeroed by a crash) is rebuilt from it.
if (-not (Test-Path $goodCopy)) {
    $current = [IO.File]::ReadAllText($settings)
    if (-not $current.Contains('<resolutions>')) { throw "the settings file is broken and there is no good copy" }
    Write-Durable $goodCopy $current
}
$original = [IO.File]::ReadAllText($goodCopy)

function Write-Resolutions([string[]]$sizes) {
    $lines = @('<resolutions>')
    foreach ($size in $sizes) {
        $wh = $size.Split('x')
        $lines += '        <resolution>'
        $lines += '            <width>' + $wh[0] + '</width>'
        $lines += '            <height>' + $wh[1] + '</height>'
        $lines += '            <refresh_rate>120</refresh_rate>'
        $lines += '        </resolution>'
    }
    $lines += '    </resolutions>'
    Replace-Durable $settings ([regex]::Replace($original, '(?s)<resolutions>.*?</resolutions>', ($lines -join "`r`n")))
}

# The helper restarts the driver with `count` instances; its answer (or $null after 5 minutes).
function Restart-Driver([int]$count) {
    $id = [string](Get-Random -Minimum 100000000 -Maximum 999999999)
    [IO.File]::WriteAllText((Join-Path $exchange 'request.txt'), "$id apply $count")
    schtasks.exe /run /tn WoRkPlaceVddHelper | Out-Null
    $deadline = (Get-Date).AddMinutes(5)
    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Seconds 3
        $answer = Get-Content -Raw (Join-Path $exchange 'response.txt') -ErrorAction SilentlyContinue
        if ($answer -and $answer.Contains('"' + $id + '"')) { return $answer.Trim() }
    }
    return $null
}

function Count-Screens {
    return @(Get-PnpDevice -Class Monitor -PresentOnly -ErrorAction SilentlyContinue |
        Where-Object { $_.InstanceId -like 'DISPLAY\MTT1337*' -and $_.Status -eq 'OK' }).Count
}

function Is-Offered([string]$size) {
    $json = & powershell -NoProfile -ExecutionPolicy Bypass -File $topology -Action modes | Out-String
    return $json.Contains('"' + $size + '@')
}

# What the state file says about each size: started / good / failed / crashed.
$known = @{}
if (Test-Path $state) {
    foreach ($line in Get-Content $state) {
        $parts = $line.Split(' ')
        if ($parts.Count -ge 2) { $known[$parts[0]] = $parts[1] }
    }
}

Note "=== probe run, $TestInstances instance(s) while testing, $Instances afterwards"
$crashed = @($known.Keys | Where-Object { $known[$_] -eq 'started' })
foreach ($size in $crashed) {
    Note "$size : started but no result - Windows went down while it was tried"
    Mark "$size crashed"
    $known[$size] = 'crashed'
}
$stop = ($known.Values | Where-Object { $_ -in @('crashed', 'failed') }).Count -gt 0

if (-not $stop) {
    # A first run remembers the layout and the windows (put back at the end).
    if ($known.Count -eq 0) {
        & powershell -NoProfile -ExecutionPolicy Bypass -File $topology -Action save -Backup apply | Out-Null
    }
    if ((Count-Screens) -ne $TestInstances) {
        Write-Resolutions $good
        Note ("$TestInstances instance(s): helper {0}, screens {1}" -f (Restart-Driver $TestInstances), (Count-Screens))
    }
    foreach ($size in $Sizes) {
        if ($known.ContainsKey($size)) {
            Note "$size : already $($known[$size])"
            continue
        }
        Note "$size : starting"
        Mark "$size started"
        Write-Resolutions ($good + $size)
        $answer = Restart-Driver $TestInstances
        Start-Sleep -Seconds 5
        $screens = Count-Screens
        $offered = $false
        if ($screens -ge $TestInstances) { $offered = Is-Offered $size }
        $result = 'failed'
        if ($screens -ge $TestInstances -and $offered) { $result = 'good' }
        Mark "$size $result"
        Note ("{0} : {1} (screens {2}, offered {3}, helper {4})" -f $size, $result, $screens, $offered, $answer)
        if ($result -ne 'good') { break }
    }
}

Note "putting the good settings and $Instances instances back"
Replace-Durable $settings $original
$answer = Restart-Driver $Instances
Start-Sleep -Seconds 5
Note ("final: screens {0}/{1}, helper {2}" -f (Count-Screens), $Instances, $answer)
& powershell -NoProfile -ExecutionPolicy Bypass -File $topology -Action restore -Backup apply | Out-Null
Note "=== probe run end"
