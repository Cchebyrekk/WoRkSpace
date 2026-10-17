# Detaches one virtual (MttVDD) monitor from the Windows desktop or attaches it
# back, the same way "Disconnect this display" does in Windows settings. Uses the
# CCD API (QueryDisplayConfig / SetDisplayConfig); no device is disabled and no
# driver restarts, so no admin rights are needed.
#
#   -Action list     print the displays
#   -Action remove   detach one active VDD monitor (never the primary, never the last)
#   -Action add      re-attach the most recently detached one at its old position
#   -Action arrange -Positions "\\.\DISPLAY3=0,0;\\.\DISPLAY4=1920,0"
#                    move monitors (by GDI name, as the app sees them) in one step
#   -Action save     remember the current layout and which monitors are attached
#   -Action restore  bring back the remembered layout (re-attach / detach VDD
#                    monitors, then positions); never leaves fewer than one screen
#
# Prints one JSON line: {"ok":true,"code":"detached","detail":"..","attached":5}
# Monitors are identified by their device path (\\?\DISPLAY#MTT1337#...), which
# survives driver restarts, unlike \\.\DISPLAYnn.
# State: %LOCALAPPDATA%\WoRkPlace\detached.json, log: ...\topology.log
#
# Keep this file ASCII-only: Windows PowerShell 5.1 reads a BOM-less script as ANSI.
# The embedded C# has to stay C# 5 (no string interpolation, no "out var").
param(
    [ValidateSet('list', 'add', 'remove', 'arrange', 'save', 'restore')][string]$Action = 'list',
    [string]$Positions = '',
    [switch]$DryRun
)

$ErrorActionPreference = 'Stop'

$CcdSource = @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;

// Top-level windows and where they were, so that they can be put back on their own
// monitor after a layout change: Windows piles them onto the primary otherwise.
public class SavedWindow {
    public IntPtr Handle;
    public string Device;
    public int MonitorX, MonitorY;
    public WindowKeeper.Placement Placement;
}

public static class WindowKeeper {
    [StructLayout(LayoutKind.Sequential)]
    public struct RECT { public int Left, Top, Right, Bottom; }
    [StructLayout(LayoutKind.Sequential)]
    public struct POINT { public int X, Y; }
    [StructLayout(LayoutKind.Sequential)]
    public struct Placement {
        public int length; public int flags; public int showCmd;
        public POINT minPosition; public POINT maxPosition; public RECT normalPosition;
    }
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    struct MONITORINFOEX {
        public int cbSize; public RECT rcMonitor; public RECT rcWork; public uint dwFlags;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] public string szDevice;
    }
    delegate bool EnumProc(IntPtr hwnd, IntPtr param);
    delegate bool MonitorProc(IntPtr monitor, IntPtr hdc, IntPtr rect, IntPtr param);

    [DllImport("user32.dll")] static extern bool EnumWindows(EnumProc proc, IntPtr param);
    [DllImport("user32.dll")] static extern bool EnumDisplayMonitors(IntPtr hdc, IntPtr clip, MonitorProc proc, IntPtr param);
    [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr hwnd);
    [DllImport("user32.dll")] static extern int GetWindowTextLength(IntPtr hwnd);
    [DllImport("user32.dll")] static extern int GetWindowLong(IntPtr hwnd, int index);
    [DllImport("user32.dll")] static extern IntPtr GetWindow(IntPtr hwnd, uint command);
    [DllImport("user32.dll")] static extern IntPtr MonitorFromWindow(IntPtr hwnd, uint flags);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern bool GetMonitorInfo(IntPtr monitor, ref MONITORINFOEX info);
    [DllImport("user32.dll")] static extern bool GetWindowPlacement(IntPtr hwnd, ref Placement placement);
    [DllImport("user32.dll")] static extern bool SetWindowPlacement(IntPtr hwnd, ref Placement placement);
    [DllImport("user32.dll")] static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] static extern bool SetForegroundWindow(IntPtr hwnd);
    [DllImport("user32.dll")] static extern bool ShowWindowAsync(IntPtr hwnd, int command);
    [DllImport("user32.dll")] static extern IntPtr SetThreadDpiAwarenessContext(IntPtr context);
    [DllImport("dwmapi.dll")] static extern int DwmGetWindowAttribute(IntPtr hwnd, int attribute, out int value, int size);
    [DllImport("user32.dll")] static extern IntPtr SendMessageTimeout(IntPtr hwnd, uint message, IntPtr wParam, IntPtr lParam, uint flags, uint timeout, out IntPtr result);

    // SetWindowPlacement waits for the window's thread; one that is busy (the app
    // itself waiting for this script, or a hung program) would block us for good.
    static bool Responds(IntPtr hwnd) {
        IntPtr ignored;
        return SendMessageTimeout(hwnd, 0, IntPtr.Zero, IntPtr.Zero, 0x2, 200, out ignored) != IntPtr.Zero; // WM_NULL, SMTO_ABORTIFHUNG
    }

    // Real pixels, not the 96-DPI virtualised ones.
    public static void PerMonitorDpi() { SetThreadDpiAwarenessContext(new IntPtr(-4)); }

    static bool MonitorBounds(IntPtr monitor, out string device, out RECT bounds) {
        MONITORINFOEX info = new MONITORINFOEX();
        info.cbSize = Marshal.SizeOf(typeof(MONITORINFOEX));
        bool ok = monitor != IntPtr.Zero && GetMonitorInfo(monitor, ref info);
        device = ok ? info.szDevice : "";
        bounds = info.rcMonitor;
        return ok;
    }

    public static List<SavedWindow> Snapshot() {
        var result = new List<SavedWindow>();
        EnumWindows(delegate (IntPtr hwnd, IntPtr param) {
            if (!IsWindowVisible(hwnd) || GetWindowTextLength(hwnd) == 0) return true;
            if (GetWindow(hwnd, 4) != IntPtr.Zero) return true; // owned (dialogs move with their owner)
            if ((GetWindowLong(hwnd, -20) & 0x80) != 0) return true; // WS_EX_TOOLWINDOW
            int cloaked;
            if (DwmGetWindowAttribute(hwnd, 14, out cloaked, 4) == 0 && cloaked != 0) return true;
            SavedWindow saved = new SavedWindow();
            saved.Handle = hwnd;
            saved.Placement.length = Marshal.SizeOf(typeof(Placement));
            if (!GetWindowPlacement(hwnd, ref saved.Placement)) return true;
            RECT bounds;
            if (!MonitorBounds(MonitorFromWindow(hwnd, 2), out saved.Device, out bounds)) return true;
            saved.MonitorX = bounds.Left; saved.MonitorY = bounds.Top;
            result.Add(saved);
            return true;
        }, IntPtr.Zero);
        return result;
    }

    // Puts each window back on the monitor it was on, at the same place relative to
    // that monitor. Returns how many had to be moved.
    public static int Restore(List<SavedWindow> saved) {
        var monitors = new Dictionary<string, RECT>(StringComparer.OrdinalIgnoreCase);
        EnumDisplayMonitors(IntPtr.Zero, IntPtr.Zero, delegate (IntPtr monitor, IntPtr hdc, IntPtr rect, IntPtr param) {
            string device; RECT bounds;
            if (MonitorBounds(monitor, out device, out bounds)) monitors[device] = bounds;
            return true;
        }, IntPtr.Zero);
        IntPtr foreground = GetForegroundWindow();
        int moved = 0;
        foreach (SavedWindow window in saved) {
            RECT target;
            if (!monitors.TryGetValue(window.Device, out target)) continue;
            Placement wanted = window.Placement;
            Shift(ref wanted.normalPosition, target.Left - window.MonitorX, target.Top - window.MonitorY);
            bool maximized = wanted.showCmd == 3;
            // A window Windows had already piled onto another monitor may keep a restore
            // rectangle there: bring it onto its own monitor, or it maximizes in the wrong place.
            int centreX = (wanted.normalPosition.Left + wanted.normalPosition.Right) / 2;
            int centreY = (wanted.normalPosition.Top + wanted.normalPosition.Bottom) / 2;
            if (centreX < target.Left || centreX >= target.Right || centreY < target.Top || centreY >= target.Bottom) {
                Shift(ref wanted.normalPosition, target.Left + 40 - wanted.normalPosition.Left, target.Top + 40 - wanted.normalPosition.Top);
            }
            Placement now = new Placement();
            now.length = Marshal.SizeOf(typeof(Placement));
            if (!GetWindowPlacement(window.Handle, ref now)) continue;
            string device; RECT bounds;
            bool sameMonitor = MonitorBounds(MonitorFromWindow(window.Handle, 2), out device, out bounds)
                && string.Equals(device, window.Device, StringComparison.OrdinalIgnoreCase);
            if (sameMonitor && (maximized || (now.normalPosition.Left == wanted.normalPosition.Left && now.normalPosition.Top == wanted.normalPosition.Top))) continue;
            if (!Responds(window.Handle)) continue;
            // Restored first (without taking the focus) on its monitor; a maximized window
            // then maximizes there: SetWindowPlacement alone leaves it where it is maximized now.
            wanted.flags = 0;
            wanted.showCmd = wanted.showCmd == 2 ? 7 : 4;
            if (!SetWindowPlacement(window.Handle, ref wanted)) continue;
            if (maximized) ShowWindowAsync(window.Handle, 3);
            moved++;
        }
        if (foreground != IntPtr.Zero && Responds(foreground)) SetForegroundWindow(foreground);
        return moved;
    }

    static void Shift(ref RECT rect, int dx, int dy) {
        rect.Left += dx; rect.Right += dx; rect.Top += dy; rect.Bottom += dy;
    }
}

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

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    struct SOURCE_NAME {
        public uint type; public uint size; public LUID adapterId; public uint id;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] public string viewGdiDeviceName;
    }
    [DllImport("user32.dll", EntryPoint = "DisplayConfigGetDeviceInfo")] static extern int GetSourceName(ref SOURCE_NAME request);

    static string GdiName(PATH_SOURCE source) {
        SOURCE_NAME request = new SOURCE_NAME();
        request.type = 1; // DISPLAYCONFIG_DEVICE_INFO_GET_SOURCE_NAME
        request.size = (uint)Marshal.SizeOf(typeof(SOURCE_NAME));
        request.adapterId = source.adapterId;
        request.id = source.id;
        return GetSourceName(ref request) == 0 ? request.viewGdiDeviceName : "";
    }

    // Moves the given monitors in one SetDisplayConfig call. `byGdiName`: the keys are
    // \\.\DISPLAYnn names, otherwise device paths. -1 if one of them is not active.
    public static int SetPositions(string[] names, int[] xs, int[] ys, bool byGdiName) {
        PATH_INFO[] paths; MODE_INFO[] modes;
        Query(QDC_ONLY_ACTIVE_PATHS, out paths, out modes);
        for (int n = 0; n < names.Length; n++) {
            bool found = false;
            for (int i = 0; i < paths.Length; i++) {
                string name = byGdiName ? GdiName(paths[i].sourceInfo) : TargetPath(paths[i].targetInfo);
                if (!Same(name, names[n])) continue;
                uint index = paths[i].sourceInfo.modeInfoIdx;
                if (index >= modes.Length || modes[index].infoType != MODE_SOURCE) continue;
                modes[index].srcX = xs[n];
                modes[index].srcY = ys[n];
                found = true;
            }
            if (!found) return -1;
        }
        return SetDisplayConfig((uint)paths.Length, paths, (uint)modes.Length, modes, SDC_FLAGS);
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
$BackupPath = Join-Path $StateDir 'layout_backup.json'
New-Item -ItemType Directory -Force $StateDir | Out-Null

# Compiling the C# takes about a second on every run: keep the compiled assembly,
# named by a hash of the source so that an edited script builds a new one.
$sha = [System.Security.Cryptography.SHA1]::Create()
$hash = ([System.BitConverter]::ToString($sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($CcdSource))) -replace '-', '').Substring(0, 12)
$AssemblyPath = Join-Path $StateDir "ccd_$hash.dll"
if (-not (Test-Path $AssemblyPath)) {
    Get-ChildItem $StateDir -Filter 'ccd_*.dll' -ErrorAction SilentlyContinue | Remove-Item -ErrorAction SilentlyContinue
    Add-Type -TypeDefinition $CcdSource -OutputAssembly $AssemblyPath -OutputType Library
}
Add-Type -Path $AssemblyPath
[WindowKeeper]::PerMonitorDpi()

# Windows moves windows itself a moment after a layout change; put them back after it.
# Measured on 17.10.2026: a window was still moved 3.8 s after the change, so keep
# watching for up to 10 s and stop once nothing has moved for 2.5 s (at least 5 s).
function Restore-Windows($saved) {
    $total = 0
    $started = Get-Date
    $lastMove = $started
    while ($true) {
        Start-Sleep -Milliseconds 400
        $moved = [WindowKeeper]::Restore($saved)
        $now = Get-Date
        if ($moved -gt 0) { $total += $moved; $lastMove = $now }
        $elapsed = ($now - $started).TotalSeconds
        if ($elapsed -ge 10 -or ($elapsed -ge 5 -and ($now - $lastMove).TotalSeconds -ge 2.5)) { break }
    }
    Write-Log ("Windows: {0} remembered, {1} moved back, watched {2:N1} s" -f $saved.Count, $total, ($now - $started).TotalSeconds)
}

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
    try {
        # Through a variable: ConvertFrom-Json sends an array down the pipeline as ONE object.
        $parsed = Get-Content $StatePath -Raw | ConvertFrom-Json
        return @($parsed | Where-Object { $_.Path -is [string] })
    } catch { return @() }
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

function Set-Arrangement {
    $names = @(); $xs = @(); $ys = @()
    foreach ($item in ($Positions -split ';')) {
        if ($item -notmatch '^(.+)=(-?\d+),(-?\d+)$') { continue }
        $names += $Matches[1]; $xs += [int]$Matches[2]; $ys += [int]$Matches[3]
    }
    if ($names.Count -eq 0) { return @{ ok = $false; code = 'failed'; detail = "no positions in '$Positions'" } }
    Write-ScreensToLog (Get-Screens)
    if ($DryRun) { return @{ ok = $true; code = 'dry_run'; detail = $Positions } }
    $code = [Ccd]::SetPositions([string[]]$names, [int[]]$xs, [int[]]$ys, $true)
    Write-Log "Arrange $Positions -> $code"
    if ($code -ne 0) { return @{ ok = $false; code = 'failed'; detail = "SetDisplayConfig returned $code" } }
    return @{ ok = $true; code = 'arranged'; detail = '' }
}

function Save-Layout {
    $screens = Get-Screens
    Write-ScreensToLog $screens
    $items = @($screens | ForEach-Object { [pscustomobject]@{ Path = $_.Path; Active = [bool]$_.Active; X = $_.X; Y = $_.Y } | ConvertTo-Json -Compress })
    if (-not $DryRun) { [System.IO.File]::WriteAllText($BackupPath, '[' + ($items -join ',') + ']') }
    return @{ ok = $true; code = 'saved'; detail = "$(@($screens | Where-Object Active).Count) active" }
}

function Restore-Layout {
    if (-not (Test-Path $BackupPath)) { return @{ ok = $false; code = 'no_backup'; detail = '' } }
    $parsed = Get-Content $BackupPath -Raw | ConvertFrom-Json
    $backup = @($parsed | Where-Object { $_.Path -is [string] })
    $screens = Get-Screens
    Write-ScreensToLog $screens
    if ($DryRun) { return @{ ok = $true; code = 'dry_run'; detail = "$($backup.Count) remembered" } }
    $errors = @()
    $state = @(Read-State)

    # Attach first, so the number of screens never drops on the way.
    foreach ($entry in @($backup | Where-Object Active)) {
        $screen = $screens | Where-Object { $_.Path -eq $entry.Path }
        if ($null -eq $screen -or $screen.Active) { continue }
        $code = [Ccd]::Attach($entry.Path)
        Write-Log "Attach $(Get-ShortName $entry.Path) -> $code"
        if ($code -ne 0 -or -not (Wait-Active $entry.Path $true)) { $errors += "attach $(Get-ShortName $entry.Path): $code"; continue }
        $state = @($state | Where-Object { $_.Path -ne $entry.Path })
    }
    # Then detach VDD monitors that were not attached before; never the primary, never the last.
    foreach ($screen in @(Get-Screens | Where-Object { $_.Active -and $_.IsVdd -and -not $_.Primary })) {
        $entry = $backup | Where-Object { $_.Path -eq $screen.Path }
        if ($null -eq $entry -or $entry.Active) { continue }
        if (@(Get-Screens | Where-Object Active).Count -le 1) { break }
        $code = [Ccd]::Detach($screen.Path)
        Write-Log "Detach $($screen.Short) -> $code"
        if ($code -ne 0 -or -not (Wait-Active $screen.Path $false)) { $errors += "detach $($screen.Short): $code"; continue }
        $state = @($state | Where-Object { $_.Path -ne $screen.Path })
        $state += [pscustomobject]@{ Path = $screen.Path; X = $screen.X; Y = $screen.Y }
    }
    Write-State $state

    # Positions of everything that is attached now and was attached then.
    $active = @(Get-Screens | Where-Object Active)
    $place = @($backup | Where-Object { $_.Active -and ($active.Path -contains $_.Path) })
    if ($place.Count -gt 0) {
        $code = [Ccd]::SetPositions([string[]]@($place.Path), [int[]]@($place | ForEach-Object { $_.X }), [int[]]@($place | ForEach-Object { $_.Y }), $false)
        Write-Log "SetPositions ($($place.Count)) -> $code"
        if ($code -ne 0) { $errors += "positions: $code" }
    }
    if ($errors.Count -gt 0) { return @{ ok = $false; code = 'failed'; detail = ($errors -join '; ') } }
    return @{ ok = $true; code = 'restored'; detail = '' }
}

try {
    $windows = $null
    if (-not $DryRun -and @('add', 'remove', 'arrange', 'restore') -contains $Action) { $windows = [WindowKeeper]::Snapshot() }
    switch ($Action) {
        'list'    { Get-Screens | Select-Object Short, IsVdd, Active, Primary, X, Y, Width, Height | Format-Table -AutoSize | Out-String -Width 200 | Write-Output; exit 0 }
        'remove'  { $result = Remove-Screen }
        'add'     { $result = Add-Screen }
        'arrange' { $result = Set-Arrangement }
        'save'    { $result = Save-Layout }
        'restore' { $result = Restore-Layout }
    }
} catch {
    $result = @{ ok = $false; code = 'failed'; detail = "$($_.Exception.Message)" }
}
if ($null -ne $windows) {
    try { Restore-Windows $windows } catch { Write-Log "Windows: $($_.Exception.Message)" }
}
$result.attached = @(Get-Screens | Where-Object Active).Count
$json = $result | ConvertTo-Json -Compress
if (-not $DryRun) {
    Write-Log $json
    Write-ScreensToLog (Get-Screens)
}
$json
