# play.ps1 -- borderless fullscreen topmost video player for the boot intro.
#
# Native WPF window: no browser, no singleton, no hijack.  (An Edge-kiosk
# player was tried first and failed: Edge keeps a background-resident
# process that sometimes HIJACKS the kiosk launch and opens the video in a
# plain new tab of the user's own profile instead -- the intro then never
# plays and a stray Edge window flashes.)
#
# Must run with powershell -STA (WPF needs an STA thread).
#
# Window title markers (the keeper polls them):
#   <tag>       while the video plays
#   <tag>-DONE  when the video ends (the last frame STAYS on screen; the
#               keeper closes this window once the app is ready, so the
#               animation never ends on a white screen)
#
# Esc ends immediately; a left click toggles mute.  The video plays WITH
# sound by default (mp4 intros normally carry their own audio track) --
# pass -Muted for the old silent behaviour.
param(
    [string]$Video,
    [int]$SelfCloseS  = 30,
    [string]$TitleTag = 'WB-INTRO',
    # 0 = fullscreen (the primary screen's work area).  Pass an explicit
    # -Width/-Height for a windowed intro.
    [int]$Width       = 0,
    [int]$Height      = 0,
    [switch]$Muted
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase

$win = New-Object System.Windows.Window
$win.WindowStyle      = 'None'
$win.ResizeMode       = 'NoResize'
$win.ShowInTaskbar    = $false
$win.Topmost          = $true
$win.Background       = [System.Windows.Media.Brushes]::Black
$win.Title            = $TitleTag
$win.WindowStartupLocation = 'Manual'

# FULLSCREEN by default: the player covers the primary screen's work area
# (screen minus taskbar) and the keeper puts the app's CLIENT area on exactly
# the same rect, so the last frame hands over to the app with nothing of the
# app's frame showing anywhere around it.
#
# The rect comes from WPF's SystemParameters.WorkArea; those values are in
# device-independent units.  At 96 DPI (100% scaling) they equal pixels,
# which is what the Win32 side (veil.py / winframe.py) uses -- keep the
# display at 100% scaling, or set -Width/-Height explicitly.
$wa = [System.Windows.SystemParameters]::WorkArea
$sw = [System.Windows.SystemParameters]::PrimaryScreenWidth
$sh = [System.Windows.SystemParameters]::PrimaryScreenHeight
if ($Width -le 0 -or $Height -le 0) {
    $win.Left   = [int]$wa.Left
    $win.Top    = [int]$wa.Top
    $win.Width  = [int]$wa.Width
    $win.Height = [int]$wa.Height
} else {
    $win.Left   = [int](($sw - $Width)  / 2)
    $win.Top    = [int](($sh - $Height) / 2)
    $win.Width  = $Width
    $win.Height = $Height
}

$vid = New-Object System.Windows.Controls.MediaElement
$vid.Stretch  = 'Fill'
$vid.Volume   = 0
if (-not $Muted) { $vid.Volume = 1.0 }
$vid.LoadedBehavior = 'Manual'
$win.Content  = $vid

$done = $false
$vid.Add_MediaEnded({
    if (-not $done) { $done = $true; $win.Title = $TitleTag + '-DONE' }
})
$vid.Add_MediaFailed({
    if (-not $done) { $done = $true; $win.Title = $TitleTag + '-DONE' }
})

# Esc skips; a left click toggles mute (starts with sound unless -Muted)
$win.Add_KeyDown({
    if ($_.Key -eq 'Escape') { $win.Close() }
})
$win.Add_MouseLeftButtonDown({
    if ($vid.Volume -eq 0) { $vid.Volume = 1.0 } else { $vid.Volume = 0.0 }
})

# hard self-close guard: a stuck decode must never trap the user
$guard = New-Object System.Windows.Threading.DispatcherTimer
$guard.Interval = [TimeSpan]::FromSeconds($SelfCloseS)
$guard.Add_Tick({ $win.Close() })
$guard.Start()

$vid.Source = [System.Uri]::new($Video)
$win.Add_Loaded({ $vid.Play() })
$win.ShowDialog() | Out-Null
exit 0
