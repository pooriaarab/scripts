# Trackpad gestures — the Mac half

## Why this is needed at all

Deskflow forwards mouse motion, buttons, scroll and clipboard. It does **not**
forward multi-touch. Gestures are interpreted on the machine the trackpad is
physically attached to, so a three-finger swipe on the Magic Trackpad fires
Mission Control *on the Mac* and nothing reaches Windows.

The workaround is a relay: BetterTouchTool on the Mac turns each gesture into an
otherwise-unused keyboard chord, Deskflow forwards that chord like any ordinary
key, and `MacKeys.ahk` turns it back into the Windows equivalent.

```
Magic Trackpad → BetterTouchTool → ⌃⌥⇧<n> → Deskflow → MacKeys.ahk → Windows
```

## What gets relayed

The Windows half is already installed and running. These chords are live:

| Mac gesture | Chord | Windows action |
|---|---|---|
| 3-finger swipe up | `⌃⌥⇧1` | Mission Control → Task View |
| 3-finger swipe down | `⌃⌥⇧2` | App Exposé → cycle windows of current app |
| 3-finger swipe left | `⌃⌥⇧3` | Next Space |
| 3-finger swipe right | `⌃⌥⇧4` | Previous Space |
| 4-finger pinch in | `⌃⌥⇧5` | Launchpad → PowerToys Run |
| 4-finger pinch out | `⌃⌥⇧6` | Show Desktop |

## Setting up the Mac half

Requires [BetterTouchTool](https://folivora.ai) (paid, ~$10 licence).

1. Copy the entire contents of `MacKeys-Gestures.json` to the clipboard.
2. In BetterTouchTool, select **Trackpad** as the trigger type and **All Apps**
   in the app list.
3. Right-click in the gesture list → **Paste**. The six triggers appear.

The file is an array of trigger definitions, which is the unit BTT's
copy/paste uses. `BTTPredefinedActionType: 264` is "send keyboard shortcut",
and BTT accepts the human-readable `ctrl+option+shift+1` form on import, so
there are no raw key codes to get wrong.

## The binding constraint: the Mac must not change

The requirement is that **every gesture keeps doing exactly what it does today
on the Mac**, and additionally works on Windows. A gesture manager that takes
over a native macOS gesture and reimplements it does not meet that bar, even
though it is the simplest thing to build.

So the Mac-side trigger has to either:

1. **Pass through** — fire the chord while letting the native gesture still
   happen (a per-trigger option in BetterTouchTool; explicit in a Hammerspoon
   event tap, which returns the event unmodified while acting on it), or
2. **Re-trigger** — fire the chord *and* explicitly invoke the native macOS
   action, so the observable behaviour is identical.

Pass-through is preferred. Whichever is used, "the Mac is unchanged" is the
acceptance criterion, verified rather than assumed.

`mac-side-prompt.md` in this folder is a self-contained brief for an agent
running on the Mac, written to that constraint. The Mac is the Deskflow server
and stays in control; nothing drives it from the Windows side.

## The unknown that decides the design

**Does Deskflow forward *synthetic* keystrokes?** Gesture tools emit keystrokes
as synthetic `CGEvent`s, and Deskflow captures real hardware input — it may not
pick up events posted programmatically by another app. If it does not, the whole
keystroke-relay approach is dead and the transport has to become a direct
network call from the Mac to a listener on the Windows box, bypassing Deskflow.

Test it before building: put the Deskflow cursor on the Windows screen, post a
synthetic keystroke from AppleScript, and see which machine receives it.

Separately, macOS may swallow a gesture before the tool sees it. If a swipe does
nothing, the corresponding entry under **System Settings → Trackpad → More
Gestures** is the first place to look.

## What this cannot do

Continuous gestures — pinch-to-zoom, smooth swipe tracking, anything that
animates as your fingers move. A relay sends one discrete keypress; there is no
gesture stream to interpolate. If you want those, the trackpad has to be paired
directly to Windows with
[mac-precision-touchpad](https://github.com/imbushuo/mac-precision-touchpad),
which is a different setup: the trackpad then drives Windows only.
