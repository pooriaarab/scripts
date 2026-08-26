# Task: make my trackpad gestures also work on my Windows PC over Deskflow — without changing how this Mac's trackpad behaves in any way

## Context

- This Mac (`L0QX6J0VJH`) is the **Deskflow server**. My Magic Keyboard and Magic
  Trackpad are attached here.
- A Windows 11 PC (`DESKTOP-EPD31FF`, Tailscale-reachable, also on the LAN) is
  the **Deskflow client**. It is driven entirely from this Mac.
- Deskflow forwards mouse motion, buttons, scroll and clipboard. It does **not**
  forward multi-touch. So gestures are recognised here on the Mac and nothing
  reaches Windows. That is the gap to close.

On the Windows side this is already installed, running, and starts at login:

- AutoHotkey v2 with a script (`%USERPROFILE%\MacKeys\MacKeys.ahk`) that gives
  Windows macOS-style keyboard behaviour.
- That script **already listens for six "gesture chords"** and converts each one
  into the Windows equivalent. The Windows half is done. Only the Mac half —
  something that emits these chords when I make a gesture — is missing.

| Chord to send | Windows action it triggers | Intended gesture |
|---|---|---|
| `control+option+shift+1` | Task View | 3-finger swipe up |
| `control+option+shift+2` | Cycle windows of current app | 3-finger swipe down |
| `control+option+shift+3` | Next virtual desktop | 3-finger swipe left |
| `control+option+shift+4` | Previous virtual desktop | 3-finger swipe right |
| `control+option+shift+5` | PowerToys Run (Spotlight) | 4-finger pinch in |
| `control+option+shift+6` | Show Desktop | 4-finger pinch out |

## The hard constraint — this is the part that matters most

**Nothing about how this Mac's trackpad behaves may change.** When I am working
on the Mac, every gesture must do exactly what it does today: three-finger swipe
up still opens Mission Control, left/right still switch Spaces, and so on. I do
not want a gesture manager to take those gestures over and reimplement them.

Adding a gesture tool is fine. Silently replacing my native gestures is not.

Please treat "the Mac is unchanged" as the acceptance criterion, and tell me
honestly if the approach you find cannot meet it.

## The critical unknown — please test this before building anything

**Does Deskflow forward *synthetic* keystrokes to the client?**

Gesture tools (BetterTouchTool, Hammerspoon, Karabiner) emit keystrokes as
synthetic `CGEvent`s. Deskflow captures real hardware keyboard input — it may or
may not pick up events posted programmatically by another app. If it does not,
this entire keystroke-relay approach is dead and we need a different transport.

A cheap way to check: move the Deskflow cursor onto the Windows screen, then
have any script post a synthetic keystroke (e.g. AppleScript
`tell application "System Events" to keystroke "a"`) and see whether the
character lands on Windows or on the Mac. Please actually run this test and
report the result — it decides the design.

If synthetic keystrokes are **not** forwarded, say so and stop. The fallback is
a network transport (the Mac sends an HTTP request straight to a small listener
on the Windows box, bypassing Deskflow entirely), and I will have that built on
the Windows side instead.

## Design, assuming synthetic keystrokes do get forwarded

The problem: a gesture tool that binds "3-finger swipe up" normally *swallows*
the native gesture, which would break the constraint above.

Two ways to avoid that — please evaluate both and pick the one that actually
holds up on current macOS:

1. **Pass-through.** Bind the gesture, send the chord, and let the native gesture
   still fire (BetterTouchTool has per-trigger options along these lines;
   Hammerspoon's event tap can return the event unmodified while acting on it).
   Preferred, if it genuinely works.

2. **Re-trigger.** Bind the gesture, send the chord, and *also* explicitly invoke
   the native macOS action (Mission Control, Spaces switch, etc.) so the Mac
   behaves identically. Acceptable, but verify there is no visible lag or double-fire.

Note one thing worth checking: when the Deskflow cursor is on the Windows screen,
does this Mac *still* react to my trackpad gestures today (does Mission Control
open here while I am working on Windows)? If it does, that is the current
behaviour and it must be preserved — do not "fix" it as part of this task. Just
tell me what you observe.

## Tooling notes

- BetterTouchTool is paid (~$10). Check whether it is already installed.
- **Hammerspoon** is free, scriptable, and can both observe gestures and post
  keystrokes — it may be the better fit here precisely because pass-through
  behaviour is explicit in code rather than a checkbox. Your call.
- Whatever you use must start at login.

## What to report back

Please answer these directly, and keep it short enough to paste back into
another agent session:

1. **Synthetic keystroke test result** — did a scripted keystroke reach Windows
   through Deskflow, yes or no?
2. **What you installed/configured**, and whether it starts at login.
3. **Which of the six gestures you wired up**, and any you could not.
4. **Confirmation that native Mac gesture behaviour is unchanged** — state how
   you verified it, not just that you believe it.
5. **Current Mac-side behaviour while the cursor is on Windows** — do gestures
   still fire here?
6. Anything you hit that the Windows side needs to change.
