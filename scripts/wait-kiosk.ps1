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
    [int]$PollMs       = 150,
    [int]$SettleMs     = 600,
    [int]$HoldCapS     = 10,
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
$appPid = Get-AppProcessId
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

        # --- finish conditions ------------------------------------------
        if ($introAt -and $wbAt -and ($now - $wbAt).TotalSeconds -ge ($SettleMs / 1000)) {
            Log 'video done + app settled -> finishing'
            break
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
    exit 1
}

# ---- finish: release the intro, then bring the app forward -------------
if ($kioskH -ne [IntPtr]::Zero) {
    [WBIntro]::SetWindowPos($kioskH, [WBIntro]::HWND_NOTOPMOST, 0, 0, 0, 0,
        ([WBIntro]::SWP_NOMOVE -bor [WBIntro]::SWP_NOSIZE -bor [WBIntro]::SWP_NOACTIVATE)) | Out-Null
}
$closed = Close-Kiosk
if ($closed -gt 0) { Log "intro closed ($closed kiosk process(es))" }

# No window at all (tray-ified, closed while minimized, or the intro was
# skipped so early the app never started)?  Spawn one instance so the app
# rebuilds/raises the window BEFORE we wait on activation -- otherwise
# Focus-AppWindow spins for seconds with the intro already closed.
if (-not (Find-AppWindow)) {
    Log 'no app window -> spawning instance to raise it'
    try { Start-Process -FilePath $App } catch { Log "could not start app: $($_.Exception.Message)" }
}

if (Focus-AppWindow) {
    Log 'app window brought forward'
} else {
    Log 'no app window to activate'
}

$killed = Kill-Kiosk
if ($killed -gt 0) { Log "$killed kiosk process(es) force-killed" }
exit 0
