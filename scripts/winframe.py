import ctypes, ctypes.wintypes as wt, sys, json

u32 = ctypes.windll.user32
k32 = ctypes.windll.kernel32

class RECT(ctypes.Structure):
    _fields_ = [("l", ctypes.c_long), ("t", ctypes.c_long),
                ("r", ctypes.c_long), ("b", ctypes.c_long)]

class PE32(ctypes.Structure):
    _fields_ = [("dwSize", wt.DWORD), ("cntUsage", wt.DWORD),
                ("th32ProcessID", wt.DWORD), ("th32DefaultHeapID", ctypes.c_void_p),
                ("th32ModuleID", wt.DWORD), ("cntThreads", wt.DWORD),
                ("th32ParentProcessID", wt.DWORD), ("pcPriClassBase", ctypes.c_long),
                ("dwFlags", wt.DWORD), ("szExeFile", wt.WCHAR * 260)]

def pids_by_name(name):
    TH32CS_SNAPPROCESS = 0x2
    snap = k32.CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0)
    out = set()
    if snap and snap != -1:
        try:
            pe = PE32(); pe.dwSize = ctypes.sizeof(PE32)
            ok = k32.Process32FirstW(snap, ctypes.byref(pe))
            while ok:
                if pe.szExeFile.lower() == name.lower():
                    out.add(int(pe.th32ProcessID))
                ok = k32.Process32NextW(snap, ctypes.byref(pe))
        finally:
            k32.CloseHandle(snap)
    return out

def windows(pids, min_w=400, min_h=300):
    out = []
    def cb(hwnd, lp):
        p = ctypes.c_ulong(0)
        u32.GetWindowThreadProcessId(hwnd, ctypes.byref(p))
        if p.value in pids:
            r = RECT()
            if u32.GetWindowRect(hwnd, ctypes.byref(r)):
                w, h = r.r - r.l, r.b - r.t
                if w >= min_w and h >= min_h:
                    out.append((hwnd, w, h, r.l, r.t))
        return True
    CBP = ctypes.WINFUNCTYPE(ctypes.c_bool, ctypes.c_void_p, ctypes.c_void_p)
    u32.EnumWindows(CBP(cb), None)
    return out

def measure(exe):
    pids = pids_by_name(exe)
    wins = windows(pids)
    if not wins:
        print(json.dumps({"error": "no window"}))
        return 1
    res = []
    for hwnd, w, h, x, y in wins:
        cr = RECT()
        u32.GetClientRect(hwnd, ctypes.byref(cr))
        cw, ch = cr.r - cr.l, cr.b - cr.t
        style = u32.GetWindowLongW(hwnd, -16)       # GWL_STYLE
        exstyle = u32.GetWindowLongW(hwnd, -20)     # GWL_EXSTYLE
        res.append({
            "hwnd": hwnd, "outer": [w, h], "client": [cw, ch],
            "extra": [w - cw, h - ch],
            "style": hex(style & 0xFFFFFFFF), "exstyle": hex(exstyle & 0xFFFFFFFF),
        })
    print(json.dumps({"windows": res}, ensure_ascii=False))
    return 0

def delta_for(hwnd):
    """Frame overhead of one window: outer size minus client size."""
    r = RECT(); cr = RECT()
    if not u32.IsWindow(hwnd):
        print("dead")
        return 2
    if not u32.GetWindowRect(hwnd, ctypes.byref(r)):
        print("dead")
        return 2
    if not u32.GetClientRect(hwnd, ctypes.byref(cr)):
        print("dead")
        return 2
    dw = (r.r - r.l) - (cr.r - cr.l)
    dh = (r.b - r.t) - (cr.b - cr.t)
    print("%d %d" % (dw, dh))
    return 0

class POINT(ctypes.Structure):
    _fields_ = [("x", ctypes.c_long), ("y", ctypes.c_long)]

def client_origin(hwnd):
    pt = POINT(0, 0)
    u32.ClientToScreen(hwnd, ctypes.byref(pt))
    return pt.x, pt.y

def frame_offsets(hwnd):
    """(left, top, fw, fh) from the window as it really is right now.
    AdjustWindowRectEx is NOT usable for Electron windows: their style says
    WS_CAPTION while the app paints over the caption itself, so the API
    reports a ~30px taller frame than actually exists (measured: real 15x8
    vs 16x39 reported)."""
    a = RECT(); b = RECT()
    if not u32.GetWindowRect(hwnd, ctypes.byref(a)) or not u32.GetClientRect(hwnd, ctypes.byref(b)):
        return None
    ox, oy = client_origin(hwnd)
    return (ox - a.l, oy - a.t,
            (a.r - a.l) - (b.r - b.l), (a.b - a.t) - (b.b - b.t))

def align_target(hwnd, cx, cy, cw, ch):
    """Outer rect ("x y w h") that puts the CLIENT area exactly on (cx,cy,cw,ch)."""
    if not u32.IsWindow(hwnd):
        print("dead")
        return 2
    fo = frame_offsets(hwnd)
    if not fo:
        print("fail")
        return 1
    left, top, fw, fh = fo
    print("%d %d %d %d" % (cx - left, cy - top, cw + fw, ch + fh))
    return 0

def check_client(hwnd):
    """Print "cx cy cw ch" of the window's client area (screen coords)."""
    if not u32.IsWindow(hwnd):
        print("dead")
        return 2
    b = RECT()
    if not u32.GetClientRect(hwnd, ctypes.byref(b)):
        print("fail")
        return 1
    ox, oy = client_origin(hwnd)
    print("%d %d %d %d" % (ox, oy, b.r - b.l, b.b - b.t))
    return 0

if __name__ == "__main__":
    if len(sys.argv) >= 3 and sys.argv[1] == "delta":
        sys.exit(delta_for(int(sys.argv[2])))
    if len(sys.argv) >= 3 and sys.argv[1] == "check-client":
        sys.exit(check_client(int(sys.argv[2])))
    if len(sys.argv) >= 7 and sys.argv[1] == "align-target":
        sys.exit(align_target(int(sys.argv[2]), int(sys.argv[3]), int(sys.argv[4]),
                              int(sys.argv[5]), int(sys.argv[6])))
    exe = sys.argv[1] if len(sys.argv) > 1 else "Doubao.exe"
    sys.exit(measure(exe))
