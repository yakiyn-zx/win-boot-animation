"""Cold-start flash repro: WPF intro + mid-intro app spawn + 50ms fg sampling.

Reproduces exactly what wait-kiosk.ps1 does in the cold-start path:
  1) launch the WPF player (play.ps1) with the intro
  2) pin it TOPMOST the moment its window appears
  3) spawn the app (single instance -> raises existing window)
  4) sample the foreground window every 50ms and flag any non-intro moment

Proves the central claim: once the intro window is pinned, nothing can
flash in front of it -- so any "flash at the start" must come from the
pre-intro gap (which is what the veil covers).

usage: coldflash.py <play.ps1 path> <video> <app exe> [title_tag]
"""
import ctypes
import subprocess
import sys
import time
from ctypes import wintypes

PLAY = sys.argv[1]
VIDEO = sys.argv[2]
APP = sys.argv[3]
TAG = sys.argv[4] if len(sys.argv) > 4 else 'WB-INTRO'

u = ctypes.windll.user32
k = ctypes.windll.kernel32

u.GetForegroundWindow.argtypes = []
u.GetWindowThreadProcessId.argtypes = [wintypes.HWND, ctypes.POINTER(wintypes.DWORD)]
u.GetWindowTextW.argtypes = [wintypes.HWND, ctypes.c_wchar_p, ctypes.c_int]
u.IsWindowVisible.argtypes = [wintypes.HWND]
u.SetWindowPos.argtypes = [wintypes.HWND, wintypes.HWND, ctypes.c_int,
                           ctypes.c_int, ctypes.c_int, ctypes.c_int, ctypes.c_uint]
u.EnumWindows.argtypes = [ctypes.WINFUNCTYPE(wintypes.BOOL, wintypes.HWND,
                                             wintypes.LPARAM), wintypes.LPARAM]

PROC_QUERY_LIMITED_INFORMATION = 0x1000
k.OpenProcess.argtypes = [wintypes.DWORD, wintypes.BOOL, wintypes.DWORD]
k.OpenProcess.restype = wintypes.HANDLE
k.QueryFullProcessImageNameW.argtypes = [wintypes.HANDLE, wintypes.DWORD,
                                         ctypes.c_wchar_p,
                                         ctypes.POINTER(wintypes.DWORD)]
k.CloseHandle.argtypes = [wintypes.HANDLE]

HWND_TOPMOST, HWND_NOTOPMOST = -1, -2
SWP_NOSIZE, SWP_NOMOVE, SWP_NOACTIVATE = 0x0001, 0x0002, 0x0010

_name_cache = {}


def proc_name(pid):
    if pid in _name_cache:
        return _name_cache[pid]
    h = k.OpenProcess(PROC_QUERY_LIMITED_INFORMATION, False, pid)
    name = '?'
    if h:
        buf = ctypes.create_unicode_buffer(512)
        n = wintypes.DWORD(512)
        if k.QueryFullProcessImageNameW(h, 0, buf, ctypes.byref(n)):
            name = buf.value.rsplit('\\', 1)[-1]
        k.CloseHandle(h)
    _name_cache[pid] = name
    return name


def fg():
    h = u.GetForegroundWindow()
    if not h:
        return None
    pid = wintypes.DWORD()
    u.GetWindowThreadProcessId(h, ctypes.byref(pid))
    buf = ctypes.create_unicode_buffer(128)
    u.GetWindowTextW(h, buf, 128)
    return h, proc_name(pid.value), buf.value


def intro_handle():
    """Visible window whose title contains the intro tag."""
    found = []

    def cb(h, _):
        if not u.IsWindowVisible(h):
            return True
        buf = ctypes.create_unicode_buffer(128)
        u.GetWindowTextW(h, buf, 128)
        if TAG in buf.value:
            found.append(h)
        return True

    u.EnumWindows(ctypes.WINFUNCTYPE(wintypes.BOOL, wintypes.HWND,
                                     wintypes.LPARAM)(cb), 0)
    return found[0] if found else None


def ts():
    return time.strftime('%H:%M:%S') + '.%03d' % int((time.time() % 1) * 1000)


t0 = time.time()
print('%s launching player' % ts())
subprocess.Popen(['powershell', '-NoProfile', '-ExecutionPolicy', 'Bypass',
                  '-STA', '-WindowStyle', 'Hidden', '-File', PLAY,
                  '-Video', VIDEO, '-TitleTag', TAG])

kh = None
while time.time() - t0 < 12:
    kh = intro_handle()
    if kh:
        break
    time.sleep(0.05)
if not kh:
    print('INTRO WINDOW NEVER APPEARED')
    sys.exit(1)
print('%s intro window up -> pinning TOPMOST' % ts())
u.SetWindowPos(kh, HWND_TOPMOST, 0, 0, 0, 0, SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE)

# spawn the app 1s after the intro is on screen (like the keeper does)
spawn_at = time.time() + 1.0
print('%s spawning app in 1s (cold-start path)' % ts())

violations = []
samples = 0
intro_done_at = None
while time.time() - t0 < 30:
    now = time.time()
    if spawn_at and now >= spawn_at:
        print('%s *** spawning %s ***' % (ts(), APP))
        subprocess.Popen([APP])
        spawn_at = None
    h, name, title = fg()
    samples += 1
    if intro_done_at is None and intro_handle() and '-DONE' in title:
        intro_done_at = now
        print('%s intro video finished' % ts())
    # flag: foreground is not the intro (after the intro is up)
    if not (TAG in title):
        if time.time() - t0 > 1.0:  # skip the pre-intro moment
            violations.append((ts(), name, title[:60]))
    time.sleep(0.05)
    if intro_done_at and time.time() - intro_done_at > 4:
        break

print('--- samples: %d, violations (fg != intro): %d ---' % (samples, len(violations)))
for v in violations:
    print('  VIOLATION %s  %s  %r' % v)

# clean up the player
subprocess.run(['powershell', '-NoProfile', '-Command',
                "Get-CimInstance Win32_Process -Filter \"Name='powershell.exe'\" |"
                " Where-Object { $_.CommandLine -like '*play.ps1*' } |"
                " Stop-Process -Force"],
               capture_output=True)
print('%s player cleaned' % ts())
