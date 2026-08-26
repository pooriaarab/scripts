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

## The trade-off you should decide on

These triggers bind **globally on the Mac**, so once BTT owns the three-finger
swipes you lose native Mission Control and Spaces switching *on the Mac itself*.
Three ways to handle that:

- **Rebind to four-finger swipes** in BTT (two clicks per trigger). macOS treats
  three- and four-finger swipes as the same action by default, so moving the
  relay to four fingers leaves the three-finger gestures native on the Mac. This
  is the cleanest option if you use Mission Control on both machines.
- **Use a Conditional Activation Group** in BTT so the triggers are only active
  under a condition you choose.
- **Accept it**, if the Mac is mostly a keyboard/trackpad host for the PC.

Also: macOS may swallow the gestures before BTT sees them. If a swipe does
nothing, turn off the corresponding gesture under
**System Settings → Trackpad → More Gestures** so BTT gets it instead.

## What this cannot do

Continuous gestures — pinch-to-zoom, smooth swipe tracking, anything that
animates as your fingers move. A relay sends one discrete keypress; there is no
gesture stream to interpolate. If you want those, the trackpad has to be paired
directly to Windows with
[mac-precision-touchpad](https://github.com/imbushuo/mac-precision-touchpad),
which is a different setup: the trackpad then drives Windows only.
