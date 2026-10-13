# Detaches one virtual (MttVDD) monitor from the Windows desktop or attaches it
# back, the same way "Disconnect this display" does in Windows settings. Uses the
# CCD API (QueryDisplayConfig / SetDisplayConfig); no device is disabled and no
# driver restarts, so no admin rights are needed.
#
#   -Action list     print the displays
#   -Action remove   detach one active VDD monitor (never the primary, never the last)
#   -Action add      re-attach the most recently detached one at its old position
#
# Prints one JSON line: {"ok":true,"code":"detached","detail":"..","attached":5}
# Monitors are identified by their device path (\\?\DISPLAY#MTT1337#...), which
# survives driver restarts, unlike \\.\DISPLAYnn.
# State: %LOCALAPPDATA%\WoRkPlace\detached.json, log: ...\topology.log
#
# Keep this file ASCII-only: Windows PowerShell 5.1 reads a BOM-less script as ANSI.
# The embedded C# has to stay C# 5 (no string interpolation, no "out var").
param(
    [ValidateSet('list', 'add', 'remove')][string]$Action = 'list',
    [switch]$DryRun
)

$ErrorActionPreference = 'Stop'

Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;

public class CcdScreen {
    public string Path { get; set; }
    public bool Active { get; set; }
    public bool Primary { get; set; }
    public int X { get; set; }
    public int Y { get; set; }
    public int Width { get; set; }
    public int Height { get; set; }
}

public static class Ccd {
    const uint QDC_ALL_PATHS = 1, QDC_ONLY_ACTIVE_PATHS = 2;
    const uint SDC_FLAGS = 0x80 | 0x20 | 0x200 | 0x400; // APPLY | USE_SUPPLIED_DISPLAY_CONFIG | SAVE_TO_DATABASE | ALLOW_CHANGES
    const uint PATH_ACTIVE = 1, MODE_SOURCE = 1, INVALID = 0xffffffff;

    [StructLayout(LayoutKind.Sequential)]
    struct LUID { public uint LowPart; public int HighPart; }
    [StructLayout(LayoutKind.Sequential)]
    struct PATH_SOURCE { public LUID adapterId; public uint id; public uint modeInfoIdx; public uint statusFlags; }
    [StructLayout(LayoutKind.Sequential)]
    struct PATH_TARGET {
        public LUID adapterId; public uint id; public uint modeInfoIdx; public uint outputTechnology;
        public uint rotation; public uint scaling; public uint refreshNumerator; public uint refreshDenominator;
        public uint scanLineOrdering; public int targetAvailable; public uint statusFlags;
    }
    [StructLayout(LayoutKind.Sequential)]
    struct PATH_INFO { public PATH_SOURCE sourceInfo; public PATH_TARGET targetInfo; public uint flags; }

    // 64 bytes; only the source-mode view of the union is spelled out.
    [StructLayout(LayoutKind.Explicit, Size = 64)]
    struct MODE_INFO {
        [FieldOffset(0)] public uint infoType;
        [FieldOffset(4)] public uint id;
        [FieldOffset(8)] public LUID adapterId;
        [FieldOffset(16)] public uint srcWidth;
        [FieldOffset(20)] public uint srcHeight;
        [FieldOffset(24)] public uint srcPixelFormat;
        [FieldOffset(28)] public int srcX;
        [FieldOffset(32)] public int srcY;
    }

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    struct TARGET_NAME {
        public uint type; public uint size; public LUID adapterId; public uint id;
        public uint flags; public uint outputTechnology; public ushort edidManufactureId; public ushort edidProductCodeId;
        public uint connectorInstance;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 64)] public string friendlyName;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)] public string devicePath;
    }

    [DllImport("user32.dll")] static extern int GetDisplayConfigBufferSizes(uint flags, out uint numPaths, out uint numModes);
    [DllImport("user32.dll")] static extern int QueryDisplayConfig(uint flags, ref uint numPaths, [In, Out] PATH_INFO[] paths, ref uint numModes, [In, Out] MODE_INFO[] modes, IntPtr topology);
    [DllImport("user32.dll")] static extern int SetDisplayConfig(uint numPaths, [In] PATH_INFO[] paths, uint numModes, [In] MODE_INFO[] modes, uint flags);
    [DllImport("user32.dll")] static extern int DisplayConfigGetDeviceInfo(ref TARGET_NAME request);

    static void Query(uint flags, out PATH_INFO[] paths, out MODE_INFO[] modes) {
        int result = 0;
        for (int attempt = 0; attempt < 4; attempt++) {
            uint pathCount, modeCount;
            result = GetDisplayConfigBufferSizes(flags, out pathCount, out modeCount);
            if (result != 0) break;
            paths = new PATH_INFO[pathCount];
            modes = new MODE_INFO[modeCount];
            result = QueryDisplayConfig(flags, ref pathCount, paths, ref modeCount, modes, IntPtr.Zero);
            if (result == 0) {
                Array.Resize(ref paths, (int)pathCount);
                Array.Resize(ref modes, (int)modeCount);
                return;
            }
            if (result != 122) break; // ERROR_INSUFFICIENT_BUFFER: the topology changed in between
        }
        throw new Exception("QueryDisplayConfig failed with " + result);
    }

    static readonly Dictionary<string, string> pathCache = new Dictionary<string, string>();

    static string TargetPath(PATH_TARGET target) {
        string key = target.adapterId.LowPart + ":" + target.adapterId.HighPart + ":" + target.id;
        string path;
        if (pathCache.TryGetValue(key, out path)) return path;
        TARGET_NAME request = new TARGET_NAME();
        request.type = 2; // DISPLAYCONFIG_DEVICE_INFO_GET_TARGET_NAME
        request.size = (uint)Marshal.SizeOf(typeof(TARGET_NAME));
        request.adapterId = target.adapterId;
        request.id = target.id;
        path = DisplayConfigGetDeviceInfo(ref request) == 0 ? request.devicePath : "";
        pathCache[key] = path;
        return path;
    }

    static string SourceKey(PATH_SOURCE source) {
        return source.adapterId.LowPart + ":" + source.adapterId.HighPart + ":" + source.id;
    }

    static bool Same(string a, string b) {
        return string.Equals(a, b, StringComparison.OrdinalIgnoreCase);
    }

    public static List<CcdScreen> List() {
        PATH_INFO[] paths; MODE_INFO[] modes;
        Query(QDC_ALL_PATHS, out paths, out modes);
        var byPath = new Dictionary<string, CcdScreen>(StringComparer.OrdinalIgnoreCase);
        var result = new List<CcdScreen>();
        foreach (PATH_INFO path in paths) {
            if (path.targetInfo.targetAvailable == 0) continue;
            string devicePath = TargetPath(path.targetInfo);
            if (devicePath == "") continue;
            CcdScreen screen;
            if (!byPath.TryGetValue(devicePath, out screen)) {
                screen = new CcdScreen();
                screen.Path = devicePath;
                byPath[devicePath] = screen;
                result.Add(screen);
            }
            if ((path.flags & PATH_ACTIVE) == 0) continue;
            screen.Active = true;
            uint index = path.sourceInfo.modeInfoIdx;
            if (index < modes.Length && modes[index].infoType == MODE_SOURCE) {
                screen.X = modes[index].srcX;
                screen.Y = modes[index].srcY;
                screen.Width = (int)modes[index].srcWidth;
                screen.Height = (int)modes[index].srcHeight;
                screen.Primary = screen.X == 0 && screen.Y == 0;
            }
        }
        return result;
    }

    // Each of these returns 0 on success, a Win32 error code, or -1 if the monitor was not found.

    public static int Detach(string devicePath) {
        PATH_INFO[] paths; MODE_INFO[] modes;
        Query(QDC_ONLY_ACTIVE_PATHS, out paths, out modes);
        int found = -1;
        for (int i = 0; i < paths.Length; i++) {
            if (Same(TargetPath(paths[i].targetInfo), devicePath)) found = i;
        }
        if (found < 0) return -1;
        paths[found].flags &= ~PATH_ACTIVE;
        int result = SetDisplayConfig((uint)paths.Length, paths, (uint)modes.Length, modes, SDC_FLAGS);
        if (result == 0) return 0;
        // Some drivers reject an inactive path in the list: leave it out instead.
        var rest = new List<PATH_INFO>(paths);
        rest.RemoveAt(found);
        return SetDisplayConfig((uint)rest.Count, rest.ToArray(), (uint)modes.Length, modes, SDC_FLAGS);
    }

    public static int Attach(string devicePath) {
        PATH_INFO[] active; MODE_INFO[] modes;
        Query(QDC_ONLY_ACTIVE_PATHS, out active, out modes);
        PATH_INFO[] all; MODE_INFO[] allModes;
        Query(QDC_ALL_PATHS, out all, out allModes);

        var usedSources = new HashSet<string>();
        foreach (PATH_INFO path in active) usedSources.Add(SourceKey(path.sourceInfo));
        int pick = -1;
        for (int i = 0; i < all.Length && pick < 0; i++) {
            if (all[i].targetInfo.targetAvailable == 0) continue;
            if (usedSources.Contains(SourceKey(all[i].sourceInfo))) continue;
            if (Same(TargetPath(all[i].targetInfo), devicePath)) pick = i;
        }
        if (pick < 0) return -1;

        // No mode supplied: with ALLOW_CHANGES Windows picks the mode and a free position.
        PATH_INFO added = all[pick];
        added.flags |= PATH_ACTIVE;
        added.sourceInfo.modeInfoIdx = INVALID;
        added.targetInfo.modeInfoIdx = INVALID;
        var paths = new List<PATH_INFO>(active);
        paths.Add(added);
        return SetDisplayConfig((uint)paths.Count, paths.ToArray(), (uint)modes.Length, modes, SDC_FLAGS);
    }

    public static int SetPosition(string devicePath, int x, int y) {
        PATH_INFO[] paths; MODE_INFO[] modes;
        Query(QDC_ONLY_ACTIVE_PATHS, out paths, out modes);
        for (int i = 0; i < paths.Length; i++) {
            if (!Same(TargetPath(paths[i].targetInfo), devicePath)) continue;
            uint index = paths[i].sourceInfo.modeInfoIdx;
            if (index >= modes.Length || modes[index].infoType != MODE_SOURCE) return -1;
            modes[index].srcX = x;
            modes[index].srcY = y;
            return SetDisplayConfig((uint)paths.Length, paths, (uint)modes.Length, modes, SDC_FLAGS);
        }
        return -1;
    }
}
'@

$StateDir = Join-Path $env:LOCALAPPDATA 'WoRkPlace'
$StatePath = Join-Path $StateDir 'detached.json'
$LogPath = Join-Path $StateDir 'topology.log'
New-Item -ItemType Directory -Force $StateDir | Out-Null

function Write-Log([string]$text) {
    Add-Content -Path $LogPath -Value ('{0:HH:mm:ss.fff} [{1}] {2}' -f (Get-Date), $Action, $text)
}

function Get-ShortName([string]$path) {
    if ($path -match 'DISPLAY#([^#]+#[^#]+)#') { return $Matches[1] }
    return $path
}

function Get-Screens {
    @([Ccd]::List() | Select-Object *, @{ n = 'IsVdd'; e = { $_.Path -like '*MTT1337*' } }, @{ n = 'Short'; e = { Get-ShortName $_.Path } })
}

function Write-ScreensToLog($screens) {
    foreach ($screen in $screens) {
        Write-Log ("  {0} active={1} primary={2} pos={3},{4} size={5}x{6}" -f $screen.Short, $screen.Active, $screen.Primary, $screen.X, $screen.Y, $screen.Width, $screen.Height)
    }
}

function Read-State {
    if (-not (Test-Path $StatePath)) { return @() }
    try { return @(Get-Content $StatePath -Raw | ConvertFrom-Json | Where-Object { $_.Path }) } catch { return @() }
}

function Write-State($entries) {
    # ConvertTo-Json unwraps a one-element array, so build the brackets by hand.
    $items = @($entries | ForEach-Object { $_ | ConvertTo-Json -Compress })
    [System.IO.File]::WriteAllText($StatePath, '[' + ($items -join ',') + ']')
}

function Wait-Active([string]$path, [bool]$expected) {
    for ($i = 0; $i -lt 20; $i++) {
        $screen = Get-Screens | Where-Object { $_.Path -eq $path }
        if ([bool]$screen.Active -eq $expected) { return $true }
        Start-Sleep -Milliseconds 250
    }
    return $false
}

function Remove-Screen {
    $screens = Get-Screens
    Write-ScreensToLog $screens
    $active = @($screens | Where-Object Active)
    $candidates = @($active | Where-Object { $_.IsVdd -and -not $_.Primary })
    # The user sees the PC only through these displays: never go below one.
    if ($active.Count -le 1 -or $candidates.Count -eq 0) { return @{ ok = $false; code = 'last_screen'; detail = '' } }

    # The one furthest from the primary, so the rest of the layout stays intact.
    $target = $candidates | Sort-Object { [math]::Abs($_.X) + [math]::Abs($_.Y) }, Path | Select-Object -Last 1
    if ($DryRun) { return @{ ok = $true; code = 'dry_run'; detail = "would detach $($target.Short) at $($target.X),$($target.Y)" } }

    $code = [Ccd]::Detach($target.Path)
    Write-Log "Detach $($target.Short) -> $code"
    if ($code -ne 0) { return @{ ok = $false; code = 'failed'; detail = "SetDisplayConfig returned $code for $($target.Short)" } }
    if (-not (Wait-Active $target.Path $false)) { return @{ ok = $false; code = 'failed'; detail = "$($target.Short) is still active" } }

    $state = @(Read-State | Where-Object { $_.Path -ne $target.Path })
    $state += [pscustomobject]@{ Path = $target.Path; X = $target.X; Y = $target.Y }
    Write-State $state
    return @{ ok = $true; code = 'detached'; detail = $target.Short }
}

function Add-Screen {
    $screens = Get-Screens
    Write-ScreensToLog $screens
    $free = @($screens | Where-Object { $_.IsVdd -and -not $_.Active })
    if ($free.Count -eq 0) { return @{ ok = $false; code = 'no_free_screen'; detail = '' } }

    # Remembered monitors first (newest first), then any other detached VDD monitor.
    $state = @(Read-State)
    $plan = @()
    for ($i = $state.Count - 1; $i -ge 0; $i--) {
        if ($free.Path -contains $state[$i].Path) { $plan += [pscustomobject]@{ Path = $state[$i].Path; HasPosition = $true; X = $state[$i].X; Y = $state[$i].Y } }
    }
    foreach ($screen in $free) {
        if ($plan.Path -notcontains $screen.Path) { $plan += [pscustomobject]@{ Path = $screen.Path; HasPosition = $false; X = 0; Y = 0 } }
    }
    if ($DryRun) { return @{ ok = $true; code = 'dry_run'; detail = "would attach $(Get-ShortName $plan[0].Path)" } }

    $errors = @()
    foreach ($entry in $plan) {
        $short = Get-ShortName $entry.Path
        $code = [Ccd]::Attach($entry.Path)
        Write-Log "Attach $short -> $code"
        if ($code -ne 0) { $errors += "${short}: $code"; continue }
        if (-not (Wait-Active $entry.Path $true)) { $errors += "${short}: not active"; continue }
        if ($entry.HasPosition) {
            $code = [Ccd]::SetPosition($entry.Path, $entry.X, $entry.Y)
            Write-Log "SetPosition $short $($entry.X),$($entry.Y) -> $code"
        }
        Write-State @($state | Where-Object { $_.Path -ne $entry.Path })
        return @{ ok = $true; code = 'attached'; detail = $short }
    }
    return @{ ok = $false; code = 'failed'; detail = ($errors -join '; ') }
}

try {
    switch ($Action) {
        'list'   { Get-Screens | Select-Object Short, IsVdd, Active, Primary, X, Y, Width, Height | Format-Table -AutoSize | Out-String -Width 200 | Write-Output; exit 0 }
        'remove' { $result = Remove-Screen }
        'add'    { $result = Add-Screen }
    }
} catch {
    $result = @{ ok = $false; code = 'failed'; detail = "$($_.Exception.Message)" }
}
$result.attached = @(Get-Screens | Where-Object Active).Count
$json = $result | ConvertTo-Json -Compress
if (-not $DryRun) {
    Write-Log $json
    Write-ScreensToLog (Get-Screens)
}
$json
