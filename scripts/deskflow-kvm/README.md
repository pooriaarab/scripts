# Script Notes: AutoHotkey v2 and KVM Keyboard Layout

## 1. AHK v2 Directive Syntax

Directives take an **unquoted** value. Quoting the value is a syntax error.

```ahk
; WRONG — syntax error, entire script fails to load
#MenuMaskKey "vkE8"

; CORRECT
#MenuMaskKey vkE8
```

A single directive syntax error prevents the whole script from loading. Every hotkey and mapping in the file silently stops working. The failure is silent unless you check.

Other directives follow the same rule (`#Requires`, `#SingleInstance`, etc.). Never quote the directive argument.

## 2. Always Parse-Check Before Deploy

Run the script with the `/ErrorStdOut` switch and check stderr. Do this in CI and before every manual deploy.

```powershell
# PowerShell — parse-check, fail on any output to stderr
$err = & "C:\Program Files\AutoHotkey\v2\AutoHotkey64.exe" /ErrorStdOut "script.ahk" 2>&1
if ($LASTEXITCODE -ne 0 -or $err) { throw "AHK syntax error:`n$err" }
```

```cmd
:: cmd.exe
"C:\Program Files\AutoHotkey\v2\AutoHotkey64.exe" /ErrorStdOut "script.ahk" 2> err.txt
if %errorlevel% neq 0 (type err.txt & exit /b 1)
```

If the script fails to load, no hotkey fires — including the chords from the Mac. A broken directive can look like a KVM or gesture bug.

## 3. Keyboard Layout Mismatch Scrambles Letters

A KVM forwards keystrokes, but letters are resolved through the active keyboard layout on each side.

- Digits (`0-9`), function keys (`F1-F12`), and modifiers (`ctrl/alt/shift/win`) are layout-stable. They travel correctly.
- Letters (`a-z`) are layout-dependent. A server on one layout and a client on another scrambles them.

Fix: keep the same layout active on both machines, or restrict chords to digits, F-keys, and modifiers.

Example stable chords:

```ahk
; Stable — digits with modifiers
^!+1::Run "action1"  ; ctrl+alt+shift+1
^!+2::Run "action2"  ; ctrl+alt+shift+2
```

```ahk
; Fragile — letters may scramble if layouts differ
^!+a::Run "actionA"  ; avoid across a KVM with mixed layouts
```

## 4. Win+Space Trap

On Windows, `Win+Space` is the input-language switcher. If the Mac forwards `Cmd+Space` and the KVM translates `Cmd` to `Win`, the client receives `Win+Space`.

That silently changes the client's keyboard layout. All subsequent letter keys are then scrambled, even if the initial chord used stable keys.

Symptoms: typing looks correct at first, then corrupts after a `Cmd+Space` / `Win+Space` event.

Mitigations:

- Do not forward `Cmd+Space` as a chord. Handle it locally on the Mac or map it to a different chord that does not include `Win+Space` on the client.
- If you must forward it, have the AHK script consume it and not pass `Win+Space` through to the OS:

```ahk
; Intercept and replace, do not let Win+Space reach the language switcher
#Space::Run "mySpotlightReplacement"
```

- After any layout-sensitive failure, check the active layout on the Windows client first (`Win+Space` indicator / `Get-WinUserLanguageList`).

## Checklist

- [ ] Directives use unquoted values.
- [ ] Script is parse-checked with `/ErrorStdOut` and stderr is empty.
- [ ] Chords use digits / F-keys, not letters.
- [ ] Server and client are on the same layout, or letters are avoided.
- [ ] No chord maps to `Win+Space` on the client.

## Parse-check an AutoHotkey v2 script before deploying it

A syntax error does not fail loudly in a useful way: the script simply does not
load, so **every mapping in it silently stops working** while the process still
appears in the task list. `#MenuMaskKey "vkE8"` (quoted) is a syntax error;
directives take an unquoted value. That one line took out an entire
macOS-keyboard-emulation script and the symptom looked like "Cmd+Delete broke".

Always parse-check to a staging filename first, and only overwrite the live
script when stderr is empty:

```powershell
$p = Start-Process -FilePath "C:\PROGRA~1\AutoHotkey\v2\AutoHotkey64.exe" `
  -ArgumentList "/ErrorStdOut","C:\path\staged.ahk" -PassThru -NoNewWindow `
  -RedirectStandardError "C:\path\err.txt"
Start-Sleep -Seconds 2
$e = Get-Content "C:\path\err.txt" -EA 0
if ($e) { "SYNTAX ERROR - not deploying"; $e } else { Copy-Item staged.ahk live.ahk -Force }
Stop-Process -Id $p.Id -Force -EA 0
```

## Modifier state does not survive a KVM the way you expect

A Synergy-style KVM sends **one** key-down when a modifier is pressed and does
not repeat it. So a Windows-side script that "borrows" that modifier - releases
Win to substitute Ctrl, say - leaves it logically up for the remainder of the
physical hold, and every subsequent click in that hold arrives with no modifier
at all. Measure the actual delivered modifier state before theorising:

```ahk
~*LButton::WriteLog("DOWN mods=" Mods())   ; note the * - without it the hotkey
~*LButton Up::WriteLog("UP   mods=" Mods()) ; never fires while a modifier is held
```

Note the `*` prefix. A plain `~LButton::` only fires when **no** modifiers are
held, so it silently records nothing during exactly the case being debugged.

### Confirmed resolution

The working shape is to **not touch the forwarded modifier at all**. Add the
modifier the target platform needs on top and leave the original held:

```ahk
CmdClick(btn) {
    Send "{Blind}{LCtrl down}"          ; do NOT release Win
    Click (btn = "RButton" ? "Right Down" : "Down")
    KeyWait btn                          ; preserves Cmd+drag
    Click (btn = "RButton" ? "Right Up" : "Up")
    Send "{Blind}{LCtrl up}"
}
```

Verified by effect rather than by log: Explorer's `SelectedItems().Count` went
to 8 across eight Cmd+clicks in a single hold, with the trace showing one
`LWin` key-down and one `LControl` per click. Explorer ignores Win for click
semantics, so leaving it held costs nothing.

## `#MenuMaskKey` is AutoHotkey v1 — in v2 it is a syntax error

Porting or copy-pasting an AHK snippet is the most likely way to take down a
whole script, because a v1 directive is still *syntactically plausible* to a
reader and fails only at load time:

```ahk
#MenuMaskKey vkE8       ; v1. In v2: "This line does not contain a recognized action"
A_MenuMaskKey := "vkE8" ; v2. Assignable built-in variable, not a directive.
```

Both forms were parse-checked to confirm this. The failure mode is what makes it
expensive: **a syntax error means the script does not load at all**, so every
mapping in it stops working at once while the process still appears in the task
list. The reported symptom was "Cmd+Delete stopped working" — nothing to do with
the line that was actually wrong.

A suggestion from any source, including an LLM, gets parse-checked before it is
deployed. This one arrived from a model, was deployed twice unchecked, and broke
the keyboard both times.

## A bare `{LWin up}` opens the Start menu and eats the next shortcut

Windows treats a Win key-up with no key pressed in between as a **Win tap**. So a
handler that releases a forwarded Win in order to substitute another modifier
pops the Start menu, which steals focus before the intended keystroke lands.

What makes this genuinely hard to find is that it is *action-order dependent*. A
different handler that happens to send a mask key first will mask the following
Win-up too, so the broken shortcut appears to work — until that unrelated handler
is changed. Symptoms:

- an unrelated shortcut "randomly" stops working
- it breaks only after some *other* feature is edited
- it works in isolation but not in a real sequence of actions

Mask every release, ideally globally: `A_MenuMaskKey := "vkE8"`.

**The diagnostic principle worth keeping:** when a change to feature A breaks
unrelated feature B, suspect shared global state — here the logical modifier
state, which every handler reads and writes — rather than coincidence. Two
handlers touching the same Win-up were coupled through the OS, not through code,
so nothing in either file hinted at the dependency.
