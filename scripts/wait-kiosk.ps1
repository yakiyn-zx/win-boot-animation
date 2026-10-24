# wait-kiosk.ps1 -- intro keeper, run synchronously by the launcher vbs.
#
# Owns the whole intro lifetime after the intro player (play.ps1, a native
# WPF window) is launched:
#
#   1) wait until the intro window is really on screen (title <tag>*)
#      -- the app must never flash in front of the intro
#   2) start the app right then, so the app's cold-start time overlaps
#      the video instead of being exposed after it (skipped entirely if
#      the app already runs -- spawning a second instance would make a
#      single-instance app raise the existing window right in front of
#      the intro)
#   3) pin the intro above everything and take the foreground back for
#      the whole intro: a newly created app window steals the foreground
#      the moment it appears -- that is what made the workspace jump in
#      front of the animation 2-3s in.  (Most app windows are not
#      topmost, so the pin alone already keeps them visually behind the
#      intro.)
#   4) wait for the video to finish: play.ps1 sets the window title to
#      <tag>-DONE and holds its last frame instead of closing itself,
#      so "intro over" is an exact signal instead of a process poll
#   5) settle briefly until the app window is up, then un-pin the intro,
#      close it and bring the app forward -- the animation never ends on
#      a white or half-loaded screen
#
# Exit codes: 0 = normal, 1 = fatal (caller falls back to AppActivate),
# 2 = the intro window never appeared (caller starts the app directly).
param(
    [string]$App,
    [string]$AppProcess   = 'WorkBuddy',
    [string]$AppTitleLike = 'WorkBuddy*',
    [string]$TitleTag     = 'WB-INTRO',
    [int]$PollMs       = 80,
    [int]$SettleMs     = 600,
    [int]$HoldCapS     = 4,
    [int]$TotalCapS    = 90,
    [int]$WindowWaitS  = 12
)

. (Join-Path $PSScriptRoot 'wbutil.ps1') -AppProcess $AppProcess -AppTitleLike $AppTitleLike -TitleTag $TitleTag

# ---- 1) wait for the intro window --------------------------------------
# (No veil sweep here: the veil was started by the launcher ~1s ago and
# is still needed.  Every abnormal path has its own veil cleanup: the
# launcher's fallbacks call stop-intro.ps1, and the veil self-exits
# after 12s even if everything else dies.)
Log 'intro keeper started'

# Hide already-running app windows RIGHT NOW.  The intro player takes ~1s to
# come up, and until the app is parked its (larger, framed) window shows a
# rim of white around the veil / animation -- the "white edge flash".
$parkedSet = @{}
try {
    $n0 = Park-AppWindows -Parked $parkedSet
    if ($n0 -gt 0) { Log "pre-parked $n0 app window(s) off-screen" }
} catch { }

$windowAt = $null
$deadline = (Get-Date).AddSeconds($WindowWaitS)
$graceOver = (Get-Date).AddSeconds(5)
$titleKnown = $false
while ((Get-Date) -lt $deadline) {
    $h = Get-KioskHandle
    if ($h -ne [IntPtr]::Zero) {
        if (-not $windowAt) {
            $windowAt = Get-Date
            Log 'intro window appeared -> pinning it immediately'
        }
        # Pin from the very first moment, before the title settles and
        # before the app starts: anything that grabs focus in the next
        # second (e.g. an already-running app window being activated)
        # must not be able to flash in front of the intro.
        [WBIntro]::SetWindowPos($h, [WBIntro]::HWND_TOPMOST, 0, 0, 0, 0,
            ([WBIntro]::SWP_NOMOVE -bor [WBIntro]::SWP_NOSIZE -bor [WBIntro]::SWP_NOACTIVATE)) | Out-Null
        $t = [WBIntro]::Title($h)
        if (-not $titleKnown) {
            Log "intro window title: '$t'"
            if ($t -like "$TitleTag*") { $titleKnown = $true }
        }
        if ($titleKnown -or ((Get-Date) -gt $graceOver)) {
            if (-not $titleKnown) { Log 'intro title unreadable -> proceeding anyway' }
            break
        }
    }
    Start-Sleep -Milliseconds 200
}
if (-not $windowAt) {
    Log 'intro window did not appear -> exit 2'
    Kill-Veil | Out-Null
    exit 2
}
# The intro window is on screen and pinned above the veil, and the video
# is starting -- drop the veil so the animation shows.  Until this moment
# the veil hid the previous screen contents during the player's startup.
$veilDropped = Kill-Veil
if ($veilDropped -gt 0) { Log "veil dropped ($veilDropped)" }

# ---- 2) start the app behind the intro ---------------------------------
$appPid   = Get-AppProcessId
$coldStart= $false
if ($appPid -gt 0) {
    # The app is already running (window open, minimized, or tray-ified).
    # Spawning a second instance would make single-instance logic
    # raise/recreate the window right now -- flashing it in front of the
    # intro.  Skip the spawn; the keeper focuses the window when the video
    # is over (raising a tray-ified window happens then, behind a closed
    # intro, so no flash is visible).
    Log "app already running (pid $appPid) -> holding it behind the intro (no second instance)"
} else {
    Log 'intro on screen -> starting app behind it'
    try { Start-Process -FilePath $App } catch { Log "could not start app: $($_.Exception.Message)" }
    # Cold start: the app window will appear ~2s in but its page stays blank
    # ~3.5s more.  The keeper parks that window off-screen and waits for the
    # page to be really ready before handing over (no white flash).
    $coldStart = $true
}

# ---- 3+4+5) hold, watch, finish ----------------------------------------
$start      = Get-Date
$introAt    = $null
$wbAt       = $null
$wbClosed   = $false
$kioskGoneAt= $null
$titleBlind = $false
$kioskH     = [IntPtr]::Zero
$raised     = $false
$readyAt    = $null
$probe      = $null
$probeFailed= $false
$finalHwnd  = [IntPtr]::Zero

try {
    while ($true) {
        Start-Sleep -Milliseconds $PollMs
        $now = Get-Date

        # resolve the visible intro window (title markers -- the player's
        # WPF window is invisible to Get-Process MainWindowHandle)
        $kioskH = Get-KioskHandle

        if ($kioskH -eq [IntPtr]::Zero) {
            if (-not $kioskGoneAt) { $kioskGoneAt = $now }
            if (($now - $kioskGoneAt).TotalSeconds -ge 2) {
                Log 'intro window closed (skipped or ended) -> finishing'
                break
            }
            continue
        }
        $kioskGoneAt = $null

        # --- hold the intro on screen -----------------------------------
        if ([int64]([WBIntro]::GetForegroundWindow()) -ne [int64]$kioskH) {
            [WBIntro]::ForceForeground($kioskH)
        }
        [WBIntro]::SetWindowPos($kioskH, [WBIntro]::HWND_TOPMOST, 0, 0, 0, 0,
            ([WBIntro]::SWP_NOMOVE -bor [WBIntro]::SWP_NOSIZE -bor [WBIntro]::SWP_NOACTIVATE)) | Out-Null

        # --- has the video finished? (window title marker) ---------------
        $title = [WBIntro]::Title($kioskH)
        if (-not $introAt) {
            if ($title -like "*$TitleTag-DONE*") {
                $introAt = $now
                Log 'intro video finished (marker seen)'
            } elseif (-not $titleKnown -and $windowAt -and ($now - $windowAt).TotalSeconds -ge 12) {
                $titleBlind = $true
                $introAt = $now
                Log 'intro video assumed finished (title unreadable, timing fallback)'
            }
        }

        # --- is the app window up? ---------------------------------------
        $wb = Find-AppWindow
        if ($wb -and -not $wbAt) {
            $wbAt = $now
            Log 'app window visible'
        }
        if (-not $wb -and $wbAt -and -not $wbClosed) {
            # the user closed the app while the intro held the screen
            $wbClosed = $true
            Log 'app window closed by user -> finishing'
            break
        }

        # --- keep the app off-screen while the intro is up ---------------
        # Cold AND warm: the app's frame / title bar stick out around the
        # frameless intro window, so any app window left on screen shows a
        # sliver of "app edge" beside the animation.  Doubao also keeps an
        # untitled shadow window next to the real one during a cold start,
        # and either can be the one painting the blank page, so ALL large
        # app windows are parked (loading continues while parked -- verified).
        if ($wbAt -and -not $introAt) {
            $nParked = Park-AppWindows -Parked $parkedSet
            if ($nParked -gt 0) {
                Log "parked $nParked app window(s) off-screen"
            }
            if (-not $readyAt) {
                if (-not $coldStart) {
                    # Warm start: the page is already loaded -- nothing to
                    # wait for, the window only has to stay hidden until the
                    # intro is over.
                    $readyAt = $now
                    $warm = Find-AppWindow
                    if ($warm) {
                        $finalHwnd = $warm.hwnd
                        Set-AppWindowRect $finalHwnd -Offscreen | Out-Null
                    }
                    Log 'warm start: page already loaded -> calibrated off-screen'
                } elseif (-not $probe -and -not $probeFailed) {
                    $probe = Start-AppReadyProbe
                    if ($probe) {
                        Log 'cold start: probing page readiness'
                    } else {
                        $probeFailed = $true
                        Log 'cold start: probe unavailable -> timing fallback'
                    }
                }
            }
        }

        # --- cold-start page readiness ------------------------------------
        if ($probe -and -not $readyAt) {
            $probeDone = $false
            try { $probe.Refresh(); $probeDone = $probe.HasExited } catch { $probeDone = $true }
            if ($probeDone) {
                $code = 1
                try { $probe.WaitForExit(2000) | Out-Null; $code = $probe.ExitCode } catch { $code = 1 }
                if ($code -eq 0) {
                    $readyAt = $now
                    $readyHwnd = Get-ReadyProbeHwnd
                    if ($readyHwnd -gt 0) {
                        $finalHwnd = [IntPtr]$readyHwnd
                    } else {
                        $wb2 = Find-AppWindow
                        if ($wb2) { $finalHwnd = $wb2.hwnd }
                    }
                    if ($finalHwnd -ne [IntPtr]::Zero) {
                        # Calibrate the size while it is still off-screen;
                        # the finish block then only has to move it.
                        Set-AppWindowRect $finalHwnd -Offscreen | Out-Null
                    }
                    Log 'app page ready -> calibrated off-screen, hidden until the intro ends'
                } else {
                    Log "ready probe ended (exit=$code) -> timing fallback"
                    $probeFailed = $true
                }
            }
        }

        # --- finish conditions ------------------------------------------
        if ($introAt -and $wbAt -and ($now - $wbAt).TotalSeconds -ge ($SettleMs / 1000)) {
            # On a cold start, hold the last frame until the page is really
            # ready -- handing over earlier would land on a white screen.
            # HoldCapS below caps the wait; a failed probe falls back to
            # plain timing.
            if ($coldStart -and -not $readyAt -and -not $probeFailed) {
                # keep holding (page not ready yet)
            } else {
                Log 'video done + app settled -> finishing'
                break
            }
        }
        if ($introAt -and -not $wb) {
            $appProcUp = (Get-AppProcessId) -gt 0
            if (-not $appProcUp -and -not $raised) {
                # Truly no app process (closed / tray-ified): cold-start one.
                $raised = $true
                Log 'video done but app not running -> spawning instance'
                try { Start-Process -FilePath $App } catch { Log "could not start app: $($_.Exception.Message)" }
            } elseif ($appProcUp -and -not $raised) {
                # App process is up (it is the running instance) but its
                # window is not yet detectable.  NEVER spawn a second
                # instance -- a single-instance app would just re-activate
                # it, adding seconds of frozen-frame freeze.  Keep waiting
                # for the window to become findable.
                $raised = $true
                Log 'video done, app process up but window not yet detectable -> waiting'
            }
        }
        if ($introAt -and ($now - $introAt).TotalSeconds -ge $HoldCapS) {
            Log "app still not ready $HoldCapS s after the video -> finishing anyway"
            break
        }
        if (($now - $start).TotalSeconds -ge $TotalCapS) {
            Log 'total time cap reached -> finishing'
            break
        }
    }
} catch {
    Log "keeper error: $($_.Exception.Message)"
    Kill-Veil | Out-Null
    Kill-ReadyProbe | Out-Null
    # Never leave the frozen last frame on screen: an error exit with the
    # intro still up looks like a permanent hang to the user.
    try { Close-Kiosk | Out-Null; Start-Sleep -Milliseconds 300; Kill-Kiosk | Out-Null } catch { }
    try { Restore-ParkedWindows -Parked $parkedSet -KeepHwnd ([IntPtr]::Zero) | Out-Null } catch { }
    try {
        $wErr = Find-AppWindow
        if ($wErr) {
            # never leave the app parked off-screen after an error exit
            Set-AppWindowRect $wErr.hwnd | Out-Null
            if (-not [WBIntro]::IsWindowVisible($wErr.hwnd)) {
                [WBIntro]::ShowWindow($wErr.hwnd, 5) | Out-Null
            }
            [WBIntro]::ForceForeground($wErr.hwnd)
        }
    } catch { }
    exit 1
}

# ---- finish: release the intro, then bring the app forward -------------
if ($kioskH -ne [IntPtr]::Zero) {
    [WBIntro]::SetWindowPos($kioskH, [WBIntro]::HWND_NOTOPMOST, 0, 0, 0, 0,
        ([WBIntro]::SWP_NOMOVE -bor [WBIntro]::SWP_NOSIZE -bor [WBIntro]::SWP_NOACTIVATE)) | Out-Null
}

# Put the app window ON the intro rect BEFORE the intro goes away (z-order
# and activation untouched, so the intro still covers it): closing the intro
# then reveals the app instantly, with no desktop flash in between.
if ($finalHwnd -eq [IntPtr]::Zero) {
    $w0 = Find-AppWindow
    if ($w0) { $finalHwnd = $w0.hwnd }
}
if ($finalHwnd -ne [IntPtr]::Zero) {
    if (Set-AppWindowRect $finalHwnd) { Log 'app window placed on the intro rect' }
}

# Close the intro right away: the app's frame is wider than the frameless
# intro, so every extra millisecond with both on screen shows a rim of app
# around the animation.  The player's PID comes straight from its window
# handle (Close-Kiosk's WMI lookup costs a few hundred ms).
$kioskPid = 0
if ($kioskH -ne [IntPtr]::Zero) { $kioskPid = [WBIntro]::ProcessIdOf($kioskH) }
if ($kioskPid -gt 0) {
    Stop-Process -Id $kioskPid -Force -ErrorAction SilentlyContinue
    Log 'intro closed (fast path)'
} else {
    $closed = Close-Kiosk
    if ($closed -gt 0) { Log "intro closed ($closed kiosk process(es))" }
}

# No window at all (tray-ified, closed while minimized, or the intro was
# skipped so early the app never started)?  Spawn one instance so the app
# rebuilds/raises the window BEFORE we wait on activation -- otherwise
# Focus-AppWindow spins for seconds with the intro already closed.
if (-not (Find-AppWindow)) {
    Log 'no app window -> spawning instance to raise it'
    try { Start-Process -FilePath $App } catch { Log "could not start app: $($_.Exception.Message)" }
}

# Cold-start fallback: if the page was never confirmed ready (probe
# timeout/failure) the window is still parked off-screen -- move it in now,
# or the user would be left with an invisible app.
if ($coldStart -and -not $readyAt) {
    $wb3 = Find-AppWindow
    if ($wb3 -and (Set-AppWindowRect $wb3.hwnd)) {
        Log 'cold-start fallback: parked window moved in (page not confirmed)'
    }
}

# Prefer the exact window the probe saw painting content: Find-AppWindow
# could otherwise pick Doubao's untitled shadow window instead of the UI.
$focused = $false
if ($finalHwnd -ne [IntPtr]::Zero) {
    $rr = Get-WindowRect $finalHwnd
    if ($rr) {
        try {
            if ([WBIntro]::IsIconic($finalHwnd)) { [WBIntro]::ShowWindow($finalHwnd, [WBIntro]::SW_RESTORE) | Out-Null }
            # tray-ified app: the window exists but is hidden -- show it,
            # otherwise the user would end up with an invisible app.
            if (-not [WBIntro]::IsWindowVisible($finalHwnd)) {
                [WBIntro]::ShowWindow($finalHwnd, 5) | Out-Null   # SW_SHOW
                Start-Sleep -Milliseconds 120
            }
            Set-AppWindowRect $finalHwnd | Out-Null
            [WBIntro]::ForceForeground($finalHwnd)
            Start-Sleep -Milliseconds 150
            $focused = ([int64]([WBIntro]::GetForegroundWindow()) -eq [int64]$finalHwnd)
        } catch { $focused = $false }
    }
}
if (-not $focused) {
    if (Focus-AppWindow) { Log 'app window brought forward' }
    else { Log 'no app window to activate' }
} else {
    Log 'app window brought forward'
}

# Put any still-parked secondary window back where it was (the visible main
# window is excluded -- it was just placed at the fixed rect).
$restored = Restore-ParkedWindows -Parked $parkedSet -KeepHwnd $finalHwnd
if ($restored -gt 0) { Log "cold start: restored $restored secondary window(s)" }

# Electron apps re-apply their own stored window bounds asynchronously
# after appearing -- hold the fixed rect until it sticks.  Pin the exact
# window we handed over to when we know it.
if ($finalHwnd -ne [IntPtr]::Zero) {
    Hold-AppWindowRect -Hwnd $finalHwnd | Out-Null
} else {
    Hold-AppWindowRect | Out-Null
}

# Stop the readiness probe if it is still running (timeout longer than
# the keeper's own caps).
if ($probe) {
    try { $probe.Refresh(); if (-not $probe.HasExited) { Stop-Process -Id $probe.Id -Force -ErrorAction SilentlyContinue } } catch { }
}

$killed = Kill-Kiosk
if ($killed -gt 0) { Log "$killed kiosk process(es) force-killed" }
exit 0
