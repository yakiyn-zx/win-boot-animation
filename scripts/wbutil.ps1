# Shared helpers for the boot-intro launcher scripts.
# Dot-sourced by wait-kiosk.ps1 / stop-intro.ps1.
# Everything here is user-scope Win32 work: no elevation, no injection,
# and the intro player instance is always identified by 'play.ps1' in the
# command line, so the user's own apps / browsers are never touched.
param(
    # Main process name of the target application (no .exe), e.g. 'WorkBuddy'.
    [string]$AppProcess   = 'WorkBuddy',
    # Wildcard pattern for the app's main window title (Electron apps own
    # a titled window only in their browser process).
    [string]$AppTitleLike = 'WorkBuddy*',
    # Title marker tag of the player window: '<tag>' while the video plays,
    # '<tag>-DONE' on the held last frame.
    [string]$TitleTag     = 'WB-INTRO'
)

$ErrorActionPreference = 'Stop'

$script:LogFile = Join-Path $PSScriptRoot 'launch.log'

# ---- window geometry -------------------------------------------------------
# The intro player AND the app work window share this fixed size: windowed
# (NOT fullscreen), centered on the primary screen.  The intro fades out
# onto the app window at exactly the same rect, so the handover is seamless.
# 1120x630 (16:9) on this machine's 1280x800 desktop leaves ~80px at the
# sides and ~85px above/below -- a clearly windowed app that still uses the
# screen well.
[int]$script:AppWinW = 1120
[int]$script:AppWinH = 630

# Frame overhead (outer size minus client size) per window handle, measured
# once per handle through winframe.py -- PowerShell cannot call GetClientRect
# without compiling code, and the DLL is frozen (no compiler available).
$script:FrameDeltaCache = @{}
# Outer rect that puts the window's CLIENT area exactly on the intro rect,
# computed with AdjustWindowRectEx (asymmetric frames matter: a plain
# "center the outer rect" leaves the content 1-2px off).
$script:TargetRectCache = @{}

# The rect the intro player occupies: centered AppWinW x AppWinH on the
# primary screen.  Everything (player, veil, app client area) must agree.
function Get-IntroRect {
    $sw = [WBIntro]::GetSystemMetrics([WBIntro]::SM_CXSCREEN)
    $sh = [WBIntro]::GetSystemMetrics([WBIntro]::SM_CYSCREEN)
    return @{
        x = [int](($sw - $script:AppWinW) / 2)
        y = [int](($sh - $script:AppWinH) / 2)
        w = $script:AppWinW
        h = $script:AppWinH
    }
}

# Outer rect ("x y w h") that makes the window's client area land exactly on
# the intro rect.  Falls back to client+delta when python is unavailable.
function Get-TargetOuterRect([IntPtr]$Hwnd) {
    $key = ([int64]$Hwnd).ToString()
    if ($script:TargetRectCache.ContainsKey($key)) { return $script:TargetRectCache[$key] }
    $ir = Get-IntroRect
    $rect = $null
    try {
        if (Test-Path $script:ProbePython) {
            $out = & $script:ProbePython (Join-Path $PSScriptRoot 'winframe.py') align-target `
                $key $ir.x $ir.y $ir.w $ir.h 2>$null
            if ($out -match '^\s*(-?\d+)\s+(-?\d+)\s+(\d+)\s+(\d+)') {
                $rect = @{ x = [int]$Matches[1]; y = [int]$Matches[2]
                           w = [int]$Matches[3]; h = [int]$Matches[4] }
            }
        }
    } catch { }
    if (-not $rect) {
        $d = Get-FrameDelta $Hwnd
        $rect = @{ x = $ir.x; y = $ir.y
                   w = $script:AppWinW + $d.w; h = $script:AppWinH + $d.h }
    }
    $script:TargetRectCache[$key] = $rect
    return $rect
}

function Get-FrameDelta([IntPtr]$Hwnd) {
    $key = ([int64]$Hwnd).ToString()
    if ($script:FrameDeltaCache.ContainsKey($key)) { return $script:FrameDeltaCache[$key] }
    $d = @{ w = 0; h = 0 }
    try {
        if (Test-Path $script:ProbePython) {
            $out = & $script:ProbePython (Join-Path $PSScriptRoot 'winframe.py') delta $key 2>$null
            if ($out -match '^\s*(\d+)\s+(\d+)') {
                $d = @{ w = [int]$Matches[1]; h = [int]$Matches[2] }
            }
        }
    } catch { }
    $script:FrameDeltaCache[$key] = $d
    return $d
}

# Is the window's client area where the intro was?  Verified through
# winframe.py because PowerShell cannot read GetClientRect / ClientToScreen.
function Test-ClientOnIntroRect([IntPtr]$Hwnd) {
    $ir = Get-IntroRect
    if (-not (Test-Path $script:ProbePython)) { return @{ ok = $true; unverified = $true } }
    try {
        $out = & $script:ProbePython (Join-Path $PSScriptRoot 'winframe.py') check-client `
            ([int64]$Hwnd).ToString() 2>$null
        if ($out -match '^\s*(-?\d+)\s+(-?\d+)\s+(\d+)\s+(\d+)') {
            $cx = [int]$Matches[1]; $cy = [int]$Matches[2]
            $cw = [int]$Matches[3]; $ch = [int]$Matches[4]
            $ok = ([Math]::Abs($cx - $ir.x) -le 2) -and ([Math]::Abs($cy - $ir.y) -le 2) -and
                  ([Math]::Abs($cw - $ir.w) -le 2) -and ([Math]::Abs($ch - $ir.h) -le 2)
            return @{ ok = $ok; x = $cx; y = $cy; w = $cw; h = $ch }
        }
    } catch { }
    return @{ ok = $true; unverified = $true }
}

# Move+resize a window so its CLIENT area is exactly the intro's rect.
# -Offscreen parks it far away while doing so: the size calibration needs the
# window moved, but while the intro is still on screen any app window in view
# shows its (larger) frame around the frameless intro.  Calibrate off-screen,
# then the finish block can place it with a single instant SetWindowPos.
# Leaves z-order and activation untouched (SWP_NOZORDER | SWP_NOACTIVATE),
# so it is safe to call while the intro still holds the foreground.
function Set-AppWindowRect([IntPtr]$Hwnd, [switch]$Offscreen) {
    if ([int64]$Hwnd -eq 0) { return $false }
    try {
        # a minimized or MAXIMIZED window cannot be moved/resized: on a
        # zoomed window SetWindowPos only rewrites the restore bounds while
        # the window stays maximized (the clamp loop would fight it
        # forever) -- restore first, then set the rect.
        if ([WBIntro]::IsIconic($Hwnd) -or [WBIntro]::IsZoomed($Hwnd)) {
            [WBIntro]::ShowWindow($Hwnd, [WBIntro]::SW_RESTORE) | Out-Null
            Start-Sleep -Milliseconds 200
        }
        $key   = ([int64]$Hwnd).ToString()
        $fresh = -not $script:TargetRectCache.ContainsKey($key)
        $t = Get-TargetOuterRect $Hwnd
        $px = $t.x; $py = $t.y
        if ($Offscreen) { $px = -4000; $py = 300 }
        [WBIntro]::SetWindowPos($Hwnd, [IntPtr]::Zero, $px, $py, $t.w, $t.h,
            ([WBIntro]::SWP_NOZORDER -bor [WBIntro]::SWP_NOACTIVATE)) | Out-Null

        if ($fresh) {
            # Closed-loop correction down to 0px: one pixel of app content
            # peeking past the frameless intro already reads as a white edge.
            # Doubao also re-attaches a caption right after being moved
            # sometimes (real frame overhead measured at both 15x8 and
            # 15x37), so measure what happened and correct.
            $ir = Get-IntroRect
            for ($i = 0; $i -lt 2; $i++) {
                Start-Sleep -Milliseconds 200
                $chk = Test-ClientOnIntroRect $Hwnd
                if ($chk.unverified) { break }
                $dx = $ir.x - $chk.x; $dy = $ir.y - $chk.y
                $dw = $ir.w - $chk.w; $dh = $ir.h - $chk.h
                if ($Offscreen) { $dx = 0; $dy = 0 }   # position is meaningless off-screen
                if ($dx -eq 0 -and $dy -eq 0 -and $dw -eq 0 -and $dh -eq 0) {
                    Log 'client area aligned to the intro rect (0px off)'
                    break
                }
                $t = @{ x = $t.x + $dx; y = $t.y + $dy; w = $t.w + $dw; h = $t.h + $dh }
                $qx = $t.x; $qy = $t.y
                if ($Offscreen) { $qx = -4000; $qy = 300 }
                [WBIntro]::SetWindowPos($Hwnd, [IntPtr]::Zero, $qx, $qy, $t.w, $t.h,
                    ([WBIntro]::SWP_NOZORDER -bor [WBIntro]::SWP_NOACTIVATE)) | Out-Null
                Log ("client off by ({0},{1}) {2}x{3} -> corrected" -f $dx, $dy, $dw, $dh)
            }
            $script:TargetRectCache[$key] = $t
        }
        return $true
    } catch {
        Log "Set-AppWindowRect failed: $($_.Exception.Message)"
        return $false
    }
}

# Current on-screen rect of a window as @{x;y;w;h}, or $null.
function Get-WindowRect([IntPtr]$Hwnd) {
    if ([int64]$Hwnd -eq 0) { return $null }
    try {
        $rect = New-Object 'WBIntro+RECT'
        if (-not [WBIntro]::GetWindowRect($Hwnd, [ref]$rect)) { return $null }
        return @{
            x = $rect.Left
            y = $rect.Top
            w = $rect.Right  - $rect.Left
            h = $rect.Bottom - $rect.Top
        }
    } catch {
        return $null
    }
}

# Clamp the app window to the fixed rect for a few seconds.  Electron apps
# (Doubao included) re-apply their own stored bounds ASYNCHRONOUSLY after
# the window appears -- sometimes seconds later -- silently overriding a
# one-shot resize.  This loop re-asserts the rect until the window holds
# it stably, then returns early; it is capped at $Seconds so a user who
# deliberately resizes the window is never fought for long.
function Hold-AppWindowRect([int]$Seconds = 6, [IntPtr]$Hwnd = [IntPtr]::Zero) {
    $deadline  = (Get-Date).AddSeconds($Seconds)
    $stableMs  = 0
    $reasserts = 0
    while ((Get-Date) -lt $deadline) {
        if ([int64]$Hwnd -ne 0) {
            $w = @{ pid = 0; hwnd = $Hwnd }
        } else {
            $w = Find-AppWindow
        }
        if ($w) {
            $r = Get-WindowRect $w.hwnd
            $t = Get-TargetOuterRect $w.hwnd
            if ($r -and [Math]::Abs($r.w - $t.w) -le 2 -and [Math]::Abs($r.h - $t.h) -le 2) {
                $stableMs += 300
                if ($stableMs -ge 900) {
                    Log "app window holding ${script:AppWinW}x${script:AppWinH} client ($($t.w) x $($t.h) outer at ($($t.x),$($t.y)), reasserts=$reasserts)"
                    return $true
                }
            } else {
                $stableMs = 0
                if (Set-AppWindowRect $w.hwnd) { $reasserts++ }
            }
        }
        Start-Sleep -Milliseconds 300
    }
    Log "app window rect clamp timed out after ${Seconds}s (reasserts=$reasserts)"
    return $false
}

# ---- cold-start preloading -------------------------------------------------
# On a cold start the app window appears ~2s in but its page is still blank
# for another ~3.5s.  Parking the window fully off-screen hides that blank
# window behind the intro WITHOUT stalling the page load (verified: the
# window keeps painting while off-screen), and the content-std probe below
# tells us when the page is actually ready, so the intro can hand over to a
# fully loaded app -- the "no white flash" handover.

# Park a window fully outside the desktop (size/z-order/activation kept).
function Park-WindowOffscreen([IntPtr]$Hwnd) {
    if ([int64]$Hwnd -eq 0) { return $false }
    try {
        [WBIntro]::SetWindowPos($Hwnd, [IntPtr]::Zero, -4000, 300, 0, 0,
            ([WBIntro]::SWP_NOSIZE -bor [WBIntro]::SWP_NOZORDER -bor [WBIntro]::SWP_NOACTIVATE)) | Out-Null
        return $true
    } catch {
        Log "Park-WindowOffscreen failed: $($_.Exception.Message)"
        return $false
    }
}

# Managed python used by the content probe (veil.py uses the same one).
$script:ProbePython = 'C:\Users\PC\.workbuddy\binaries\python\versions\3.13.12\python.exe'

# Start the content-ready probe on one window handle.  Returns the probe
# process (check .HasExited / .ExitCode: 0 = page ready, 1 = timeout,
# 2 = window gone) or $null if python is unavailable (the keeper then falls
# back to timing-based handover).
function Start-ReadyProbe([IntPtr]$Hwnd, [int]$ReadyStd = 15, [int]$TimeoutS = 12) {
    if ([int64]$Hwnd -eq 0) { return $null }
    if (-not (Test-Path $script:ProbePython)) {
        Log 'ready probe: managed python not found -> timing fallback'
        return $null
    }
    $probe = Join-Path $PSScriptRoot 'ready-probe.py'
    if (-not (Test-Path $probe)) {
        Log 'ready probe: ready-probe.py missing -> timing fallback'
        return $null
    }
    try {
        # The probe writes its own log (see --log): Start-Process redirection
        # is unusable here (-NoNewWindow dies on this machine because both
        # http_proxy and HTTP_PROXY are set, colliding in PowerShell's
        # case-insensitive env dictionary).
        $log = Join-Path $PSScriptRoot 'ready-probe.log'
        Remove-Item $log -Force -ErrorAction SilentlyContinue
        $p = Start-Process -FilePath $script:ProbePython -WindowStyle Hidden -PassThru `
             -ArgumentList @(
                 $probe, '--hwnd', ([int64]$Hwnd).ToString(),
                 '--until-ready', $ReadyStd.ToString(),
                 '--timeout', $TimeoutS.ToString(),
                 '--interval', '0.25',
                 '--log', $log)
        return $p
    } catch {
        Log "ready probe: could not start ($($_.Exception.Message))"
        return $null
    }
}

# Every LARGE top-level window of the app (splash/IME/helper windows are
# dropped by the size filter).  Returns objects: hwnd, w, h, x, y, title.
# Doubao keeps several same-sized top-level windows around during startup
# (an untitled shadow window next to the real one), so callers that need to
# hide or probe "the app window" must consider all of them.
function Find-AppWindows {
    $pids = Get-AppPids
    if ($pids.Count -eq 0) { return @() }
    $dump = [WBIntro]::ListWindowsByPids($pids)
    if (-not $dump) { return @() }
    $out = @()
    foreach ($line in ($dump -split "`r?`n")) {
        if ($line -notmatch 'hwnd=(0x[0-9A-Fa-f]+).*?rect=(\d+)x(\d+)@\((-?\d+),(-?\d+)\).*?title=''(.*)''\s*$') { continue }
        $w = [int]$Matches[2]; $h = [int]$Matches[3]
        if ($w -lt 400 -or $h -lt 300) { continue }   # splash / IME / helper
        $out += [pscustomobject]@{
            hwnd  = [IntPtr][Convert]::ToInt64($Matches[1].Substring(2), 16)
            w     = $w
            h     = $h
            x     = [int]$Matches[4]
            y     = [int]$Matches[5]
            title = $Matches[6]
        }
    }
    return $out
}

# The app's REAL main window: titled windows outrank untitled ones (the
# title may still be unset during the first second of a cold start), and
# the largest window wins within a rank.  Returns @{ pid; hwnd } or $null.
function Find-AppWindow {
    $wins = @(Find-AppWindows)
    if ($wins.Count -eq 0) { return $null }
    $best = $null; $bestArea = 0; $bestRank = -1
    foreach ($x in $wins) {
        $rank = 1
        if ([string]::IsNullOrWhiteSpace($x.title)) { $rank = 0 }
        $area = $x.w * $x.h
        if ($rank -gt $bestRank -or ($rank -eq $bestRank -and $area -gt $bestArea)) {
            $bestRank = $rank
            $bestArea = $area
            $best = $x
        }
    }
    if (-not $best) { return $null }
    return @{ pid = 0; hwnd = $best.hwnd }
}

# Keep every large app window off-screen.  Called on EVERY keeper tick while
# the intro is up, not just once: Doubao re-applies its remembered window
# bounds asynchronously (seconds later) and also creates extra windows
# during startup, so a one-shot park always leaks some of them back onto the
# screen -- which shows up as a white edge beside the animation.
# $Parked keeps the FIRST seen rect per handle so Restore-ParkedWindows can
# put secondary windows back afterwards.
function Park-AppWindows([hashtable]$Parked) {
    $n = 0
    foreach ($x in @(Find-AppWindows)) {
        $key = ([int64]$x.hwnd).ToString()
        if (-not $Parked.ContainsKey($key)) {
            $Parked[$key] = @{ hwnd = $x.hwnd; x = $x.x; y = $x.y; w = $x.w; h = $x.h }
        }
        if ($x.x -gt -2000) {
            if (Park-WindowOffscreen $x.hwnd) { $n++ }
        }
    }
    return $n
}

# Put parked windows back where they were, except the one that became the
# visible main window (that one is placed by Set-AppWindowRect).  Without
# this an app's secondary window would stay off-screen forever.
function Restore-ParkedWindows([hashtable]$Parked, [IntPtr]$KeepHwnd) {
    $n = 0
    foreach ($v in @($Parked.Values)) {
        if ([int64]$v.hwnd -eq [int64]$KeepHwnd) { continue }
        if ($v.x -lt -2000) { continue }   # it was already off-screen on its own
        try {
            [WBIntro]::SetWindowPos($v.hwnd, [IntPtr]::Zero, $v.x, $v.y, $v.w, $v.h,
                ([WBIntro]::SWP_NOZORDER -bor [WBIntro]::SWP_NOACTIVATE)) | Out-Null
            $n++
        } catch { }
    }
    return $n
}

# Handle reported by the last "ready" line of the probe log (the window that
# actually painted content), or 0 when unavailable.
function Get-ReadyProbeHwnd {
    $log = Join-Path $PSScriptRoot 'ready-probe.log'
    if (-not (Test-Path $log)) { return [int64]0 }
    try {
        $line = Get-Content $log -Tail 6 |
                Where-Object { $_ -match '"state":\s*"ready"' } |
                Select-Object -Last 1
        if ($line -and $line -match '"hwnd":\s*(\d+)') { return [int64]$Matches[1] }
    } catch { }
    return [int64]0
}

# Start the content-ready probe in "track the app" mode: it re-discovers all
# large windows of the app on every sample and reports ready as soon as ANY
# of them paints real content.  That is the reliable signal during a cold
# start, where several same-sized windows coexist and the one holding the
# page is not knowable in advance.
function Start-AppReadyProbe([int]$ReadyStd = 15, [int]$TimeoutS = 12) {
    if (-not (Test-Path $script:ProbePython)) {
        Log 'ready probe: managed python not found -> timing fallback'
        return $null
    }
    $probe = Join-Path $PSScriptRoot 'ready-probe.py'
    if (-not (Test-Path $probe)) {
        Log 'ready probe: ready-probe.py missing -> timing fallback'
        return $null
    }
    try {
        $log = Join-Path $PSScriptRoot 'ready-probe.log'
        Remove-Item $log -Force -ErrorAction SilentlyContinue
        $p = Start-Process -FilePath $script:ProbePython -WindowStyle Hidden -PassThru `
             -ArgumentList @(
                 $probe, '--app', ($AppProcess + '.exe'),
                 '--until-ready', $ReadyStd.ToString(),
                 '--timeout', $TimeoutS.ToString(),
                 '--interval', '0.25',
                 '--log', $log)
        return $p
    } catch {
        Log "ready probe: could not start ($($_.Exception.Message))"
        return $null
    }
}

function Log([string]$Message) {
    # A log write must never break the launcher (the vbs host may hold
    # the file open for its own line at the same moment).
    try {
        $stamp = (Get-Date).ToString('HH:mm:ss')
        Add-Content -LiteralPath $script:LogFile -Value "$stamp  $Message"
    } catch { }
}

# ---- Win32 bindings: prebuilt DLL first, inline compile as fallback -----
$dll = Join-Path $PSScriptRoot 'wbhelper.dll'
$cs  = Join-Path $PSScriptRoot 'wbhelper.cs'
if (Test-Path $dll) {
    Add-Type -Path $dll
} elseif (Test-Path $cs) {
    Add-Type -TypeDefinition (Get-Content -Raw -LiteralPath $cs)
} else {
    throw "neither wbhelper.dll nor wbhelper.cs found next to the scripts"
}

# PIDs of the intro player process (powershell -STA running play.ps1).
function Get-KioskPids {
    Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" |
        Where-Object { $_.CommandLine -like '*play.ps1*' } |
        ForEach-Object { $_.ProcessId }
}

# The dark full-screen veil shown between the click and the intro window
# (see veil.py).  Identified by 'veil.py' in the python command line.
function Kill-Veil {
    $pids = @(Get-CimInstance Win32_Process -Filter "Name='python.exe'" |
        Where-Object { $_.CommandLine -like '*veil.py*' } |
        ForEach-Object { $_.ProcessId })
    foreach ($id in $pids) { Stop-Process -Id $id -Force -ErrorAction SilentlyContinue }
    return $pids.Count
}

# Content-readiness probes (ready-probe.py) left over from a keeper run.
function Kill-ReadyProbe {
    $pids = @(Get-CimInstance Win32_Process -Filter "Name='python.exe'" |
        Where-Object { $_.CommandLine -like '*ready-probe.py*' } |
        ForEach-Object { $_.ProcessId })
    foreach ($id in $pids) { Stop-Process -Id $id -Force -ErrorAction SilentlyContinue }
    return $pids.Count
}

# Handle of the visible intro window, or IntPtr.Zero.
# The player is a -WindowStyle Hidden powershell process hosting a WPF
# window: Get-Process MainWindowHandle does NOT see that window, so the
# window is located by its title markers instead ('<tag>' while the video
# plays, '<tag>-DONE' on the held last frame).
function Get-KioskHandle {
    foreach ($t in @("$TitleTag-DONE", $TitleTag)) {
        $h = [WBIntro]::FindWindowByTitle($t)
        if ($h -ne [IntPtr]::Zero -and [WBIntro]::IsWindowVisible($h)) {
            return $h
        }
    }
    return [IntPtr]::Zero
}

# The app main window: @{ pid; hwnd } or $null.
function Get-AppWindow([switch]$AnyTitle) {
    $p = Get-Process -Name $AppProcess -ErrorAction SilentlyContinue |
         Where-Object { $_.MainWindowHandle -ne [IntPtr]::Zero -and ($AnyTitle -or $_.MainWindowTitle -like $AppTitleLike) } |
         Select-Object -First 1
    if ($p) { return @{ pid = $p.Id; hwnd = $p.MainWindowHandle } }
    return $null
}

# All PIDs of the app (Electron spawns many; the window may live in any of
# them, and the main process exposes a ZERO MainWindowHandle to
# Get-Process).  Used by Find-AppWindow below.
function Get-AppPids {
    @(Get-Process -Name $AppProcess -ErrorAction SilentlyContinue |
        Where-Object { $_.Id } |
        ForEach-Object { [int]$_.Id })
}

# Is the app running at all?  Returns the browser-process PID or 0.
# This is PROCESS-level, not window-level: the app can be tray-ified
# (window destroyed, process alive) or minimized.  The keeper must never
# spawn a second instance in those states -- a single-instance app
# (Electron and friends) would raise/recreate the window right in front
# of the intro (the "flash" users report).
function Get-AppProcessId {
    $p = Get-CimInstance Win32_Process -Filter "Name='$AppProcess.exe'" |
         Where-Object { $_.CommandLine -notlike '*--type=*' } |
         Select-Object -First 1
    if ($p) { return $p.ProcessId }
    return 0
}

# Graceful close first (WM_CLOSE), then a force sweep -- a stuck WPF
# message loop does not always exit on window close, so the sweep is
# mandatory.
function Close-Kiosk {
    $pids = @(Get-KioskPids)
    foreach ($id in $pids) {
        $p = Get-Process -Id $id -ErrorAction SilentlyContinue
        if ($p -and $p.MainWindowHandle -ne [IntPtr]::Zero) { $p.CloseMainWindow() | Out-Null }
    }
    return $pids.Count
}

function Kill-Kiosk {
    $pids = @(Get-KioskPids)
    foreach ($id in $pids) { Stop-Process -Id $id -Force -ErrorAction SilentlyContinue }
    return $pids.Count
}

# Bring the app forward (restore if minimized, force foreground) and pin
# its work window to the fixed AppWinW x AppWinH rect.
function Focus-AppWindow([int]$Tries = 10) {
    for ($i = 0; $i -lt $Tries; $i++) {
        $w = Find-AppWindow
        if ($w) {
            if ([WBIntro]::IsIconic($w.hwnd)) { [WBIntro]::ShowWindow($w.hwnd, [WBIntro]::SW_RESTORE) | Out-Null }
            # Electron apps re-apply their own stored bounds asynchronously
            # after the window appears -- re-assert the rect here so the
            # final resting size is always the fixed one.
            Set-AppWindowRect $w.hwnd | Out-Null
            [WBIntro]::ForceForeground($w.hwnd)
            Start-Sleep -Milliseconds 250
            if ([int64]([WBIntro]::GetForegroundWindow()) -eq [int64]($w.hwnd)) { return $true }
        } else {
            Start-Sleep -Milliseconds 250
        }
    }
    return $false
}
