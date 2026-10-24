// Win32 helpers for the boot-intro keeper.
// Compile to wbhelper.dll (see build-helper.ps1) so the keeper starts in
// ~0.3s instead of ~2s; wbutil.ps1 falls back to compiling this source
// inline if the DLL is missing.
using System;
using System.Text;
using System.Runtime.InteropServices;

public class WBIntro {
    [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint procId);
    [DllImport("kernel32.dll")] public static extern uint GetCurrentThreadId();
    [DllImport("user32.dll")] public static extern bool AttachThreadInput(uint idAttach, uint idAttachTo, bool fAttach);
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr hWnd);
    [DllImport("user32.dll")] public static extern bool BringWindowToTop(IntPtr hWnd);
    [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr hWnd, IntPtr hWndInsertAfter, int X, int Y, int cx, int cy, uint uFlags);
    [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
    [DllImport("user32.dll")] public static extern bool EnumWindows(EnumWindowsProc lpEnumFunc, IntPtr lParam);
    public delegate bool EnumWindowsProc(IntPtr hWnd, IntPtr lParam);
    [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr hWnd);
    [DllImport("user32.dll")] public static extern bool IsIconic(IntPtr hWnd);
    [DllImport("user32.dll")] public static extern bool IsZoomed(IntPtr hWnd);
    [DllImport("user32.dll")] public static extern int GetSystemMetrics(int nIndex);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetWindowText(IntPtr hWnd, StringBuilder lpString, int nMaxCount);
    [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr hWnd, out RECT lpRect);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern IntPtr FindWindow(string lpClassName, string lpWindowName);

    public static readonly IntPtr HWND_TOPMOST    = (IntPtr)(-1);
    public static readonly IntPtr HWND_NOTOPMOST = (IntPtr)(-2);
    public const uint SWP_NOSIZE     = 0x0001;
    public const uint SWP_NOMOVE     = 0x0002;
    public const uint SWP_NOZORDER   = 0x0004;
    public const uint SWP_NOACTIVATE = 0x0010;
    public const int  SW_RESTORE     = 9;
    public const int  SM_CXSCREEN    = 0;
    public const int  SM_CYSCREEN    = 1;

    public static string Title(IntPtr h) {
        var sb = new StringBuilder(256);
        GetWindowText(h, sb, 256);
        return sb.ToString();
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct RECT {
        public int Left, Top, Right, Bottom;
    }

    // FindWindow(null, title) from PowerShell needs a C# wrapper: passing
    // $null to a string parameter marshals as "" (matches nothing), not
    // as a real NULL class name (matches any class).
    public static IntPtr FindWindowByTitle(string title) {
        return FindWindow(null, title);
    }

    // Electron main processes expose a ZERO MainWindowHandle to
    // Get-Process, so the naive PowerShell window search misses the window
    // entirely.  Walk every top-level window and return the first one
    // owned by a process whose PID is in `pids` (preferring a window that
    // actually has a title, i.e. the real main window).  Returns Zero if
    // none found.

    public static IntPtr FindWindowByPids(int[] pids) {
        IntPtr found = IntPtr.Zero;
        EnumWindows(delegate(IntPtr hWnd, IntPtr lParam) {
            uint pid = 0;
            GetWindowThreadProcessId(hWnd, out pid);
            if (System.Array.IndexOf(pids, (int)pid) >= 0) {
                if (found == IntPtr.Zero) found = hWnd;
                string t = Title(hWnd);
                if (t != null && t.Length > 0) { found = hWnd; return false; }
            }
            return true;
        }, IntPtr.Zero);
        return found;
    }

    public static int ProcessIdOf(IntPtr h) {
        uint p = 0;
        GetWindowThreadProcessId(h, out p);
        return (int)p;
    }

    // Debug helper: one line per top-level window owned by any of `pids`.
    // wbutil.ps1 parses this line format to pick the app's real main window
    // (Electron apps create tiny splash/IME windows first); keep the format
    // in sync with the regex there.
    public static string ListWindowsByPids(int[] pids) {
        var sb = new StringBuilder();
        EnumWindows(delegate(IntPtr hWnd, IntPtr lParam) {
            uint pid = 0;
            GetWindowThreadProcessId(hWnd, out pid);
            if (System.Array.IndexOf(pids, (int)pid) >= 0) {
                RECT r;
                if (GetWindowRect(hWnd, out r)) {
                    sb.AppendFormat("hwnd=0x{0:X} pid={1} rect={2}x{3}@({4},{5}) vis={6} zoom={7} title='{8}'",
                        hWnd.ToInt64(), pid, r.Right - r.Left, r.Bottom - r.Top, r.Left, r.Top,
                        IsWindowVisible(hWnd), IsZoomed(hWnd), Title(hWnd));
                    sb.AppendLine();
                }
            }
            return true;
        }, IntPtr.Zero);
        return sb.ToString();
    }

    // Take the foreground from whatever window owns it right now.  A plain
    // SetForegroundWindow from a background process is ignored by Windows,
    // so we briefly attach our thread's input state to the current
    // foreground thread first -- same user, same integrity level.
    public static void ForceForeground(IntPtr h) {
        uint pid = 0;
        IntPtr fg = GetForegroundWindow();
        uint fgThread = GetWindowThreadProcessId(fg, out pid);
        uint me = GetCurrentThreadId();
        if (fgThread != 0 && fgThread != me) AttachThreadInput(me, fgThread, true);
        SetForegroundWindow(h);
        BringWindowToTop(h);
        if (fgThread != 0 && fgThread != me) AttachThreadInput(me, fgThread, false);
    }
}
