#Requires AutoHotkey v2.0
#SingleInstance Force
InstallKeybdHook
Persistent
SendMode "Input"
SetTitleMatchMode 2
SetWorkingDir A_ScriptDir

; ============================================================================
;  MacKeys - macOS keyboard behaviour for Windows
; ============================================================================
;  Built for: Apple Magic Keyboard + Magic Trackpad -> Mac -> Deskflow -> here.
;
;  Deskflow forwards the Mac's Command key as the Windows key, so Command is
;  remapped from Win. Ctrl and Alt are deliberately left alone, which means:
;    - the local (Dell) keyboard keeps behaving like normal Windows
;    - Ctrl is free for macOS's system-wide emacs text nav, just like a Mac
;
;  Panic switch:  Ctrl+Alt+F12   suspend / resume every remap in here
;  Toggles:       Win+Alt+E      emacs text navigation on/off
;                 Win+Alt+S      invert scroll direction on/off
;  The tray icon has the same options, plus Edit and Reload.
; ============================================================================

; ---------------------------------------------------------------- config ----
EmacsNav    := true      ; Ctrl+A/E/B/F/N/P/D/H/K behave like macOS
InvertWheel := false     ; set true if scrolling feels backwards

; Apps where Ctrl must stay sacred (Ctrl+C = interrupt, Ctrl+A = tmux prefix)
TerminalApps := Map()
for exe in StrSplit("windowsterminal.exe,cmd.exe,powershell.exe,pwsh.exe"
                  . ",conhost.exe,openconsole.exe,mintty.exe,putty.exe"
                  . ",wsl.exe,ubuntu.exe,bash.exe,alacritty.exe"
                  . ",wezterm-gui.exe,hyper.exe,kitty.exe,tabby.exe", ",")
    TerminalApps[exe] := true

; ------------------------------------------------------------- helpers ------
ActiveExe() {
    try return StrLower(WinGetProcessName("A"))
    catch
        return ""
}

IsTerminal() => TerminalApps.Has(ActiveExe())
IsExplorer() => (ActiveExe() = "explorer.exe")

; Release the physically-held Win key, then send the real shortcut. {Blind}
; preserves any extra modifier the user holds, so Cmd+Shift+Z arrives as
; Ctrl+Shift+Z without needing a second hotkey for every single key.
Pass(keys) => Send("{Blind}{LWin up}{RWin up}" keys)

; Same, but also drops Shift / Ctrl / Alt so the target combo is exact.
Only(keys) => Send("{LWin up}{RWin up}{Shift up}{Ctrl up}{Alt up}" keys)

CmdOf(target) => (*) => Pass("^" target)

; ------------------------------------------------- Cmd+<key> -> Ctrl+<key> --
; c and v are handled below (terminals want Ctrl+Shift+C/V).
; h, m and q are window actions; backtick is the same-app window cycler.
for key in StrSplit("abdefgijklnoprstuwxyz1234567890,./;=-")
    try Hotkey("*#" key, CmdOf(key))

; Copy / paste: inside a terminal use the terminal's own bindings, so that
; Ctrl+C stays free as interrupt - exactly how Terminal.app behaves on a Mac.
*#c:: Pass(IsTerminal() ? "^+c" : "^c")
*#v:: Pass(IsTerminal() ? "^+v" : "^v")

; -------------------------------------------------------- window actions ----
#q:: Pass("!{F4}")                          ; Cmd+Q        quit app
#m:: Minimize()                             ; Cmd+M        minimise
#h:: Minimize()                             ; Cmd+H        hide app
#^f:: Only("#{Up}")                         ; Cmd+Ctrl+F   fullscreen
#!Escape:: Only("^+{Escape}")               ; Force Quit -> Task Manager
#^q:: DllCall("user32\LockWorkStation")     ; Cmd+Ctrl+Q   lock screen

Minimize() {
    try WinMinimize "A"
}

; Cmd+Tab - a real held-open app switcher, not a single poke. AutoHotkey's
; AltTab action insists on exactly one L/R-qualified modifier, hence both sides
; spelled out; Cmd+Shift+Tab has to drive the switcher backwards by hand.
<#Tab:: AltTab
>#Tab:: AltTab
*#+Tab:: CmdShiftTab()

CmdShiftTab() {
    if GetKeyState("Alt")                       ; switcher is already open
        Send "{Blind}{LWin up}{RWin up}{Tab}"   ; Shift stays held -> backwards
    else
        Send "{LWin up}{RWin up}{Shift up}!+{Tab}"
}

; Cmd+backtick cycles windows of the frontmost app. SC029 is the backtick key;
; naming it literally would collide with AutoHotkey's escape character.
#SC029:: CycleAppWindows()

CycleAppWindows() {
    exe := ActiveExe()
    if (exe = "")
        return
    wins := []
    for hwnd in WinGetList("ahk_exe " exe) {
        if (WinGetTitle(hwnd) != "" && DllCall("user32\IsWindowVisible", "ptr", hwnd))
            wins.Push(hwnd)
    }
    if (wins.Length < 2)
        return
    try WinActivate wins[2]                 ; next window down the z-order
}

; ------------------------------------------------------------- Spotlight ----
; PowerToys Run already listens on Alt+Space; Cmd+Space relays to it.
#Space:: Only("!{Space}")

; --------------------------------------------------- Mission Control etc ----
^Up:: Only("#{Tab}")                        ; Mission Control
^Left:: Only("#^{Left}")                    ; previous Space
^Right:: Only("#^{Right}")                  ; next Space

; ---------------------------------------------------------- screenshots -----
#+3:: Only("#{PrintScreen}")                ; whole screen, saved to a file
#+4:: Only("#+s")                           ; region (Snipping Tool)
#+5:: Only("#!r")                           ; screen recording (Game Bar)

; ------------------------------------------------------- text navigation ----
; Cmd+arrows = line / document ends, Option+arrows = by word. In Explorer,
; Cmd+Up/Down keep their Finder meaning: parent folder, and open.
*#Left::  Pass("{Home}")
*#Right:: Pass("{End}")
*#Up::    CmdUp()
*#Down::  CmdDown()

CmdUp() {
    if IsExplorer()
        Pass("!{Up}")
    else
        Pass("^{Home}")
}
CmdDown() {
    if IsExplorer()
        Pass("{Enter}")
    else
        Pass("^{End}")
}

*!Left::  Send "{Blind}{LAlt up}{RAlt up}^{Left}"     ; word left
*!Right:: Send "{Blind}{LAlt up}{RAlt up}^{Right}"    ; word right
*!Up::    Send "{Blind}{LAlt up}{RAlt up}^{Up}"       ; paragraph up
*!Down::  Send "{Blind}{LAlt up}{RAlt up}^{Down}"     ; paragraph down

#[:: Only("!{Left}")                        ; Cmd+[  back
#]:: Only("!{Right}")                       ; Cmd+]  forward

; Deletions
#BackSpace:: Pass("+{Home}{Delete}")                  ; delete to line start
!BackSpace:: Send "{Blind}{LAlt up}{RAlt up}^{BackSpace}"    ; delete word left

; ------------------------------------- macOS emacs bindings (Ctrl+letter) ---
#HotIf (EmacsNav && !IsTerminal())
^a:: Send "{Blind}{LCtrl up}{RCtrl up}{Home}"
^e:: Send "{Blind}{LCtrl up}{RCtrl up}{End}"
^b:: Send "{Blind}{LCtrl up}{RCtrl up}{Left}"
^f:: Send "{Blind}{LCtrl up}{RCtrl up}{Right}"
^p:: Send "{Blind}{LCtrl up}{RCtrl up}{Up}"
^n:: Send "{Blind}{LCtrl up}{RCtrl up}{Down}"
^d:: Only("{Delete}")
^h:: Only("{BackSpace}")
^k:: Only("+{End}{Delete}")                 ; kill to end of line
#HotIf

; --------------------------------------------------------------- scroll -----
#HotIf InvertWheel
WheelUp:: Send "{WheelDown}"
WheelDown:: Send "{WheelUp}"
#HotIf

; --------------------------------------------- trackpad gesture receiver ----
; The Magic Trackpad stays on the Mac, and Deskflow forwards no multi-touch at
; all - gestures are interpreted on the machine the trackpad is attached to.
; So BetterTouchTool on the Mac converts each gesture into one of these
; otherwise-unused chords, which Deskflow forwards like any ordinary key, and
; they get turned back into the Windows equivalent here.
;
; Import MacKeys-Gestures.bttpreset on the Mac to set the sending half up.
; Continuous gestures (pinch zoom, smooth swipe tracking) cannot work this way:
; there is no gesture stream to interpolate, only a discrete keypress.
;
;   Mac gesture                chord              Windows action
^!+1:: Only("#{Tab}")        ; 3-finger up      -> Mission Control / Task View
^!+2:: CycleAppWindows()     ; 3-finger down    -> App Expose
^!+3:: Only("#^{Right}")     ; 3-finger left    -> next Space
^!+4:: Only("#^{Left}")      ; 3-finger right   -> previous Space
^!+5:: Only("!{Space}")      ; 4-finger pinch   -> Launchpad / PowerToys Run
^!+6:: Only("#d")            ; 4-finger spread  -> Show Desktop

; -------------------------------------------------------------- toggles -----
^!F12:: ToggleSuspend()
#!e:: ToggleEmacs()
#!s:: ToggleWheel()

ToggleSuspend() {
    Suspend -1
    TrayTip((A_IsSuspended ? "Suspended" : "Active"), "MacKeys")
}
ToggleEmacs() {
    global EmacsNav := !EmacsNav
    TrayTip("Emacs text navigation: " (EmacsNav ? "on" : "off"), "MacKeys")
}
ToggleWheel() {
    global InvertWheel := !InvertWheel
    TrayTip("Inverted scrolling: " (InvertWheel ? "on" : "off"), "MacKeys")
}

; ----------------------------------------------------------------- tray -----
A_TrayMenu.Delete()
A_TrayMenu.Add("Suspend / resume`t Ctrl+Alt+F12", (*) => ToggleSuspend())
A_TrayMenu.Add("Emacs text nav`t Win+Alt+E", (*) => ToggleEmacs())
A_TrayMenu.Add("Invert scrolling`t Win+Alt+S", (*) => ToggleWheel())
A_TrayMenu.Add()
A_TrayMenu.Add("Edit script", (*) => Run('notepad.exe "' A_ScriptFullPath '"'))
A_TrayMenu.Add("Reload", (*) => Reload())
A_TrayMenu.Add("Exit", (*) => ExitApp())
A_IconTip := "MacKeys - macOS shortcuts"
