# Detaches one virtual (MttVDD) monitor from the Windows desktop or attaches it
# back, the same way "Disconnect this display" does in Windows settings. No
# device is disabled and no driver restarts, so no admin rights are needed.
#
#   -Action list     print the displays
#   -Action remove   detach one attached VDD monitor (never the primary, never the last)
#   -Action add      re-attach the most recently detached one at its old position
#
# Prints one JSON line: {"ok":true,"code":"detached","detail":"..","attached":5}
# Detached monitors are remembered in %LOCALAPPDATA%\WoRkPlace\detached.json.
#
# Keep this file ASCII-only: Windows PowerShell 5.1 reads a BOM-less script as ANSI.
param(
    [ValidateSet('list', 'add', 'remove')][string]$Action = 'list',
    [int]$Width = 1920,
    [int]$Height = 1080,
    [switch]$DryRun
)

$ErrorActionPreference = 'Stop'

Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;

public static class Disp {
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    public struct DISPLAY_DEVICE {
        public int cb;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] public string DeviceName;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)] public string DeviceString;
        public int StateFlags;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)] public string DeviceID;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)] public string DeviceKey;
    }

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    public struct DEVMODE {
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] public string dmDeviceName;
        public short dmSpecVersion, dmDriverVersion, dmSize, dmDriverExtra;
        public int dmFields;
        public int dmPositionX, dmPositionY, dmDisplayOrientation, dmDisplayFixedOutput;
        public short dmColor, dmDuplex, dmYResolution, dmTTOption, dmCollate;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] public string dmFormName;
        public short dmLogPixels;
        public int dmBitsPerPel, dmPelsWidth, dmPelsHeight, dmDisplayFlags, dmDisplayFrequency;
        public int dmICMMethod, dmICMIntent, dmMediaType, dmDitherType, dmReserved1, dmReserved2;
        public int dmPanningWidth, dmPanningHeight;
    }

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    public static extern bool EnumDisplayDevices(string device, int index, ref DISPLAY_DEVICE info, int flags);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    public static extern bool EnumDisplaySettingsEx(string device, int mode, ref DEVMODE devMode, int flags);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    public static extern int ChangeDisplaySettingsEx(string device, ref DEVMODE devMode, IntPtr hwnd, int flags, IntPtr param);
    [DllImport("user32.dll", CharSet = CharSet.Unicode, EntryPoint = "ChangeDisplaySettingsEx")]
    public static extern int ApplyDisplaySettings(string device, IntPtr devMode, IntPtr hwnd, int flags, IntPtr param);
}
'@

# Prefixed, because PowerShell variable names are case-insensitive ($ATTACHED would be $attached).
$FLAG_ATTACHED = 0x1; $FLAG_PRIMARY = 0x4; $FLAG_MIRRORING = 0x8
$ENUM_CURRENT = -1
$DM_POSITION = 0x20; $DM_PELSWIDTH = 0x80000; $DM_PELSHEIGHT = 0x100000
$CDS_UPDATEREGISTRY = 0x1; $CDS_NORESET = 0x10000000
$StatePath = Join-Path $env:LOCALAPPDATA 'WoRkPlace\detached.json'

function New-DevMode {
    $mode = New-Object Disp+DEVMODE
    $mode.dmSize = [System.Runtime.InteropServices.Marshal]::SizeOf($mode)
    return $mode
}

function Get-Displays {
    $result = @()
    for ($i = 0; ; $i++) {
        $device = New-Object Disp+DISPLAY_DEVICE
        $device.cb = [System.Runtime.InteropServices.Marshal]::SizeOf($device)
        # [NullString]::Value, because PowerShell would marshal $null as "".
        if (-not [Disp]::EnumDisplayDevices([NullString]::Value, $i, [ref]$device, 0)) { break }
        if ($device.StateFlags -band $FLAG_MIRRORING) { continue }

        $monitor = New-Object Disp+DISPLAY_DEVICE
        $monitor.cb = [System.Runtime.InteropServices.Marshal]::SizeOf($monitor)
        $monitorId = ''
        if ([Disp]::EnumDisplayDevices($device.DeviceName, 0, [ref]$monitor, 0)) { $monitorId = $monitor.DeviceID }

        $attached = ($device.StateFlags -band $FLAG_ATTACHED) -ne 0
        $mode = New-DevMode
        if ($attached) { [Disp]::EnumDisplaySettingsEx($device.DeviceName, $ENUM_CURRENT, [ref]$mode, 0) | Out-Null }

        $result += [pscustomobject]@{
            Name     = $device.DeviceName
            Adapter  = $device.DeviceString
            Monitor  = $monitorId
            IsVdd    = ($device.DeviceString -eq 'Virtual Display Driver') -or ($monitorId -like 'MONITOR\MTT1337*')
            Attached = $attached
            Primary  = ($device.StateFlags -band $FLAG_PRIMARY) -ne 0
            X        = $mode.dmPositionX
            Y        = $mode.dmPositionY
            Width    = $mode.dmPelsWidth
            Height   = $mode.dmPelsHeight
        }
    }
    return $result
}

function Get-AttachedCount { @(Get-Displays | Where-Object Attached).Count }

function Read-State {
    if (-not (Test-Path $StatePath)) { return @() }
    try { return @(Get-Content $StatePath -Raw | ConvertFrom-Json) } catch { return @() }
}

function Write-State($entries) {
    New-Item -ItemType Directory -Force (Split-Path $StatePath) | Out-Null
    # ConvertTo-Json unwraps a one-element array, so build the brackets by hand.
    $items = @($entries | ForEach-Object { $_ | ConvertTo-Json -Compress })
    [System.IO.File]::WriteAllText($StatePath, '[' + ($items -join ',') + ']')
}

function Set-DisplayRect([string]$name, [int]$x, [int]$y, [int]$w, [int]$h) {
    $mode = New-DevMode
    $mode.dmFields = $DM_POSITION -bor $DM_PELSWIDTH -bor $DM_PELSHEIGHT
    $mode.dmPositionX = $x; $mode.dmPositionY = $y
    $mode.dmPelsWidth = $w; $mode.dmPelsHeight = $h
    $code = [Disp]::ChangeDisplaySettingsEx($name, [ref]$mode, [IntPtr]::Zero, ($CDS_UPDATEREGISTRY -bor $CDS_NORESET), [IntPtr]::Zero)
    if ($code -ne 0) { return $code }
    return [Disp]::ApplyDisplaySettings([NullString]::Value, [IntPtr]::Zero, [IntPtr]::Zero, 0, [IntPtr]::Zero)
}

function Wait-AttachedCount([int]$expected) {
    for ($i = 0; $i -lt 20; $i++) {
        if ((Get-AttachedCount) -eq $expected) { return $true }
        Start-Sleep -Milliseconds 250
    }
    return $false
}

function Remove-Screen {
    $attached = @(Get-Displays | Where-Object Attached)
    $candidates = @($attached | Where-Object { $_.IsVdd -and -not $_.Primary })
    # The user sees the PC only through these displays: never go below one.
    if ($attached.Count -le 1 -or $candidates.Count -eq 0) { return @{ ok = $false; code = 'last_screen'; detail = '' } }

    # The one furthest from the primary, so the rest of the layout stays intact.
    $target = $candidates | Sort-Object { [math]::Abs($_.X) + [math]::Abs($_.Y) }, Name | Select-Object -Last 1
    if ($DryRun) { return @{ ok = $true; code = 'dry_run'; detail = "would detach $($target.Name) at $($target.X),$($target.Y)" } }

    $code = Set-DisplayRect $target.Name 0 0 0 0
    if ($code -ne 0) { return @{ ok = $false; code = 'failed'; detail = "ChangeDisplaySettingsEx returned $code for $($target.Name)" } }
    if (-not (Wait-AttachedCount ($attached.Count - 1))) { return @{ ok = $false; code = 'failed'; detail = "$($target.Name) did not detach" } }

    $state = @(Read-State | Where-Object { $_.Name -ne $target.Name })
    $state += [pscustomobject]@{ Name = $target.Name; X = $target.X; Y = $target.Y; Width = $target.Width; Height = $target.Height }
    Write-State $state
    return @{ ok = $true; code = 'detached'; detail = $target.Name }
}

function Add-Screen {
    $displays = @(Get-Displays)
    $attachedCount = @($displays | Where-Object Attached).Count
    $free = @($displays | Where-Object { $_.IsVdd -and -not $_.Attached })
    if ($free.Count -eq 0) { return @{ ok = $false; code = 'no_free_screen'; detail = '' } }

    # Remembered monitors first (newest first), at the place they were taken from;
    # then any other detached VDD output, to the right of everything else.
    $right = ($displays | Where-Object Attached | ForEach-Object { $_.X + $_.Width } | Measure-Object -Maximum).Maximum
    $state = @(Read-State)
    $plan = @()
    for ($i = $state.Count - 1; $i -ge 0; $i--) {
        if ($free.Name -contains $state[$i].Name) { $plan += $state[$i] }
    }
    foreach ($display in $free) {
        if ($plan.Name -notcontains $display.Name) {
            $plan += [pscustomobject]@{ Name = $display.Name; X = $right; Y = 0; Width = $Width; Height = $Height }
        }
    }
    if ($DryRun) { return @{ ok = $true; code = 'dry_run'; detail = "would attach $($plan[0].Name) at $($plan[0].X),$($plan[0].Y)" } }

    # An adapter can expose outputs with no monitor behind them; those accept the
    # mode but never attach, so try candidates until the attached count grows.
    foreach ($entry in $plan) {
        $code = Set-DisplayRect $entry.Name $entry.X $entry.Y $entry.Width $entry.Height
        if ($code -eq 0 -and (Wait-AttachedCount ($attachedCount + 1))) {
            Write-State @($state | Where-Object { $_.Name -ne $entry.Name })
            return @{ ok = $true; code = 'attached'; detail = $entry.Name }
        }
    }
    return @{ ok = $false; code = 'failed'; detail = "none of $($plan.Count) detached outputs attached" }
}

try {
    switch ($Action) {
        'list'   { Get-Displays | Format-Table -AutoSize | Out-String -Width 250 | Write-Output; exit 0 }
        'remove' { $result = Remove-Screen }
        'add'    { $result = Add-Screen }
    }
} catch {
    $result = @{ ok = $false; code = 'failed'; detail = "$($_.Exception.Message)" }
}
$result.attached = Get-AttachedCount
$result | ConvertTo-Json -Compress
