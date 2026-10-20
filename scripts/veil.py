"""veil.py -- instant full-screen dark veil for the boot intro.

Started by the launcher the moment the icon is clicked, BEFORE the intro
player starts.  While the player boots (~0.5-2s) the previous screen
contents stay visible (and a browser-based player first shows a plain
white untitled window) -- both read as a "flash" at the start of the
intro.  This veil covers that whole gap:

  click -> veil (dark, ~0.3s, click-through) -> player boots behind it
        -> keeper pins the intro window above the veil and kills it
        -> animation plays, no flash of the old screen / white window

Self-exits after `hold` seconds as a leak guard (the keeper normally
kills it within ~2s of the intro window appearing).

usage: veil.py [hold_seconds] [rrggbb]     e.g.  veil.py 12 05060a
"""
import ctypes
import sys
import time
from ctypes import wintypes

HOLD = float(sys.argv[1]) if len(sys.argv) > 1 else 12.0
COLOR = int(sys.argv[2], 16) if len(sys.argv) > 2 else 0x000A0605  # #05060a

u = ctypes.windll.user32
k = ctypes.windll.kernel32
g = ctypes.windll.gdi32

CS_HREDRAW, CS_VREDRAW = 0x0002, 0x0001
WS_POPUP = 0x80000000
WS_EX_TOPMOST = 0x00000008
WS_EX_NOACTIVATE = 0x08000000
WS_EX_TRANSPARENT = 0x00000020
SW_SHOW = 5
HWND_TOPMOST = -1
SWP_SHOWWINDOW = 0x0040
SWP_NOSIZE, SWP_NOMOVE = 0x0001, 0x0002
WM_DESTROY, WM_CLOSE, WM_QUIT = 0x0002, 0x0010, 0x0012
PM_REMOVE = 0x0001
SM_XVIRTUALSCREEN, SM_YVIRTUALSCREEN = 76, 77
SM_CXVIRTUALSCREEN, SM_CYVIRTUALSCREEN = 78, 79

u.DefWindowProcW.argtypes = [wintypes.HWND, wintypes.UINT, wintypes.WPARAM,
                             wintypes.LPARAM]
u.DefWindowProcW.restype = wintypes.LPARAM


class WNDCLASS(ctypes.Structure):
    _fields_ = [
        ('style', wintypes.UINT),
        ('lpfnWndProc', ctypes.WINFUNCTYPE(wintypes.LPARAM, wintypes.HWND,
                                           wintypes.UINT, wintypes.WPARAM,
                                           wintypes.LPARAM)),
        ('cbClsExtra', ctypes.c_int),
        ('cbWndExtra', ctypes.c_int),
        ('hInstance', wintypes.HINSTANCE),
        ('hIcon', wintypes.HICON),
        ('hCursor', wintypes.HICON),
        ('hbrBackground', wintypes.HBRUSH),
        ('lpszMenuName', wintypes.LPCWSTR),
        ('lpszClassName', wintypes.LPCWSTR),
    ]


def wndproc(h, m, w, l):
    if m == WM_CLOSE:
        return 0
    if m == WM_DESTROY:
        u.PostQuitMessage(0)
        return 0
    return u.DefWindowProcW(h, m, w, l)


def main():
    hinst = k.GetModuleHandleW(None)
    brush = g.CreateSolidBrush(COLOR)

    wc = WNDCLASS()
    wc.style = CS_HREDRAW | CS_VREDRAW
    wc.lpfnWndProc = ctypes.WINFUNCTYPE(wintypes.LPARAM, wintypes.HWND,
                                        wintypes.UINT, wintypes.WPARAM,
                                        wintypes.LPARAM)(wndproc)
    wc.hInstance = hinst
    wc.hbrBackground = brush
    wc.lpszClassName = 'WBVeilClass'
    if not u.RegisterClassW(ctypes.byref(wc)):
        return

    x = u.GetSystemMetrics(SM_XVIRTUALSCREEN)
    y = u.GetSystemMetrics(SM_YVIRTUALSCREEN)
    w = u.GetSystemMetrics(SM_CXVIRTUALSCREEN)
    h = u.GetSystemMetrics(SM_CYVIRTUALSCREEN)

    hwnd = u.CreateWindowExW(
        WS_EX_TOPMOST | WS_EX_NOACTIVATE | WS_EX_TRANSPARENT,
        'WBVeilClass', None, WS_POPUP, x, y, w, h,
        None, None, hinst, None)
    if not hwnd:
        return

    u.ShowWindow(hwnd, SW_SHOW)
    u.SetWindowPos(hwnd, HWND_TOPMOST, 0, 0, 0, 0,
                   SWP_SHOWWINDOW | SWP_NOSIZE | SWP_NOMOVE)

    deadline = time.time() + HOLD
    msg = wintypes.MSG()
    while time.time() < deadline:
        if u.PeekMessageW(ctypes.byref(msg), None, 0, 0, PM_REMOVE):
            if msg.message == WM_QUIT:
                break
            u.TranslateMessage(ctypes.byref(msg))
            u.DispatchMessageW(ctypes.byref(msg))
        else:
            time.sleep(0.02)

    u.DestroyWindow(hwnd)
    u.UnregisterClassW('WBVeilClass', hinst)
    g.DeleteObject(brush)


main()
