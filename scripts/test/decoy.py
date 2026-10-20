"""Aggressive foreground-stealer decoy for testing the intro keeper.

Mimics a cold-start app window: after a delay it creates a real top-level
window and repeatedly GRABS the foreground (AttachThreadInput +
SetForegroundWindow, the same trick a focused app window uses).  If the
keeper works, this window never comes to the front while the intro plays.

usage: decoy.py [steal_seconds] [delay_seconds] [window_title]
"""
import ctypes
import ctypes.wintypes as w
import sys
import threading
import time

user32 = ctypes.windll.user32
kernel32 = ctypes.windll.kernel32

WS_POPUP = 0x80000000
WS_VISIBLE = 0x10000000
SW_SHOW = 5
WM_DESTROY = 0x0002

# 64-bit safe prototypes (handles are pointers!)
user32.GetForegroundWindow.restype = w.HWND
user32.GetWindowThreadProcessId.argtypes = [w.HWND, ctypes.POINTER(ctypes.c_ulong)]
user32.GetWindowThreadProcessId.restype = ctypes.c_ulong
user32.AttachThreadInput.argtypes = [ctypes.c_ulong, ctypes.c_ulong, w.BOOL]
user32.SetForegroundWindow.argtypes = [w.HWND]
user32.SetForegroundWindow.restype = w.BOOL
user32.BringWindowToTop.argtypes = [w.HWND]
user32.BringWindowToTop.restype = w.BOOL
user32.CreateWindowExW.restype = w.HWND
user32.DefWindowProcW.argtypes = [w.HWND, ctypes.c_uint, ctypes.c_size_t, ctypes.c_longlong]
user32.DefWindowProcW.restype = ctypes.c_longlong
kernel32.GetCurrentThreadId.restype = ctypes.c_ulong

WNDPROC = ctypes.WINFUNCTYPE(ctypes.c_longlong, w.HWND, ctypes.c_uint,
                             ctypes.c_longlong, ctypes.c_longlong)


class WNDCLASSW(ctypes.Structure):
    _fields_ = [
        ('style', ctypes.c_uint),
        ('lpfnWndProc', WNDPROC),
        ('cbClsExtra', ctypes.c_int),
        ('cbWndExtra', ctypes.c_int),
        ('hInstance', w.HINSTANCE),
        ('hIcon', w.HICON),
        ('hCursor', w.HANDLE),
        ('hbrBackground', w.HANDLE),
        ('lpszMenuName', w.LPCWSTR),
        ('lpszClassName', w.LPCWSTR),
    ]


class MSG(ctypes.Structure):
    _fields_ = [
        ('hwnd', w.HWND), ('message', ctypes.c_uint),
        ('wParam', ctypes.c_size_t), ('lParam', ctypes.c_longlong),
        ('time', ctypes.c_uint), ('pt', w.POINT),
    ]


def wndproc(h, m, wp, lp):
    if m == WM_DESTROY:
        user32.PostQuitMessage(0)
        return 0
    return user32.DefWindowProcW(h, m, wp, lp)


def main():
    steal_s = float(sys.argv[1]) if len(sys.argv) > 1 else 6.0
    delay_s = float(sys.argv[2]) if len(sys.argv) > 2 else 0.0
    title = sys.argv[3] if len(sys.argv) > 3 else 'DECOY-STEALER'

    if delay_s > 0:
        time.sleep(delay_s)

    proc = WNDPROC(wndproc)
    hinst = kernel32.GetModuleHandleW(None)
    wc = WNDCLASSW()
    wc.lpfnWndProc = proc
    wc.hInstance = hinst
    wc.lpszClassName = 'DecoyStealer'
    user32.RegisterClassW(ctypes.byref(wc))

    hwnd = user32.CreateWindowExW(
        0, 'DecoyStealer', title,
        WS_POPUP | WS_VISIBLE, 300, 250, 480, 260,
        None, None, hinst, None)
    if not hwnd:
        sys.exit('CreateWindowExW failed')
    user32.ShowWindow(hwnd, SW_SHOW)
    user32.UpdateWindow(hwnd)

    def pump():
        msg = MSG()
        while user32.GetMessageW(ctypes.byref(msg), None, 0, 0):
            user32.TranslateMessage(ctypes.byref(msg))
            user32.DispatchMessageW(ctypes.byref(msg))

    threading.Thread(target=pump, daemon=True).start()

    print('decoy: stealing foreground for %.1fs (hwnd=%s)' % (steal_s, hwnd), flush=True)
    end = time.time() + steal_s
    me = kernel32.GetCurrentThreadId()
    while time.time() < end:
        fg = user32.GetForegroundWindow()
        if fg != hwnd:
            pid = ctypes.c_ulong(0)
            fg_thread = user32.GetWindowThreadProcessId(fg, ctypes.byref(pid))
            if fg_thread and fg_thread != me:
                user32.AttachThreadInput(me, fg_thread, True)
            user32.SetForegroundWindow(hwnd)
            user32.BringWindowToTop(hwnd)
            if fg_thread and fg_thread != me:
                user32.AttachThreadInput(me, fg_thread, False)
        time.sleep(0.15)
    print('decoy: done', flush=True)
    user32.DestroyWindow(hwnd)
    time.sleep(0.5)


if __name__ == '__main__':
    main()
