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

usage: veil.py [hold_seconds] [rrggbb] [--app <exe>]
       e.g.  veil.py 12 --app Doubao.exe
"""
import ctypes
import sys
import time
from ctypes import wintypes

# Backwards-compatible arg parsing: positional hold + colour, plus the
# optional --app used to park the app's windows before the veil is drawn.
HOLD = 12.0
COLOR = 0x000A0605  # #05060a
APP = None
_i = 1
while _i < len(sys.argv):
    _a = sys.argv[_i]
    if _a == '--app' and _i + 1 < len(sys.argv):
        APP = sys.argv[_i + 1]
        _i += 2
        continue
    if _i == 1:
        try:
            HOLD = float(_a)
        except ValueError:
            pass
    else:
        try:
            COLOR = int(_a, 16)
        except ValueError:
            pass
    _i += 1

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
SM_CXSCREEN, SM_CYSCREEN = 0, 1
SPI_GETWORKAREA = 0x0030
# 0,0 = cover the primary screen's whole work area (fullscreen, taskbar
# still visible).  A non-zero size makes a centered windowed veil instead.
VEIL_W, VEIL_H = 0, 0

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


def park_app_windows(exe_name):
    """Move the app's large windows off-screen BEFORE the veil is drawn.

    The veil is exactly intro-sized (so it does not look "bigger than the
    animation"), but the app's window has a frame that sticks out around
    that rect -- which shows up as a white rim during the veil.  Hiding the
    app first keeps the veil exactly the size of the animation.
    """
    try:
        import os
        import importlib.util
        here = os.path.dirname(os.path.abspath(__file__))
        spec = importlib.util.spec_from_file_location(
            'rp', os.path.join(here, 'ready-probe.py'))
        rp = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(rp)
        name = exe_name if exe_name.lower().endswith('.exe') else exe_name + '.exe'
        pids = rp.proc_pids_by_name(name)
        if not pids:
            return 0
        n = 0
        for hwnd, w, h in rp.find_windows(pids=pids):
            if w >= 400 and h >= 300:
                # SWP_NOSIZE | SWP_NOZORDER | SWP_NOACTIVATE
                u.SetWindowPos(hwnd, None, -4000, 300, 0, 0,
                               0x0001 | 0x0004 | 0x0010)
                n += 1
        return n
    except Exception:
        return 0


def main():
    if APP:
        park_app_windows(APP)
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

    # FULLSCREEN veil: the primary screen's work area -- the exact rect the
    # intro player and the app's client area take, so click -> veil -> intro
    # -> app all line up with nothing changing size along the way.
    wr = wintypes.RECT()
    if u.SystemParametersInfoW(SPI_GETWORKAREA, 0, ctypes.byref(wr), 0):
        wa_x, wa_y = wr.left, wr.top
        wa_w, wa_h = wr.right - wr.left, wr.bottom - wr.top
    else:
        wa_x = wa_y = 0
        wa_w = u.GetSystemMetrics(SM_CXSCREEN)
        wa_h = u.GetSystemMetrics(SM_CYSCREEN)

    if VEIL_W <= 0 or VEIL_H <= 0:
        x, y, w, h = wa_x, wa_y, wa_w, wa_h
    else:
        x = wa_x + (wa_w - VEIL_W) // 2
        y = wa_y + (wa_h - VEIL_H) // 2
        w, h = VEIL_W, VEIL_H

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
