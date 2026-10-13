# Elevated one-shot helper: adds or removes ONE virtual display by enabling,
# disabling or creating a MttVDD device instance. Started by the scheduled task
# WoRkPlaceVddHelper; reads a single request and writes a single response.
#
# Request  (request.txt):  "<id> add" | "<id> remove"
# Response (response.txt): {"id":"..","ok":true,"screens":5,"message":".."}
#
# Only the two verbs above are accepted and nothing from the request is ever
# executed, because this script runs elevated on behalf of an unelevated app.
#
# Keep this file ASCII-only: Windows PowerShell 5.1 reads a BOM-less script as ANSI.
param(
    [string]$Dir = (Join-Path $env:ProgramData 'WoRkPlace\vdd'),
    [switch]$DryRun
)

$ErrorActionPreference = 'Stop'
$HardwareId = 'Root\MttVDD'
$MaxScreens = 8
$Nefconc = 'C:\ProgramData\scoop\shims\nefconc.exe'
$LogPath = Join-Path $Dir 'helper.log'

function Write-Log([string]$text) {
    Add-Content -Path $LogPath -Value ('{0:HH:mm:ss.fff} {1}' -f (Get-Date), $text)
}

function Get-VddInstances {
    @(Get-PnpDevice -Class Display | Where-Object { $_.HardwareID -contains $HardwareId } | Sort-Object InstanceId)
}

function Get-ScreenCount {
    @(Get-PnpDevice -Class Monitor -PresentOnly | Where-Object { $_.InstanceId -like 'DISPLAY\MTT1337\*' -and $_.Status -eq 'OK' }).Count
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
        $code = Invoke-Tool 'pnputil.exe' @('/enable-device', $id)
        if ($code -ne 0 -and $code -ne 3010) { throw "pnputil /enable-device ${id}: exit code $code" }
        if ($DryRun) { return "dry run: would enable $id" }
        if (-not (Wait-ScreenCount ($before + 1) 30)) { throw "$id enabled, but no screen appeared in 30 s" }
        return "enabled $id"
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
        Invoke-Tool 'pnputil.exe' @('/restart-device', $created[0]) | Out-Null
        if (Wait-ScreenCount ($before + 1) 10) { return "created $($created[0]) (bound after restart)" }
    }
    Invoke-Tool 'pnputil.exe' @('/scan-devices') | Out-Null
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
    $code = Invoke-Tool 'pnputil.exe' @('/disable-device', $id)
    if ($code -ne 0 -and $code -ne 3010) { throw "pnputil /disable-device ${id}: exit code $code" }
    if ($DryRun) { return "dry run: would disable $id" }
    if (-not (Wait-ScreenCount ($before - 1) 30)) { throw "$id disabled, but the screen count did not change in 30 s" }
    return "disabled $id"
}

$requestPath = Join-Path $Dir 'request.txt'
$responsePath = Join-Path $Dir 'response.txt'
if (-not (Test-Path $requestPath)) { exit 0 }

$parts = (Get-Content $requestPath -Raw).Trim() -split '\s+'
Remove-Item $requestPath -Force
$requestId = if ($parts[0] -match '^\d+$') { $parts[0] } else { '' }

Write-Log "request: $($parts -join ' ') (screens $(Get-ScreenCount))"
$ok = $false
try {
    if ($requestId -eq '' -or $parts.Count -ne 2) { throw 'malformed request' }
    switch -CaseSensitive ($parts[1]) {
        'add'    { $message = Add-Screen }
        'remove' { $message = Remove-Screen }
        default  { throw 'unknown command' }
    }
    $ok = $true
} catch {
    $message = "$($_.Exception.Message)"
}

$response = @{ id = $requestId; ok = $ok; screens = (Get-ScreenCount); message = $message } | ConvertTo-Json -Compress
[System.IO.File]::WriteAllText($responsePath, $response, (New-Object System.Text.UTF8Encoding($false)))
Write-Log "response: $response"
