# MacKeys — macOS behaviour on this PC

Setup assumption: **Magic Keyboard + Magic Trackpad → Mac → Deskflow → this PC.**
Deskflow forwards the Mac's **Command** key as the **Windows** key, so Command is
remapped from Win. Ctrl and Alt are left alone, which keeps the local Dell
keyboard behaving like normal Windows *and* frees Ctrl for macOS's emacs text
navigation — exactly the division of labour a Mac has.

Script: `C:\Users\poori\MacKeys\MacKeys.ahk` (AutoHotkey v2, starts at login)

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
| `Cmd+click` | Add to a selection, or open a link in a background tab |
| `Cmd+drag` | Same, held — press and release are mapped separately |
| `Cmd+scroll` | Zoom |

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
