"""Poll the intro window's WS_EX_TOPMOST flag during playback.

The visual guarantee of the whole design: while the intro plays, its
window must be topmost so the loading app (which is NOT topmost) can
never appear in front of it.  Samples the flag every 200ms for N seconds
and reports how often it held.

usage: pincheck.py [seconds] [title_tag]      e.g.  pincheck.py 17 WB-INTRO
"""
import ctypes
import ctypes.wintypes as w
import sys
import time

user32 = ctypes.windll.user32
user32.GetWindowLongPtrW.argtypes = [w.HWND, ctypes.c_int]
user32.GetWindowLongPtrW.restype = ctypes.c_ssize_t
user32.GetWindowTextW.argtypes = [w.HWND, ctypes.c_wchar_p, ctypes.c_int]
user32.IsWindowVisible.argtypes = [w.HWND]

GWL_EXSTYLE = -20
WS_EX_TOPMOST = 0x00000008


def intro_windows(tag):
    hits = []

    @ctypes.WINFUNCTYPE(w.BOOL, w.HWND, w.LPARAM)
    def cb(h, _):
        if user32.IsWindowVisible(h):
            title = ctypes.create_unicode_buffer(260)
            user32.GetWindowTextW(h, title, 260)
            if title.value.startswith(tag):
                hits.append(h)
        return True

    user32.EnumWindows(cb, 0)
    return hits


def main():
    seconds = float(sys.argv[1]) if len(sys.argv) > 1 else 17.0
    tag = sys.argv[2] if len(sys.argv) > 2 else 'WB-INTRO'
    end = time.time() + seconds
    seen = 0
    topmost = 0
    while time.time() < end:
        for h in intro_windows(tag):
            seen += 1
            if user32.GetWindowLongPtrW(h, GWL_EXSTYLE) & WS_EX_TOPMOST:
                topmost += 1
        time.sleep(0.2)
    print('pincheck: intro window seen in %d samples, topmost in %d (%.0f%%)'
          % (seen, topmost, (100.0 * topmost / seen) if seen else 0.0))


if __name__ == '__main__':
    main()
