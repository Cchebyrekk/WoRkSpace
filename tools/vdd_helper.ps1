# Elevated one-shot helper: adds or removes ONE virtual display by enabling,
# disabling or creating a MttVDD device instance. Started by the scheduled task
# WoRkPlaceVddHelper; reads a single request and writes a single response.
#
# Request  (request.txt):  "<id> add" | "<id> remove" | "<id> apply <count>"
# Response (response.txt): {"id":"..","ok":true,"screens":5,"message":".."}
#
# Only the verbs above (and a count of 1..$MaxScreens) are accepted and nothing
# from the request is ever executed, because this script runs elevated on behalf
# of an unelevated app.
#
# Keep this file ASCII-only: Windows PowerShell 5.1 reads a BOM-less script as ANSI.
param(
    [string]$Dir = (Join-Path $env:ProgramData 'WoRkPlace\vdd'),
    [switch]$DryRun
)

$ErrorActionPreference = 'Stop'
# The task runs elevated as the user, and Windows PowerShell looks for modules in
# the user's Documents first: a planted PnpDevice module would run as admin.
# Only the system's own modules are used.
$env:PSModulePath = Join-Path $PSHOME 'Modules'
Import-Module (Join-Path $PSHOME 'Modules\PnpDevice') -ErrorAction Stop
$Pnputil = Join-Path $env:SystemRoot 'System32\pnputil.exe'
$HardwareId = 'Root\MttVDD'
$MaxScreens = 8
# Raised whenever the commands change; the app warns when the installed copy is older.
$HelperVersion = 6
$Nefconc = 'C:\ProgramData\scoop\shims\nefconc.exe'
# The log lives in a folder only administrators can write (install_vdd_helper.ps1);
# the exchange folder is writable by users, and an elevated write there could be
# redirected elsewhere through a junction.
$LogPath = if ($DryRun) { Join-Path $Dir 'helper.log' } else { Join-Path $env:ProgramData 'WoRkPlace\vdd-log\helper.log' }

function Test-Redirected([string]$Path) {
    $item = Get-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
    return $null -ne $item -and ($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint)
}

function Write-Log([string]$text) {
    if (Test-Redirected (Split-Path $LogPath)) { return }
    Add-Content -Path $LogPath -Value ('{0:HH:mm:ss.fff} {1}' -f (Get-Date), $text)
}

# -ErrorAction SilentlyContinue: right after the driver host is ended there may be
# no such device at all, and Get-PnpDevice then throws instead of returning nothing
# (19.10.2026: the whole "apply" failed on that).
function Get-VddInstances {
    @(Get-PnpDevice -Class Display -ErrorAction SilentlyContinue | Where-Object { $_.HardwareID -contains $HardwareId } | Sort-Object InstanceId)
}

function Get-ScreenCount {
    @(Get-PnpDevice -Class Monitor -PresentOnly -ErrorAction SilentlyContinue | Where-Object { $_.InstanceId -like 'DISPLAY\MTT1337\*' -and $_.Status -eq 'OK' }).Count
}

function Wait-ScreenCount([int]$Expected, [int]$TimeoutSec) {
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    while ((Get-Date) -lt $deadline) {
        if ((Get-ScreenCount) -eq $Expected) { return $true }
        Start-Sleep -Milliseconds 500
    }
    return $false
}

function Invoke-Tool([string]$Exe, [string[]]$Arguments) {
    if ($DryRun) { return 0 }
    $output = & $Exe @Arguments 2>&1 | Out-String
    Write-Log "$Exe $($Arguments -join ' ') -> exit $LASTEXITCODE, screens $(Get-ScreenCount): $($output.Trim() -replace '\s+', ' ')"
    return $LASTEXITCODE
}

function Add-Screen {
    $before = Get-ScreenCount
    if ($before -ge $MaxScreens) { throw "already $before screens, limit is $MaxScreens" }

    $disabled = @(Get-VddInstances | Where-Object { "$($_.ConfigManagerErrorCode)" -eq 'CM_PROB_DISABLED' })
    if ($disabled.Count -gt 0) {
        $id = $disabled[0].InstanceId
        $code = Invoke-Tool $Pnputil @('/enable-device', $id)
        if ($DryRun) { return "dry run: would enable $id" }
        if ($code -eq 0 -or $code -eq 3010) {
            if (-not (Wait-ScreenCount ($before + 1) 30)) { throw "$id enabled, but no screen appeared in 30 s" }
            return "enabled $id"
        }
        # 18.10.2026: an instance disabled days before refused with 1167 ("device not
        # connected"). Such a one is removed and a fresh instance created below.
        Write-Log "cannot enable $id (exit $code): removing it and creating a new instance"
        Invoke-Tool $Pnputil @('/remove-device', $id) | Out-Null
    }

    if (-not (Test-Path $Nefconc)) { throw "$Nefconc not found" }
    $known = @(Get-VddInstances | ForEach-Object InstanceId)
    $code = Invoke-Tool $Nefconc @('--create-device-node', '--hardware-id', $HardwareId, '--class-name', 'Display', '--class-guid', '4D36E968-E325-11CE-BFC1-08002BE10318')
    if ($code -ne 0) { throw "nefconc --create-device-node: exit code $code" }
    if ($DryRun) { return 'dry run: would create a new device instance' }
    if (Wait-ScreenCount ($before + 1) 2) { return 'created a new device instance' }

    # The driver does not bind on its own. Restarting just the new node is what
    # worked in practice (a device scan did not); --install-driver is the last
    # resort because it restarts every instance.
    $created = @(Get-VddInstances | ForEach-Object InstanceId | Where-Object { $known -notcontains $_ })
    Write-Log "new instances: $($created -join ', ')"
    if ($created.Count -eq 1) {
        Invoke-Tool $Pnputil @('/restart-device', $created[0]) | Out-Null
        if (Wait-ScreenCount ($before + 1) 10) { return "created $($created[0]) (bound after restart)" }
    }
    Invoke-Tool $Pnputil @('/scan-devices') | Out-Null
    if (Wait-ScreenCount ($before + 1) 10) { return 'created a new device instance (bound after device scan)' }

    $inf = Get-ChildItem (Join-Path $env:SystemRoot 'System32\DriverStore\FileRepository\mttvdd.inf_amd64_*\MttVDD.inf') | Select-Object -First 1
    if ($null -eq $inf) { throw 'instance created, but the driver did not bind and MttVDD.inf was not found' }
    $code = Invoke-Tool $Nefconc @('--install-driver', '--inf-path', $inf.FullName)
    if ($code -ne 0 -and $code -ne 3010) { throw "nefconc --install-driver: exit code $code" }
    if (-not (Wait-ScreenCount ($before + 1) 30)) { throw 'instance created and driver installed, but no screen appeared' }
    return 'created a new device instance (driver installed explicitly)'
}

function Remove-Screen {
    $before = Get-ScreenCount
    $enabled = @(Get-VddInstances | Where-Object { $_.Status -eq 'OK' })
    # The user sees the PC only through these displays: never go below one.
    if ($before -le 1 -or $enabled.Count -le 1) { throw 'only one screen left, refusing to remove it' }

    $id = $enabled[-1].InstanceId
    $code = Invoke-Tool $Pnputil @('/disable-device', $id)
    if ($code -ne 0 -and $code -ne 3010) { throw "pnputil /disable-device ${id}: exit code $code" }
    if ($DryRun) { return "dry run: would disable $id" }
    if (-not (Wait-ScreenCount ($before - 1) 30)) { throw "$id disabled, but the screen count did not change in 30 s" }
    return "disabled $id"
}

function Get-Working {
    @(Get-VddInstances | Where-Object { $_.Status -eq 'OK' })
}

# "Apply" from the app: bring the number of working instances to $Target, then
# restart every instance so that the driver reads vdd_settings.xml again (the app
# has written the user's resolutions there). One driver restart for everything,
# so Quest Link reconnects once. Disabled instances are enabled before new ones
# are created; surplus ones are removed, the highest-numbered first.
# Ends the WUDFHost process(es) the MttVDD driver runs in; Windows restarts them
# with the devices. True once the screens are back.
function Restart-DriverHost([int]$Screens) {
    $hosts = @(Get-Process WUDFHost -ErrorAction SilentlyContinue | Where-Object {
        try { @($_.Modules | Where-Object { $_.ModuleName -like 'mttvdd*' }).Count -gt 0 } catch { $false }
    })
    if ($hosts.Count -eq 0) {
        Write-Log 'no driver host process with MttVDD.dll found'
        return $false
    }
    foreach ($process in $hosts) {
        Write-Log "ending driver host process $($process.Id) (started $($process.StartTime))"
        if (-not $DryRun) { Stop-Process -Id $process.Id -Force }
    }
    if ($DryRun) { return $true }
    Start-Sleep -Seconds 2
    if (Wait-ScreenCount $Screens 30) { return $true }
    # Not back by themselves: start the instances again.
    foreach ($instance in (Get-VddInstances)) {
        Invoke-Tool $Pnputil @('/restart-device', $instance.InstanceId) | Out-Null
    }
    return (Wait-ScreenCount $Screens 30)
}

function Set-InstanceCount([int]$Target) {
    if ($Target -lt 1 -or $Target -gt $MaxScreens) { throw "count must be 1..$MaxScreens, got $Target" }
    $steps = @()
    while ((Get-Working).Count -gt $Target) {
        $working = Get-Working
        # The user sees the PC only through these displays: never go below one.
        if ($working.Count -le 1) { break }
        $id = $working[-1].InstanceId
        $code = Invoke-Tool $Pnputil @('/remove-device', $id)
        if ($code -ne 0 -and $code -ne 3010) { throw "pnputil /remove-device ${id}: exit code $code" }
        $steps += "removed $id"
        if ($DryRun) { break }
    }
    while ((Get-Working).Count -lt $Target) {
        $steps += (Add-Screen)
        if ($DryRun) { break }
    }
    # Restarting the instances one by one did not make the driver read its settings
    # file again (18.10.2026: a new resolution was in the file but not offered; two
    # instances answered 3010 "restart needed"). Reinstalling the driver restarts
    # all of them at once, as it did when instances were created.
    # Neither did --install-driver (3010, "restart needed"): the driver host process
    # had been running since the PC started. Ending it makes Windows start the
    # driver anew, and it reads the file then.
    $reloaded = Restart-DriverHost (Get-ScreenCount)
    $inf = Get-ChildItem (Join-Path $env:SystemRoot 'System32\DriverStore\FileRepository\mttvdd.inf_amd64_*\MttVDD.inf') -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $reloaded -and $null -ne $inf -and (Test-Path $Nefconc)) {
        $code = Invoke-Tool $Nefconc @('--install-driver', '--inf-path', $inf.FullName)
        $reloaded = $code -eq 0 -or $code -eq 3010
    }
    if (-not $reloaded) {
        foreach ($instance in (Get-Working)) {
            Invoke-Tool $Pnputil @('/restart-device', $instance.InstanceId) | Out-Null
        }
    }
    if (-not $DryRun -and -not (Wait-ScreenCount $Target 60)) { throw "instances set to $Target, but $(Get-ScreenCount) screens came up in 60 s" }
    $steps += "driver restarted, $((Get-Working).Count) instances"
    return ($steps -join '; ')
}

$requestPath = Join-Path $Dir 'request.txt'
$responsePath = Join-Path $Dir 'response.txt'
# A junction in place of the exchange folder (or its parent) would send the
# elevated writes below somewhere else.
if ((Test-Redirected $Dir) -or (Test-Redirected (Split-Path $Dir))) { exit 1 }
if (-not (Test-Path -LiteralPath $requestPath)) { exit 0 }

$parts = @()
$requestId = ''
$ok = $false
try {
    # At most 64 characters, only letters, digits and spaces: anything else is
    # not a request, and nothing unchecked reaches the log.
    $raw = [System.IO.File]::ReadAllText($requestPath)
    Remove-Item -LiteralPath $requestPath -Force
    if ($raw.Length -gt 64 -or $raw -notmatch '^[A-Za-z0-9\s]*$') { $raw = '' }
    $parts = @($raw.Trim() -split '\s+')
    $requestId = if ($parts[0] -match '^\d+$') { $parts[0] } else { '' }
    Write-Log "request: $($parts -join ' ') (screens $(Get-ScreenCount))"
    if ($requestId -eq '' -or $parts.Count -lt 2) { throw 'malformed request' }
    switch -CaseSensitive ($parts[1]) {
        'add'    { if ($parts.Count -ne 2) { throw 'malformed request' }; $message = Add-Screen }
        'remove' { if ($parts.Count -ne 2) { throw 'malformed request' }; $message = Remove-Screen }
        'apply'  {
            if ($parts.Count -ne 3 -or $parts[2] -notmatch '^\d{1,2}$') { throw 'malformed request' }
            $message = Set-InstanceCount ([int]$parts[2])
        }
        default  { throw 'unknown command' }
    }
    $ok = $true
} catch {
    $message = "$($_.Exception.Message)"
}

$response = @{ id = $requestId; ok = $ok; screens = (Get-ScreenCount); message = $message; version = $HelperVersion } | ConvertTo-Json -Compress
# Into a new file only: never through a file or link someone put there.
Remove-Item -LiteralPath $responsePath -Force -ErrorAction SilentlyContinue
try {
    $stream = New-Object System.IO.FileStream($responsePath, [System.IO.FileMode]::CreateNew, [System.IO.FileAccess]::Write)
    $bytes = (New-Object System.Text.UTF8Encoding($false)).GetBytes($response)
    $stream.Write($bytes, 0, $bytes.Length)
    $stream.Close()
} catch {
    Write-Log "response not written: $($_.Exception.Message)"
}
Write-Log "response: $response"
