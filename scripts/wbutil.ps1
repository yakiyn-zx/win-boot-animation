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

# Bring the app forward (restore if minimized, force foreground).
function Focus-AppWindow([int]$Tries = 10) {
    for ($i = 0; $i -lt $Tries; $i++) {
        $w = Get-AppWindow -AnyTitle
        if ($w) {
            if ([WBIntro]::IsIconic($w.hwnd)) { [WBIntro]::ShowWindow($w.hwnd, [WBIntro]::SW_RESTORE) | Out-Null }
            [WBIntro]::ForceForeground($w.hwnd)
            Start-Sleep -Milliseconds 250
            if ([int64]([WBIntro]::GetForegroundWindow()) -eq [int64]($w.hwnd)) { return $true }
        } else {
            Start-Sleep -Milliseconds 250
        }
    }
    return $false
}
