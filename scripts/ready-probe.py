# ready-probe: PrintWindow-based luma-std probe (no third-party deps).
# Usage: python ready-probe.py --title <exact window title or substring>
#        python ready-probe.py --pid <pid>
# Prints one JSON line per sample; final line: {"done": true}
import ctypes, ctypes.wintypes as wt, json, sys, time, math

u32 = ctypes.windll.user32
g32 = ctypes.windll.gdi32
k32 = ctypes.windll.kernel32

PW_RENDERFULLCONTENT = 0x00000002
SRCCOPY = 0x00CC0020
DIB_RGB_COLORS = 0
BI_RGB = 0

class RECT(ctypes.Structure):
    _fields_ = [("l", ctypes.c_long), ("t", ctypes.c_long),
                ("r", ctypes.c_long), ("b", ctypes.c_long)]

class BITMAPINFOHEADER(ctypes.Structure):
    _fields_ = [("biSize", ctypes.c_uint32), ("biWidth", ctypes.c_int32),
                ("biHeight", ctypes.c_int32), ("biPlanes", ctypes.c_uint16),
                ("biBitCount", ctypes.c_uint16), ("biCompression", ctypes.c_uint32),
                ("biSizeImage", ctypes.c_uint32), ("biXPelsPerMeter", ctypes.c_int32),
                ("biYPelsPerMeter", ctypes.c_int32), ("biClrUsed", ctypes.c_uint32),
                ("biClrImportant", ctypes.c_uint32)]

class BITMAPINFO(ctypes.Structure):
    _fields_ = [("bmiHeader", BITMAPINFOHEADER),
                ("bmiColors", ctypes.c_uint32 * 3)]

def find_windows(pids=None, title_sub=None):
    """All matching top-level windows (no IsWindowVisible filter: an app
    window can be legitimately hidden while it is still painting/loading,
    e.g. Electron hiding its window on close-to-tray)."""
    out = []
    def cb(hwnd, lparam):
        if pids is not None:
            p = ctypes.c_ulong(0)
            u32.GetWindowThreadProcessId(hwnd, ctypes.byref(p))
            if p.value not in pids:
                return True
        if title_sub is not None:
            n = u32.GetWindowTextLengthW(hwnd)
            if n == 0:
                return True
            buf = ctypes.create_unicode_buffer(n + 1)
            u32.GetWindowTextW(hwnd, buf, n + 1)
            if title_sub.lower() not in buf.value.lower():
                return True
        r = RECT()
        if u32.GetWindowRect(hwnd, ctypes.byref(r)):
            w, h = r.r - r.l, r.b - r.t
            if w > 0 and h > 0:
                out.append((hwnd, w, h))
        return True
    CBP = ctypes.WINFUNCTYPE(ctypes.c_bool, ctypes.c_void_p, ctypes.c_void_p)
    u32.EnumWindows(CBP(cb), None)
    return out

def main_window(pids=None, title_sub=None):
    """Pick the app's real main window: largest area, prefer titled ones."""
    wins = find_windows(pids=pids, title_sub=title_sub)
    if not wins:
        return None
    def area(item):
        hwnd, w, h = item
        n = u32.GetWindowTextLengthW(hwnd)
        titled = 1 if n > 0 else 0
        return (titled, w * h)
    return max(wins, key=area)

def luma_std(hwnd, w, h, margin=0.12):
    """Luma std of the window's own rendered content (PrintWindow), sampled
    over the central region only (title bar / borders / chrome excluded so a
    merely-decorated window still reads as blank)."""
    x0 = int(w * margin); x1 = int(w * (1 - margin))
    y0 = int(h * margin); y1 = int(h * (1 - margin))
    w = max(1, x1 - x0); h = max(1, y1 - y0)
    hdc_src = u32.GetDC(None)
    if not hdc_src:
        return None
    try:
        hdc_mem = g32.CreateCompatibleDC(hdc_src)
        hbm = g32.CreateCompatibleBitmap(hdc_src, w, h)
        old = g32.SelectObject(hdc_mem, hbm)
        try:
            if not u32.PrintWindow(hwnd, hdc_mem, PW_RENDERFULLCONTENT):
                return None
            bi = BITMAPINFO()
            bi.bmiHeader.biSize = ctypes.sizeof(BITMAPINFOHEADER)
            bi.bmiHeader.biWidth = w
            bi.bmiHeader.biHeight = -h   # top-down
            bi.bmiHeader.biPlanes = 1
            bi.bmiHeader.biBitCount = 32
            bi.bmiHeader.biCompression = BI_RGB
            buf = ctypes.create_string_buffer(w * h * 4)
            got = g32.GetDIBits(hdc_mem, hbm, 0, h, buf, ctypes.byref(bi), DIB_RGB_COLORS)
            if got == 0:
                return None
            mv = buf.raw
            s = 0.0; s2 = 0.0; n = 0
            step = 4 * 4   # every 4th pixel
            total = w * h * 4
            for off in range(0, total - 3, step):
                b = mv[off]; g = mv[off + 1]; rr = mv[off + 2]
                lum = 0.114 * b + 0.587 * g + 0.299 * rr
                s += lum; s2 += lum * lum; n += 1
            if n == 0:
                return None
            mean = s / n
            return math.sqrt(max(0.0, s2 / n - mean * mean))
        finally:
            g32.SelectObject(hdc_mem, old)
            g32.DeleteObject(hbm)
            g32.DeleteDC(hdc_mem)
    finally:
        u32.ReleaseDC(None, hdc_src)

def proc_pids_by_name(name):
    """PIDs of all processes whose exe name matches (case-insensitive)."""
    import ctypes.wintypes as wt
    TH32CS_SNAPPROCESS = 0x00000002
    class PE32(ctypes.Structure):
        _fields_ = [("dwSize", wt.DWORD), ("cntUsage", wt.DWORD),
                    ("th32ProcessID", wt.DWORD), ("th32DefaultHeapID", ctypes.c_void_p),
                    ("th32ModuleID", wt.DWORD), ("cntThreads", wt.DWORD),
                    ("th32ParentProcessID", wt.DWORD), ("pcPriClassBase", ctypes.c_long),
                    ("dwFlags", wt.DWORD), ("szExeFile", wt.WCHAR * 260)]
    k = ctypes.windll.kernel32
    snap = k.CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0)
    pids = set()
    if snap and snap != -1:
        try:
            pe = PE32(); pe.dwSize = ctypes.sizeof(PE32)
            ok = k.Process32FirstW(snap, ctypes.byref(pe))
            while ok:
                if pe.szExeFile.lower() == name.lower():
                    pids.add(int(pe.th32ProcessID))
                ok = k.Process32NextW(snap, ctypes.byref(pe))
        finally:
            k.CloseHandle(snap)
    return pids

def watch(name, seconds, interval, start_ts, hide_offscreen=False,
          ready_std=15.0, dest=(160, 130)):
    """Cold-start timeline: track the app's processes, its main window and
    the window's content std, printing one CSV line per sample.
    With hide_offscreen: the moment the main window appears it is parked
    fully off-screen until its content is ready (std >= ready_std twice in a
    row), then moved to `dest` -- verifying that hiding the window does not
    stall the app's page loading."""
    t0 = time.time()
    print("# t_ms,win,size,std,state", flush=True)
    state = "waiting-win"
    stable = 0
    parked = False
    ready_at = None
    while time.time() - t0 < seconds:
        now = time.time()
        t_ms = int((now - start_ts) * 1000)
        pids = proc_pids_by_name(name)
        win = main_window(pids=pids) if pids else None
        std = None
        if win:
            hwnd, w, h = win
            if hide_offscreen and not parked and w > 300:
                # park the real main window off-screen right away
                u32.SetWindowPos(hwnd, None, -4000, 300, 0, 0,
                                 0x0001 | 0x0004 | 0x0010)  # NOSIZE|NOZORDER|NOACTIVATE
                parked = True
                state = "parked"
            try:
                std = luma_std(hwnd, w, h)
            except Exception:
                std = None
            if hide_offscreen and parked and ready_at is None and std is not None:
                if std >= ready_std:
                    stable += 1
                    if stable >= 2:
                        ready_at = t_ms
                        state = "ready"
                        u32.SetWindowPos(hwnd, None, dest[0], dest[1], 0, 0,
                                         0x0001 | 0x0004 | 0x0010)
                else:
                    stable = 0
        print("%d,%s,%s,%.2f,%s" % (t_ms, "1" if win else "0",
              ("%dx%d" % (win[1], win[2])) if win else "-",
              std if std is not None else -1.0, state), flush=True)
        time.sleep(interval)

def probe_app(exe_name, ready_std, timeout, interval, logfile=None,
              min_w=400, min_h=300):
    """Like probe_hwnd, but keeps noticing the app's windows itself: the pid
    set is refreshed from the exe name on every sample (Electron spawns its
    renderer processes during startup), and the highest content std across
    all large top-level windows is what counts.  Electron apps can keep
    several same-sized windows around while starting (Doubao has an
    untitled "shadow" window next to the real one), so pinning the probe to
    one hwnd is unreliable.
    Exit 0 = ready (some window loaded, twice in a row), 1 = timeout,
    2 = app gone.  The ready line names the window that actually loaded."""
    lf = None
    if logfile:
        try:
            lf = open(logfile, "a", encoding="utf-8", buffering=1)
        except Exception:
            lf = None

    def emit(text):
        print(text, flush=True)
        if lf:
            try:
                lf.write(text + "\n")
            except Exception:
                pass

    t0 = time.time()
    stable = 0
    miss = 0
    try:
        while time.time() - t0 < timeout:
            pids = proc_pids_by_name(exe_name)
            wins = [w for w in find_windows(pids=pids)
                    if w[1] >= min_w and w[2] >= min_h] if pids else []
            if not wins:
                miss += 1
                if miss >= 20:
                    emit(json.dumps({"std": None, "state": "app-gone"}))
                    return 2
                time.sleep(interval)
                continue
            miss = 0
            best_std = None; best_hwnd = None; best_size = None
            for hwnd, w, h in wins:
                try:
                    s = luma_std(hwnd, w, h)
                except Exception:
                    s = None
                if s is not None and (best_std is None or s > best_std):
                    best_std = s; best_hwnd = hwnd; best_size = [w, h]
            state = "blank" if (best_std is not None and best_std < ready_std) else "loaded"
            emit(json.dumps({"std": best_std, "state": state,
                             "t": round(time.time() - t0, 2),
                             "size": best_size, "hwnd": best_hwnd,
                             "wins": len(wins)}))
            if best_std is not None and best_std >= ready_std:
                stable += 1
                if stable >= 2:
                    emit(json.dumps({"std": best_std, "state": "ready",
                                     "t": round(time.time() - t0, 2),
                                     "hwnd": best_hwnd, "size": best_size}))
                    return 0
            else:
                stable = 0
            time.sleep(interval)
        emit(json.dumps({"std": None, "state": "timeout"}))
        return 1
    finally:
        if lf:
            try:
                lf.close()
            except Exception:
                pass

def probe_hwnd(hwnd, ready_std, timeout, interval, logfile=None):
    """Watch one window's content std until it looks loaded.
    Exit 0 = ready (std >= ready_std twice in a row), 1 = timeout,
    2 = window gone (hwnd invalid for a long stretch).  Writes one status
    line per sample to stdout and, when logfile is given, to that file --
    Start-Process redirection cannot be used here (this machine has both
    http_proxy and HTTP_PROXY set, which crashes -NoNewWindow)."""
    lf = None
    if logfile:
        try:
            lf = open(logfile, "a", encoding="utf-8", buffering=1)
        except Exception:
            lf = None

    def emit(text):
        print(text, flush=True)
        if lf:
            try:
                lf.write(text + "\n")
            except Exception:
                pass

    t0 = time.time()
    stable = 0
    miss = 0
    try:
        while time.time() - t0 < timeout:
            ok = u32.IsWindow(hwnd)
            if not ok:
                miss += 1
                if miss >= 20:
                    emit(json.dumps({"std": None, "state": "window-gone"}))
                    return 2
            else:
                miss = 0
            class R(ctypes.Structure):
                _fields_ = [("l", ctypes.c_long), ("t", ctypes.c_long),
                            ("r", ctypes.c_long), ("b", ctypes.c_long)]
            r = R()
            std = None
            if u32.GetWindowRect(hwnd, ctypes.byref(r)) and (r.r - r.l) > 0:
                try:
                    std = luma_std(hwnd, r.r - r.l, r.b - r.t)
                except Exception:
                    std = None
            state = "blank" if (std is not None and std < ready_std) else "loaded"
            emit(json.dumps({"std": std, "state": state,
                             "t": round(time.time() - t0, 2), "size": [r.r - r.l, r.b - r.t]}))
            if std is not None and std >= ready_std:
                stable += 1
                if stable >= 2:
                    emit(json.dumps({"std": std, "state": "ready",
                                     "t": round(time.time() - t0, 2)}))
                    return 0
            else:
                stable = 0
            time.sleep(interval)
        emit(json.dumps({"std": None, "state": "timeout"}))
        return 1
    finally:
        if lf:
            try:
                lf.close()
            except Exception:
                pass

def main():
    pids = None; title = None; n = 1; interval = 0.5
    args = sys.argv[1:]
    for j, a in enumerate(args):
        if a == "--pids" and j + 1 < len(args):
            pids = set(int(x) for x in args[j+1].split(",") if x.strip())
        elif a == "--pid" and j + 1 < len(args):
            pids = set([int(args[j+1])])
        elif a == "--title" and j + 1 < len(args):
            title = args[j+1]
        elif a == "--count" and j + 1 < len(args):
            n = int(args[j+1])
        elif a == "--interval" and j + 1 < len(args):
            interval = float(args[j+1])
        elif a == "--app" and j + 1 < len(args):
            # --app <exe name> --until-ready <std> --timeout <s> [--log <f>]
            rs = 15.0; to = 20.0; logf = None
            for k2, a2 in enumerate(args):
                if a2 == "--until-ready" and k2 + 1 < len(args):
                    rs = float(args[k2 + 1])
                elif a2 == "--timeout" and k2 + 1 < len(args):
                    to = float(args[k2 + 1])
                elif a2 == "--log" and k2 + 1 < len(args):
                    logf = args[k2 + 1]
            sys.exit(probe_app(args[j+1], rs, to, interval, logf))
        elif a == "--hwnd" and j + 1 < len(args):
            # --hwnd <decimal> --until-ready <std> --timeout <s> [--log <file>]
            rs = 15.0; to = 20.0; logf = None
            for k2, a2 in enumerate(args):
                if a2 == "--until-ready" and k2 + 1 < len(args):
                    rs = float(args[k2 + 1])
                elif a2 == "--timeout" and k2 + 1 < len(args):
                    to = float(args[k2 + 1])
                elif a2 == "--log" and k2 + 1 < len(args):
                    logf = args[k2 + 1]
            sys.exit(probe_hwnd(int(args[j+1]), rs, to, interval, logf))
        elif a == "--watch" and j + 3 < len(args):
            # --watch <exe_name> <seconds> <start_epoch> [--hide] [--readystd N]
            hide = "--hide" in args
            rs = 15.0
            for k2, a2 in enumerate(args):
                if a2 == "--readystd" and k2 + 1 < len(args):
                    rs = float(args[k2 + 1])
            watch(args[j+1], float(args[j+2]), interval, float(args[j+3]),
                  hide_offscreen=hide, ready_std=rs)
            return
    for _ in range(n):
        win = main_window(pids=pids, title_sub=title)
        std = None
        if win:
            hwnd, w, h = win
            std = luma_std(hwnd, w, h)
        print(json.dumps({"std": std, "win": bool(win),
                          "size": [win[1], win[2]] if win else None}),
              flush=True)
        time.sleep(interval)

if __name__ == "__main__":
    main()
