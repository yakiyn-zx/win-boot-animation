"""Foreground-window sampler: proves whether the app window can steal
focus in front of the intro while it plays.

Run it in parallel with the launcher; every sample prints the current
foreground process + title.  During the intro, 100% of the samples must
be the player window (powershell / <tag>).

usage: fg-sampler.py [seconds] [interval]      e.g.  fg-sampler.py 17 0.4
"""
import ctypes
import datetime
import sys
import time

user32 = ctypes.windll.user32
kernel32 = ctypes.windll.kernel32
PROCESS_QUERY_LIMITED_INFORMATION = 0x1000


def fg_info():
    h = user32.GetForegroundWindow()
    if not h:
        return 'none', ''
    pid = ctypes.c_ulong(0)
    user32.GetWindowThreadProcessId(h, ctypes.byref(pid))
    name = '?'
    hproc = kernel32.OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, False, pid.value)
    if hproc:
        buf = ctypes.create_unicode_buffer(260)
        size = ctypes.c_ulong(260)
        if kernel32.QueryFullProcessImageNameW(hproc, 0, buf, ctypes.byref(size)):
            name = buf.value.replace('\\', '/').rsplit('/', 1)[-1]
        kernel32.CloseHandle(hproc)
    title = ctypes.create_unicode_buffer(260)
    user32.GetWindowTextW(h, title, 260)
    return name, title.value


seconds = float(sys.argv[1]) if len(sys.argv) > 1 else 17.0
interval = float(sys.argv[2]) if len(sys.argv) > 2 else 0.4

seen = {}
end = time.time() + seconds
while time.time() < end:
    name, title = fg_info()
    seen[name] = seen.get(name, 0) + 1
    print('%s  %-16s %s' % (datetime.datetime.now().strftime('%H:%M:%S'), name, title[:44]))
    time.sleep(interval)

print('--- summary ---')
for k, v in sorted(seen.items(), key=lambda x: -x[1]):
    print('%-20s %d samples' % (k, v))
