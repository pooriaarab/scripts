# MacKeys — macOS behaviour on this PC

Setup assumption: **Magic Keyboard + Magic Trackpad → Mac → Deskflow → this PC.**
Deskflow forwards the Mac's **Command** key as the **Windows** key, so Command is
remapped from Win. Ctrl and Alt are left alone, which keeps the local Dell
keyboard behaving like normal Windows *and* frees Ctrl for macOS's emacs text
navigation — exactly the division of labour a Mac has.

## Install

```powershell
.\install.ps1
```

Idempotent. Installs AutoHotkey v2 and QuickLook via winget if missing, copies
`MacKeys.ahk` to `%USERPROFILE%\MacKeys`, registers both at login, and starts
them. Add `-FreeWinL` to also fix `Cmd+L` (see Known limits).

If Command turns out to arrive as **Alt** rather than **Win** — a directly
paired Apple keyboard with Boot Camp drivers does this — swap the `#` hotkey
prefixes in `MacKeys.ahk` for `!`.

## Escape hatches

| Shortcut | Effect |
|---|---|
| `Ctrl+Alt+F12` | Suspend / resume every remap (panic switch) |
| `Win+Alt+E` | Emacs text navigation on/off |
| `Win+Alt+S` | Invert scroll direction on/off |

The tray icon has the same options plus **Edit** and **Reload**.

## Editing / clipboard

| Mac | Does |
|---|---|
| `Cmd+C / X / V / A / Z / Shift+Z` | Copy, cut, paste, select all, undo, redo |
| `Cmd+S / P / F / G / N / O / T / W / R` | Save, print, find, find-next, new, open, new tab, close, reload |
| `Cmd+1`…`9`, `Cmd+0`, `Cmd+-`, `Cmd+=` | Tab switching and zoom |

In a terminal, `Cmd+C` / `Cmd+V` become `Ctrl+Shift+C` / `Ctrl+Shift+V` so that
`Ctrl+C` stays available as interrupt — the same trick Terminal.app plays.

## Text navigation

| Mac | Does |
|---|---|
| `Cmd+←` / `Cmd+→` | Start / end of line |
| `Cmd+↑` / `Cmd+↓` | Start / end of document (parent folder / open, in Explorer) |
| `Option+←` / `Option+→` | Word left / right |
| `Option+↑` / `Option+↓` | Paragraph up / down |
| `Cmd+Backspace` | Delete to start of line |
| `Option+Backspace` | Delete word left |
| `Ctrl+A / E` | Start / end of line |
| `Ctrl+B / F / P / N` | Left / right / up / down |
| `Ctrl+D / H` | Forward delete / backspace |
| `Ctrl+K` | Kill to end of line |

The `Ctrl+…` set is skipped inside terminals, where those keys mean other things.

## Windows, apps, system

| Mac | Does |
|---|---|
| `Cmd+Tab` / `Cmd+Shift+Tab` | App switcher, held open while Cmd is down |
| `` Cmd+` `` | Cycle windows of the current app |
| `Cmd+Q` | Quit app |
| `Cmd+M` / `Cmd+H` | Minimise / hide |
| `Cmd+Ctrl+F` | Fullscreen (maximise) |
| `Cmd+Option+Esc` | Force Quit → Task Manager |
| `Cmd+Ctrl+Q` | Lock screen |
| `Cmd+Space` | Spotlight → PowerToys Run |
| `Cmd+[` / `Cmd+]` | Back / forward |
| `Ctrl+↑` | Mission Control → Task View |
| `Ctrl+←` / `Ctrl+→` | Previous / next Space (virtual desktop) |
| `Cmd+Shift+3 / 4 / 5` | Screenshot: full / region / recording |
| `Space` in Explorer | Quick Look preview (QuickLook) |

## Known limits

- **`Cmd+L`** currently locks the screen instead of focusing the address bar.
  Windows reserves `Win+L` at a level no hook can intercept. Fixing it needs
  `DisableLockWorkstation=1` under
  `HKCU\Software\Microsoft\Windows\CurrentVersion\Policies\System`; `Cmd+Ctrl+Q`
  already covers locking.
- **Scroll direction** depends on what the Mac sends. Deskflow forwards the
  already-inverted delta, so it is probably right — `Win+Alt+S` flips it if not.
- No global menu bar, and no true app-level `Cmd+Q` quit semantics. Windows has
  no equivalent concept.

## Trackpad gestures

Deskflow forwards no multi-touch, so gestures need a relay: BetterTouchTool on
the Mac converts each gesture to a `⌃⌥⇧<n>` chord that Deskflow forwards and
`MacKeys.ahk` translates back. See [GESTURES.md](GESTURES.md) for the six
mapped gestures, the paste-ready `MacKeys-Gestures.json`, and the trade-off
that binding them globally costs you the native Mac gestures.
