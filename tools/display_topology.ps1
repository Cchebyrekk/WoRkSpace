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
#   -Action instances  how many MttVDD device instances work (and how many exist)
#   -Action modes    each monitor's mode, the modes it offers and its Windows scale
#   -Action setmode -Monitor \\.\DISPLAY3 -Mode 2560x1440@60 -Scale 150
#                    change one monitor's mode and/or scale (either may be left out)
#   -Action setmodes -Modes "\\.\DISPLAY3=2560x1440@60;\\.\DISPLAY4=1920x544@60"
#                    change several monitors' modes in one step (one window watch)
#
# Prints one JSON line: {"ok":true,"code":"detached","detail":"..","attached":5}
# Monitors are identified by their device path (\\?\DISPLAY#MTT1337#...), which
# survives driver restarts, unlike \\.\DISPLAYnn.
# State: %LOCALAPPDATA%\WoRkPlace\detached.json, log: ...\topology.log
#
# Keep this file ASCII-only: Windows PowerShell 5.1 reads a BOM-less script as ANSI.
# The embedded C# has to stay C# 5 (no string interpolation, no "out var").
param(
    [ValidateSet('list', 'add', 'remove', 'arrange', 'save', 'restore', 'modes', 'setmode', 'setmodes', 'instances')][string]$Action = 'list',
    [string]$Positions = '',
    [string]$Monitor = '',
    [string]$Mode = '',
    [string]$Modes = '',
    [int]$Scale = 0,
    # save/restore: 'start' = the layout before the session (emergency exit),
    # 'apply' = the layout before the driver restart of "Apply".
    [ValidateSet('start', 'apply')][string]$Backup = 'start',
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

    // A window read back from a file (the snapshot taken before "Apply").
    public static SavedWindow Make(long handle, string device, int monitorX, int monitorY, int showCmd,
            int minX, int minY, int maxX, int maxY, int left, int top, int right, int bottom) {
        SavedWindow saved = new SavedWindow();
        saved.Handle = new IntPtr(handle);
        saved.Device = device;
        saved.MonitorX = monitorX; saved.MonitorY = monitorY;
        saved.Placement.length = Marshal.SizeOf(typeof(Placement));
        saved.Placement.showCmd = showCmd;
        saved.Placement.minPosition.X = minX; saved.Placement.minPosition.Y = minY;
        saved.Placement.maxPosition.X = maxX; saved.Placement.maxPosition.Y = maxY;
        saved.Placement.normalPosition.Left = left; saved.Placement.normalPosition.Top = top;
        saved.Placement.normalPosition.Right = right; saved.Placement.normalPosition.Bottom = bottom;
        return saved;
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

    // Active monitors: GDI name (\\.\DISPLAYnn) -> device path.
    public static Dictionary<string, string> GdiToPath() {
        PATH_INFO[] paths; MODE_INFO[] modes;
        Query(QDC_ONLY_ACTIVE_PATHS, out paths, out modes);
        var result = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
        foreach (PATH_INFO path in paths) result[GdiName(path.sourceInfo)] = TargetPath(path.targetInfo);
        return result;
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

    // One monitor's resolution and refresh rate (by GDI name); the target mode is
    // left for Windows to pick from the refresh rate given on the path.
    public static int SetMode(string gdiName, int width, int height, int refresh) {
        PATH_INFO[] paths; MODE_INFO[] modes;
        Query(QDC_ONLY_ACTIVE_PATHS, out paths, out modes);
        for (int i = 0; i < paths.Length; i++) {
            if (!Same(GdiName(paths[i].sourceInfo), gdiName)) continue;
            uint index = paths[i].sourceInfo.modeInfoIdx;
            if (index >= modes.Length || modes[index].infoType != MODE_SOURCE) return -1;
            modes[index].srcWidth = (uint)width;
            modes[index].srcHeight = (uint)height;
            paths[i].targetInfo.modeInfoIdx = INVALID;
            paths[i].targetInfo.refreshNumerator = (uint)refresh;
            paths[i].targetInfo.refreshDenominator = 1;
            return SetDisplayConfig((uint)paths.Length, paths, (uint)modes.Length, modes, SDC_FLAGS);
        }
        return -1;
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
// Display modes (resolution, refresh rate) per monitor and the Windows scale
// ("Settings > Display > Scale"). The scale is set the way that page does it:
// DisplayConfigSetDeviceInfo with the undocumented DPI types (-3 get, -4 set),
// as steps relative to the recommended scale.
public class MonitorModes {
    public string Name;
    public int Width, Height, Refresh, Scale;
    public List<string> Modes = new List<string>();
    public List<int> Scales = new List<int>();
}

public static class DisplayModes {
    public static readonly int[] ScaleSteps = { 100, 125, 150, 175, 200, 225, 250, 300, 350, 400, 450, 500 };

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    struct DEVMODE {
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] public string dmDeviceName;
        public short dmSpecVersion, dmDriverVersion, dmSize, dmDriverExtra; public int dmFields;
        public int dmPositionX, dmPositionY; public int dmDisplayOrientation, dmDisplayFixedOutput;
        public short dmColor, dmDuplex, dmYResolution, dmTTOption, dmCollate;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] public string dmFormName;
        public short dmLogPixels; public int dmBitsPerPel, dmPelsWidth, dmPelsHeight, dmDisplayFlags, dmDisplayFrequency;
        public int dmICMMethod, dmICMIntent, dmMediaType, dmDitherType, dmReserved1, dmReserved2, dmPanningWidth, dmPanningHeight;
    }
    [StructLayout(LayoutKind.Sequential)] struct LUID { public uint LowPart; public int HighPart; }
    [StructLayout(LayoutKind.Sequential)] struct PATH_SOURCE { public LUID adapterId; public uint id; public uint modeInfoIdx; public uint statusFlags; }
    [StructLayout(LayoutKind.Sequential)] struct PATH_TARGET { public LUID adapterId; public uint id; public uint modeInfoIdx; public uint outputTechnology; public uint rotation; public uint scaling; public uint refreshNumerator; public uint refreshDenominator; public uint scanLineOrdering; public int targetAvailable; public uint statusFlags; }
    [StructLayout(LayoutKind.Sequential)] struct PATH_INFO { public PATH_SOURCE sourceInfo; public PATH_TARGET targetInfo; public uint flags; }
    [StructLayout(LayoutKind.Explicit, Size = 64)] struct MODE_INFO { [FieldOffset(0)] public uint infoType; }
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)] struct SOURCE_NAME { public int type; public uint size; public LUID adapterId; public uint id; [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] public string name; }
    [StructLayout(LayoutKind.Sequential)] struct GET_DPI { public int type; public uint size; public LUID adapterId; public uint id; public int minScaleRel; public int curScaleRel; public int maxScaleRel; }
    [StructLayout(LayoutKind.Sequential)] struct SET_DPI { public int type; public uint size; public LUID adapterId; public uint id; public int scaleRel; }

    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern bool EnumDisplaySettings(string name, int mode, ref DEVMODE dm);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int ChangeDisplaySettingsEx(string name, ref DEVMODE dm, IntPtr hwnd, uint flags, IntPtr param);
    [DllImport("user32.dll")] static extern int GetDisplayConfigBufferSizes(uint flags, out uint p, out uint m);
    [DllImport("user32.dll")] static extern int QueryDisplayConfig(uint flags, ref uint p, [In, Out] PATH_INFO[] paths, ref uint m, [In, Out] MODE_INFO[] modes, IntPtr t);
    [DllImport("user32.dll", EntryPoint = "DisplayConfigGetDeviceInfo")] static extern int GetName(ref SOURCE_NAME r);
    [DllImport("user32.dll", EntryPoint = "DisplayConfigGetDeviceInfo")] static extern int GetDpi(ref GET_DPI r);
    [DllImport("user32.dll", EntryPoint = "DisplayConfigSetDeviceInfo")] static extern int SetDpi(ref SET_DPI r);

    static DEVMODE NewMode() { DEVMODE dm = new DEVMODE(); dm.dmSize = (short)Marshal.SizeOf(typeof(DEVMODE)); return dm; }

    // Active sources by GDI name.
    static Dictionary<string, PATH_SOURCE> Sources() {
        uint p, m;
        GetDisplayConfigBufferSizes(2, out p, out m);
        PATH_INFO[] paths = new PATH_INFO[p];
        MODE_INFO[] modes = new MODE_INFO[m];
        QueryDisplayConfig(2, ref p, paths, ref m, modes, IntPtr.Zero);
        var result = new Dictionary<string, PATH_SOURCE>(StringComparer.OrdinalIgnoreCase);
        for (int i = 0; i < p; i++) {
            SOURCE_NAME n = new SOURCE_NAME();
            n.type = 1; n.size = (uint)Marshal.SizeOf(typeof(SOURCE_NAME));
            n.adapterId = paths[i].sourceInfo.adapterId; n.id = paths[i].sourceInfo.id;
            if (GetName(ref n) == 0) result[n.name] = paths[i].sourceInfo;
        }
        return result;
    }

    static bool ReadDpi(PATH_SOURCE source, out GET_DPI dpi) {
        dpi = new GET_DPI();
        dpi.type = -3; dpi.size = (uint)Marshal.SizeOf(typeof(GET_DPI));
        dpi.adapterId = source.adapterId; dpi.id = source.id;
        return GetDpi(ref dpi) == 0;
    }

    public static List<MonitorModes> List() {
        var result = new List<MonitorModes>();
        foreach (var pair in Sources()) {
            MonitorModes item = new MonitorModes();
            item.Name = pair.Key;
            DEVMODE now = NewMode();
            EnumDisplaySettings(pair.Key, -1, ref now);
            item.Width = now.dmPelsWidth; item.Height = now.dmPelsHeight; item.Refresh = now.dmDisplayFrequency;
            var seen = new HashSet<string>();
            for (int i = 0; ; i++) {
                DEVMODE dm = NewMode();
                if (!EnumDisplaySettings(pair.Key, i, ref dm)) break;
                string mode = dm.dmPelsWidth + "x" + dm.dmPelsHeight + "@" + dm.dmDisplayFrequency;
                if (seen.Add(mode)) item.Modes.Add(mode);
            }
            GET_DPI dpi;
            if (ReadDpi(pair.Value, out dpi)) {
                int recommended = -dpi.minScaleRel;
                for (int k = dpi.minScaleRel; k <= dpi.maxScaleRel; k++) {
                    int index = recommended + k;
                    if (index >= 0 && index < ScaleSteps.Length) item.Scales.Add(ScaleSteps[index]);
                }
                int current = recommended + dpi.curScaleRel;
                item.Scale = current >= 0 && current < ScaleSteps.Length ? ScaleSteps[current] : 0;
            }
            result.Add(item);
        }
        return result;
    }

    // 0 on success, a SetDisplayConfig error, or -100 if the mode is not offered.
    // Through the CCD API like the moves: ChangeDisplaySettingsEx re-applied old
    // saved settings to the other monitors (18.10.2026: one went back from
    // 2560x1440 to 1920x1080, another lost its scale).
    public static int SetMode(string name, int width, int height, int refresh) {
        for (int i = 0; ; i++) {
            DEVMODE dm = NewMode();
            if (!EnumDisplaySettings(name, i, ref dm)) break;
            if (dm.dmPelsWidth == width && dm.dmPelsHeight == height && dm.dmDisplayFrequency == refresh) {
                return Ccd.SetMode(name, width, height, refresh);
            }
        }
        return -100;
    }

    // 0 on success, -100 if this scale is not allowed for the monitor, -101 if not found.
    public static int SetScale(string name, int percent) {
        PATH_SOURCE source;
        if (!Sources().TryGetValue(name, out source)) return -101;
        GET_DPI dpi;
        if (!ReadDpi(source, out dpi)) return -101;
        int target = Array.IndexOf(ScaleSteps, percent);
        int relative = target - (-dpi.minScaleRel);
        if (target < 0 || relative < dpi.minScaleRel || relative > dpi.maxScaleRel) return -100;
        SET_DPI set = new SET_DPI();
        set.type = -4; set.size = (uint)Marshal.SizeOf(typeof(SET_DPI));
        set.adapterId = source.adapterId; set.id = source.id; set.scaleRel = relative;
        return SetDpi(ref set);
    }
}

'@

$StateDir = Join-Path $env:LOCALAPPDATA 'WoRkPlace'
$StatePath = Join-Path $StateDir 'detached.json'
$LogPath = Join-Path $StateDir 'topology.log'
$BackupPath = Join-Path $StateDir $(if ($Backup -eq 'apply') { 'layout_apply.json' } else { 'layout_backup.json' })
# With -Backup apply: the windows too, by monitor key (\\.\DISPLAYnn names change with the driver restart).
$WindowsPath = Join-Path $StateDir 'windows_apply.json'
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

# The part of a device path that stays the same when the driver is reinstalled
# (as ScreenPanel.key_of in the app): MTT1337#1&2240405a&UID256.
function Get-Key([string]$path) {
    $parts = $path -split '#'
    if ($parts.Count -lt 3 -or -not $parts[0].EndsWith('DISPLAY')) { return $path }
    $instance = @($parts[2] -split '&')
    if ($instance.Count -eq 4) { $instance = @($instance[0], $instance[1], $instance[3]) }
    return $parts[1] + '#' + ($instance -join '&')
}

# -Monitor <key>: detach that monitor (if it may be detached), else the default choice.
function Remove-Screen {
    $screens = Get-Screens
    Write-ScreensToLog $screens
    $active = @($screens | Where-Object Active)
    $candidates = @($active | Where-Object { $_.IsVdd -and -not $_.Primary })
    # The user sees the PC only through these displays: never go below one.
    if ($active.Count -le 1 -or $candidates.Count -eq 0) { return @{ ok = $false; code = 'last_screen'; detail = '' } }

    # The one furthest from the primary, so the rest of the layout stays intact.
    $target = $candidates | Sort-Object { [math]::Abs($_.X) + [math]::Abs($_.Y) }, Path | Select-Object -Last 1
    if ($Monitor -ne '') {
        $asked = @($candidates | Where-Object { (Get-Key $_.Path) -eq $Monitor })
        if ($asked.Count -gt 0) { $target = $asked[0] }
    }
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
    # -Monitor <key>: that monitor first.
    if ($Monitor -ne '') {
        $plan = @($plan | Where-Object { (Get-Key $_.Path) -eq $Monitor }) + @($plan | Where-Object { (Get-Key $_.Path) -ne $Monitor })
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

function Get-Modes {
    $monitors = @([DisplayModes]::List() | ForEach-Object {
        [ordered]@{ name = $_.Name; width = $_.Width; height = $_.Height; refresh = $_.Refresh; scale = $_.Scale
            modes = @($_.Modes); scales = @($_.Scales) }
    })
    return @{ ok = $true; code = 'modes'; detail = ''; monitors = $monitors }
}

function Get-Instances {
    $all = @(Get-PnpDevice -Class Display -ErrorAction SilentlyContinue | Where-Object { $_.HardwareID -contains 'Root\MttVDD' })
    $working = @($all | Where-Object { $_.Status -eq 'OK' })
    return @{ ok = $true; code = 'instances'; detail = ''; working = $working.Count; total = $all.Count }
}

function Set-Mode {
    if ($Monitor -eq '') { return @{ ok = $false; code = 'failed'; detail = 'no -Monitor' } }
    $done = @()
    # Windows puts a monitor back to its recommended scale when its mode changes:
    # keep the one it had unless a new one is asked for.
    $keepScale = 0
    if ($Mode -ne '' -and $Scale -le 0) {
        $before = [DisplayModes]::List() | Where-Object { $_.Name -eq $Monitor }
        if ($null -ne $before) { $keepScale = $before.Scale }
    }
    if ($Mode -ne '') {
        if ($Mode -notmatch '^(\d+)x(\d+)@(\d+)$') { return @{ ok = $false; code = 'failed'; detail = "bad mode '$Mode'" } }
        if ($DryRun) { return @{ ok = $true; code = 'dry_run'; detail = "$Monitor -> $Mode" } }
        $code = [DisplayModes]::SetMode($Monitor, [int]$Matches[1], [int]$Matches[2], [int]$Matches[3])
        Write-Log "SetMode $Monitor $Mode -> $code"
        if ($code -ne 0) { return @{ ok = $false; code = 'failed'; detail = "mode $Mode on ${Monitor}: $code" } }
        $done += $Mode
    }
    if ($keepScale -gt 0) {
        $code = [DisplayModes]::SetScale($Monitor, $keepScale)
        Write-Log "SetScale $Monitor $keepScale (kept) -> $code"
    }
    if ($Scale -gt 0) {
        if ($DryRun) { return @{ ok = $true; code = 'dry_run'; detail = "$Monitor -> $Scale %" } }
        $code = [DisplayModes]::SetScale($Monitor, $Scale)
        Write-Log "SetScale $Monitor $Scale -> $code"
        if ($code -ne 0) { return @{ ok = $false; code = 'failed'; detail = "scale $Scale on ${Monitor}: $code" } }
        $done += "$Scale %"
    }
    return @{ ok = $true; code = 'mode_set'; detail = "$Monitor $($done -join ', ')" }
}

# Several monitors' modes in one run (23.10.2026: one run per monitor, each with
# its own 5-10 s window watch and a layout step after it, took minutes for nine).
# Each keeps its scale as Set-Mode does; the ones Windows refuses are named.
function Set-Modes {
    $failed = @()
    $set = @()
    foreach ($item in ($Modes -split ';')) {
        if ($item -notmatch '^(.+)=(\d+x\d+@\d+)$') { continue }
        $script:Monitor = $Matches[1]
        $script:Mode = $Matches[2]
        $script:Scale = 0
        $one = Set-Mode
        if ($one.ok) { $set += "$Monitor $Mode" } else { $failed += "$Monitor $Mode" }
    }
    if ($failed.Count -gt 0) { return @{ ok = $false; code = 'failed'; detail = "refused: $($failed -join ', ')"; set = $set.Count } }
    return @{ ok = $true; code = 'modes_set'; detail = ($set -join ', ') }
}

function Save-Layout {
    $screens = Get-Screens
    Write-ScreensToLog $screens
    $items = @($screens | ForEach-Object { [pscustomobject]@{ Path = $_.Path; Active = [bool]$_.Active; X = $_.X; Y = $_.Y } | ConvertTo-Json -Compress })
    if (-not $DryRun) { [System.IO.File]::WriteAllText($BackupPath, '[' + ($items -join ',') + ']') }
    if ($Backup -eq 'apply') {
        $paths = [Ccd]::GdiToPath()
        $windows = @([WindowKeeper]::Snapshot() | Where-Object { $paths.ContainsKey($_.Device) } | ForEach-Object {
            $p = $_.Placement
            [pscustomobject]@{ Handle = $_.Handle.ToInt64(); Key = (Get-Key $paths[$_.Device]); MonitorX = $_.MonitorX; MonitorY = $_.MonitorY
                ShowCmd = $p.showCmd; MinX = $p.minPosition.X; MinY = $p.minPosition.Y; MaxX = $p.maxPosition.X; MaxY = $p.maxPosition.Y
                Left = $p.normalPosition.Left; Top = $p.normalPosition.Top; Right = $p.normalPosition.Right; Bottom = $p.normalPosition.Bottom } | ConvertTo-Json -Compress
        })
        Write-Log "$($windows.Count) windows remembered"
        if (-not $DryRun) { [System.IO.File]::WriteAllText($WindowsPath, '[' + ($windows -join ',') + ']') }
    }
    return @{ ok = $true; code = 'saved'; detail = "$(@($screens | Where-Object Active).Count) active" }
}

# The local list is not called $backup: PowerShell names ignore case, and it would
# overwrite the -Backup parameter (the windows were never put back, 19.10.2026).
function Restore-Layout {
    if (-not (Test-Path $BackupPath)) { return @{ ok = $false; code = 'no_backup'; detail = '' } }
    $parsed = Get-Content $BackupPath -Raw | ConvertFrom-Json
    $remembered = @($parsed | Where-Object { $_.Path -is [string] })
    $screens = Get-Screens
    Write-ScreensToLog $screens
    # A driver restart may change the middle of a device path: such a monitor is
    # found by its key.
    foreach ($entry in $remembered) {
        if (@($screens | Where-Object { $_.Path -eq $entry.Path }).Count -gt 0) { continue }
        $same = @($screens | Where-Object { (Get-Key $_.Path) -eq (Get-Key $entry.Path) })
        if ($same.Count -gt 0) { $entry.Path = $same[0].Path }
    }
    if ($DryRun) { return @{ ok = $true; code = 'dry_run'; detail = "$($remembered.Count) remembered: $(@($remembered | Where-Object Active | ForEach-Object { Get-ShortName $_.Path }) -join ', ') attached" } }
    $errors = @()
    $state = @(Read-State)

    # Attach first, so the number of screens never drops on the way.
    foreach ($entry in @($remembered | Where-Object Active)) {
        $screen = $screens | Where-Object { $_.Path -eq $entry.Path }
        if ($null -eq $screen -or $screen.Active) { continue }
        $code = [Ccd]::Attach($entry.Path)
        Write-Log "Attach $(Get-ShortName $entry.Path) -> $code"
        if ($code -ne 0 -or -not (Wait-Active $entry.Path $true)) { $errors += "attach $(Get-ShortName $entry.Path): $code"; continue }
        $state = @($state | Where-Object { $_.Path -ne $entry.Path })
    }
    # Then detach VDD monitors that were not attached before; never the primary, never the last.
    foreach ($screen in @(Get-Screens | Where-Object { $_.Active -and $_.IsVdd -and -not $_.Primary })) {
        $entry = $remembered | Where-Object { $_.Path -eq $screen.Path }
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
    $place = @($remembered | Where-Object { $_.Active -and ($active.Path -contains $_.Path) })
    if ($place.Count -gt 0) {
        $code = [Ccd]::SetPositions([string[]]@($place.Path), [int[]]@($place | ForEach-Object { $_.X }), [int[]]@($place | ForEach-Object { $_.Y }), $false)
        Write-Log "SetPositions ($($place.Count)) -> $code"
        if ($code -ne 0) { $errors += "positions: $code" }
    }
    if ($Backup -eq 'apply') { $script:windows = Read-SavedWindows }
    if ($errors.Count -gt 0) { return @{ ok = $false; code = 'failed'; detail = ($errors -join '; ') } }
    return @{ ok = $true; code = 'restored'; detail = '' }
}

# The windows remembered before "Apply", on the monitors' current GDI names.
function Read-SavedWindows {
    $result = New-Object 'System.Collections.Generic.List[SavedWindow]'
    if (-not (Test-Path $WindowsPath)) { return ,$result }
    $byKey = @{}
    foreach ($entry in ([Ccd]::GdiToPath()).GetEnumerator()) { $byKey[(Get-Key $entry.Value)] = $entry.Key }
    $parsed = Get-Content $WindowsPath -Raw | ConvertFrom-Json
    foreach ($w in @($parsed | Where-Object { $null -ne $_.Key })) {
        if (-not $byKey.ContainsKey($w.Key)) { continue }
        $result.Add([WindowKeeper]::Make([int64]$w.Handle, $byKey[$w.Key], $w.MonitorX, $w.MonitorY, $w.ShowCmd,
            $w.MinX, $w.MinY, $w.MaxX, $w.MaxY, $w.Left, $w.Top, $w.Right, $w.Bottom))
    }
    Remove-Item $WindowsPath -ErrorAction SilentlyContinue
    Write-Log "$($result.Count) windows to put back from before Apply"
    return ,$result
}

try {
    $windows = $null
    if (-not $DryRun -and @('add', 'remove', 'arrange', 'restore', 'setmode', 'setmodes') -contains $Action) { $windows = [WindowKeeper]::Snapshot() }
    switch ($Action) {
        'list'    { Get-Screens | Select-Object Short, IsVdd, Active, Primary, X, Y, Width, Height | Format-Table -AutoSize | Out-String -Width 200 | Write-Output; exit 0 }
        'remove'  { $result = Remove-Screen }
        'add'     { $result = Add-Screen }
        'arrange' { $result = Set-Arrangement }
        'save'    { $result = Save-Layout }
        'restore' { $result = Restore-Layout }
        'modes'   { $result = Get-Modes }
        'setmode' { $result = Set-Mode }
        'setmodes' { $result = Set-Modes }
        'instances' { $result = Get-Instances }
    }
} catch {
    $result = @{ ok = $false; code = 'failed'; detail = "$($_.Exception.Message)" }
}
if ($null -ne $windows) {
    try { Restore-Windows $windows } catch { Write-Log "Windows: $($_.Exception.Message)" }
}
$result.attached = @(Get-Screens | Where-Object Active).Count
$json = $result | ConvertTo-Json -Compress -Depth 5
if (-not $DryRun) {
    Write-Log $json
    Write-ScreensToLog (Get-Screens)
}
$json
