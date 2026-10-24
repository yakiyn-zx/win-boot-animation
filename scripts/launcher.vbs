' ============================================================
'  Boot animation launcher -- target of the app's desktop /
'  start-menu shortcuts after retargeting (see SKILL.md).
'
'  Runs under wscript.exe -> no console window ever appears.
'
'  This is a thin stub: it covers the screen with a dark veil and
'  launches the intro player (play.ps1, a native WPF window -- no
'  browser, no singleton, no hijack), then hands everything else to
'  the keeper (wait-kiosk.ps1), which runs synchronously and owns
'  the rest of the flow:
'
'   1) wait until the intro window is really on screen
'   2) start the app right then (loads BEHIND the intro)
'   3) pin the intro above everything and take the foreground
'      back for the whole intro -- the app window cannot jump
'      in front of the animation
'   4) wait for the video to end (window title marker) AND the
'      app window to be ready
'   5) close the intro and bring the app forward
'
'  Esc skips the intro.  Clicking the icon again while it plays
'  ends it at once (stop-intro.ps1).  Every step is appended to
'  <dir>\launch.log.
'
'  >>> EDIT THE FIVE PATHS BELOW, then copy this file to the app's
'      install directory with an EQUAL-LENGTH name to the original
'      exe (e.g. WorkBuddy.exe -> WorkBuddy.vbs) and retarget the
'      shortcut with scripts\lnktool.py subst. <<<
' ============================================================

Option Explicit

Dim sh, fso
Dim base, python, app, appProc, appTitle, titleTag, logfile, t0, rc

' ---- configuration ------------------------------------------------------
base     = "C:\Users\PC\.workbuddy\boot-animation"   ' this script set's dir
python   = "C:\Users\PC\.workbuddy\binaries\python\versions\3.13.12\python.exe"
app      = "D:\WBD\WorkBuddy\WorkBuddy.exe"          ' the real app exe
appProc  = "WorkBuddy"                               ' process name (no .exe)
appTitle = "WorkBuddy*"                              ' main window title pattern
                                                   ' ASCII ONLY!  The vbs host reads
                                                   ' this file as GBK (system ANSI) --
                                                   ' Chinese patterns arrive as
                                                   ' mojibake and never match.  Use "*"
                                                   ' (any titled window of the process)
                                                   ' when the real title is non-ASCII.
titleTag = "WB-INTRO"                                ' player window title tag
logfile  = base & "\launch.log"

Set sh  = CreateObject("WScript.Shell")
Set fso = CreateObject("Scripting.FileSystemObject")

t0 = Now
Log "launcher started"

' ---- second click while the intro plays: end it, focus the app ----------
If IntroRunning() Then
    Log "intro already playing -> ending it and focusing app"
    sh.Run PSFile(base & "\stop-intro.ps1", "-App """ & app & """ -AppProcess " & appProc & " -AppTitleLike """ & appTitle & """ -TitleTag " & titleTag), 0, True
    Log "launcher done"
    WScript.Quit
End If

' ---- cover the screen instantly, then launch the intro ------------------
' Between the click and the intro window (~1-2s) the previous screen
' contents stay visible -- that read as a "flash" at the start of the
' animation.  The dark veil (click-through, self-exiting) covers the
' gap; the keeper drops it the moment the intro window is pinned.
' --app makes the veil hide the app's own windows BEFORE it is drawn: the
' veil is exactly intro-sized, and the app's framed window would otherwise
' show a rim of itself around it.
sh.Run """" & python & """ """ & base & "\veil.py"" 12 --app " & appProc, 0, False

' ---- launch the intro player (native WPF window, no browser) ------------
Log "starting intro player"
sh.Run "powershell -NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File """ & base & "\play.ps1"" -Video """ & base & "\videos\intro.mp4"" -TitleTag " & titleTag, 0, False

rc = sh.Run(PSFile(base & "\wait-kiosk.ps1", "-App """ & app & """ -AppProcess " & appProc & " -AppTitleLike """ & appTitle & """ -TitleTag " & titleTag), 0, True)

Select Case rc
    Case 0
        Log "intro finished after " & DateDiff("s", t0, Now) & "s, app is forward"
    Case 2
        Log "intro window never appeared -> starting app directly"
        sh.Run PSFile(base & "\stop-intro.ps1", "-App """ & app & """ -AppProcess " & appProc & " -AppTitleLike """ & appTitle & """ -TitleTag " & titleTag), 0, True
        sh.Run """" & app & """", 1, False
        ActivateApp
    Case Else
        Log "keeper failed (rc=" & rc & ") -> activating app directly"
        sh.Run PSFile(base & "\stop-intro.ps1", "-App """ & app & """ -AppProcess " & appProc & " -AppTitleLike """ & appTitle & """ -TitleTag " & titleTag), 0, True
        ActivateApp
End Select

Log "launcher done"

' ============================================================
Function PSFile(p, extra)
    Dim s
    s = "powershell -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File """ & p & """"
    If extra <> "" Then s = s & " " & extra
    PSFile = s
End Function

' Fallback activation (only if the keeper could not run at all).
Sub ActivateApp()
    Dim i
    On Error Resume Next
    For i = 1 To 14
        Err.Clear
        sh.AppActivate appTitle
        If Err.Number = 0 Then
            Log "app window activated"
            Exit Sub
        End If
        WScript.Sleep 500
    Next
    Log "app window not activated (title not found yet)"
End Sub

' True when THIS app's intro player is already on screen (double-click
' guard).  Match both the player script and this app's title tag, so a
' second app's intro (e.g. WorkBuddy's) never false-triggers.
Function IntroRunning()
    Dim wmi, procs, p
    IntroRunning = False
    On Error Resume Next
    Set wmi = GetObject("winmgmts:\\.\root\cimv2")
    Set procs = wmi.ExecQuery("Select CommandLine from Win32_Process Where Name='powershell.exe'")
    For Each p In procs
        If InStr(p.CommandLine, "play.ps1") > 0 And InStr(p.CommandLine, "-TitleTag " & titleTag) > 0 Then
            IntroRunning = True
            Exit Function
        End If
    Next
End Function

Sub Log(msg)
    Dim f
    Set f = fso.OpenTextFile(logfile, 8, True)   ' 8 = ForAppending
    f.WriteLine Now & "  " & msg
    f.Close
End Sub
