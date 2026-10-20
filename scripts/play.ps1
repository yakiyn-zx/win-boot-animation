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

# cover the whole virtual screen (all monitors), not just the primary
$win.Left   = [System.Windows.SystemParameters]::VirtualScreenLeft
$win.Top    = [System.Windows.SystemParameters]::VirtualScreenTop
$win.Width  = [System.Windows.SystemParameters]::VirtualScreenWidth
$win.Height = [System.Windows.SystemParameters]::VirtualScreenHeight

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
