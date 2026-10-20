# stop-intro.ps1 -- end the intro immediately and focus the app.
# Used when the user clicks the app icon again while the intro is still
# playing (impatient second click), and as the launcher's no-intro
# fallback path.
param(
    [string]$App,
    [string]$AppProcess   = 'WorkBuddy',
    [string]$AppTitleLike = 'WorkBuddy*',
    [string]$TitleTag     = 'WB-INTRO'
)
. (Join-Path $PSScriptRoot 'wbutil.ps1') -AppProcess $AppProcess -AppTitleLike $AppTitleLike -TitleTag $TitleTag
$ErrorActionPreference = 'SilentlyContinue'

$closed = Close-Kiosk
Start-Sleep -Milliseconds 400
$killed = Kill-Kiosk
if ($closed -gt 0 -or $killed -gt 0) { Log "intro stopped (closed=$closed killed=$killed)" }
$veil = Kill-Veil
if ($veil -gt 0) { Log "veil dropped ($veil)" }

# Window gone (tray-ified / closed while minimized)?  Spawn one instance
# so the app rebuilds the window before we wait on activation.
if (-not (Get-AppWindow -AnyTitle)) {
    Log 'no app window -> spawning instance to raise it'
    try { Start-Process -FilePath $App } catch { }
}

if (Focus-AppWindow) {
    Log 'app window focused'
} else {
    Log 'no app window to focus'
}
exit 0
