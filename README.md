# Dev Island

A personal dev toolbox that lives in the MacBook notch. Music, clipboard
history, terminal history and a file shelf, in a panel that drops out of the
cutout on hover.

Geometry and corner radii follow
[BoringNotch](https://github.com/TheBoredTeam/boring.notch) — the open-source
equivalent of NotchNook. No code is shared with it.

## Behaviour

- **Closed / idle** — exactly the camera cutout, so it is invisible.
- **Closed / playing** — the cutout plus a "chin" either side showing artwork
  and an animated waveform. Width is `notch + 4 + 2 × (height − 12) + 20`.
- **Hover** — expands into a panel. Collapses shortly after the pointer leaves.
- **Panel switch** — click the icons along the bottom, or `⌥⌘1`–`⌥⌘4` while
  open. `⌥⌘←` / `⌥⌘→` cycle.

Corners: `top 6 / bottom 14` closed, `top 19 / bottom 24` open, with a 1 pt
black strip across the top to hide the seam against the bezel.

## Panels

| Panel | Size | State |
| --- | --- | --- |
| Music | 440 × 162 | Works |
| Clipboard | 440 × 310 | Works |
| Terminal | 440 × 310 | Works |
| Shelf | 440 × 240 | Not wired up |

Every panel except Music carries a compact now-playing strip at the top, so
playback stays reachable without giving up the width a list needs.

### Clipboard

Captures the system pasteboard every 0.4 s (`changeCount` integer compare; the
string is only read when the count moves). Deduped by SHA-256, capped at 300,
stored `0600` in `~/Library/Application Support/Dev Island/clipboard.json`.

- Click a row to paste it into whatever app had focus.
- `⌥`-click to copy without pasting.
- Right-click for copy / remove / clear.

Skips items marked `TransientType` or `ConcealedType`, skips password managers
by bundle ID, and never stores anything matching the secret heuristic.

### Terminal

Reads `~/.zsh_history` and watches it with a `DispatchSource` file watcher — no
polling. Re-parses the whole file on change (~50 KB is under a millisecond), so
there is no cache and no second copy on disk.

- Ranked by use count, then recency (the file has no timestamps).
- Click to paste; `⌥`-click to copy only. A trailing newline is stripped, so a
  pasted command sits at the prompt instead of executing.
- Continuations (`\`) are joined with a space, so a pasted command never contains
  a newline that would run it line by line.
- Commands matching the secret heuristic are masked in the panel; clicking still
  pastes the real text.

Requires `setopt INC_APPEND_HISTORY` in `~/.zshrc`, otherwise zsh only writes
history when a shell exits and the panel shows stale commands. It says so in a
notice strip if the option is missing. Trivia like bare `cd` and `ls` is hidden
by an editable deny-list: status item → **Edit Ignore Rules…**.

## Run it

```sh
./build.sh
open DevIsland.app
```

Accessory app — no Dock icon. A menu bar item exposes expand / collapse /
default panel / edit ignore rules / quit.

Launch expanded and pinned, for screenshots:

```sh
ISLAND_EXPANDED=1 ./DevIsland.app/Contents/MacOS/DevIsland
```

Pick the panel and whether a track is playing:

```sh
ISLAND_EXPANDED=1 ISLAND_PANEL=clipboard \
  ./DevIsland.app/Contents/MacOS/DevIsland
```

## Permissions

- **Automation (Spotify)** — required to read and control playback. Deny it and
  playback control falls back to MediaRemote, which is unreliable when another
  player owns the session.
- **Accessibility** — required only for auto-paste (synthesising `⌘V`). Without
  it, clicking a clipboard row copies instead of pasting, and the panel says so.

Grants are keyed to the code-signing identity, so `build.sh` signs with a stable
certificate rather than ad-hoc. See `PLAN.md` §11.

## Layout

| File | Role |
| --- | --- |
| `Sources/App.swift` | Entry point, status item, single-instance guard, preview renderer |
| `Sources/IslandController.swift` | Borderless `NSPanel`, hover tracking, window sizing, hotkeys |
| `Sources/IslandView.swift` | SwiftUI island: `NotchShape`, chin, panels, nav |
| `Sources/IslandModel.swift` | Presentation state, geometry, `PlayerService` |
| `Sources/Panels.swift` | `PanelID`, provider lifecycle, `PanelHost` |
| `Sources/ClipboardStore.swift` | Entry model, frecency, JSON persistence |
| `Sources/ClipboardService.swift` | Pasteboard watcher, privacy rules, paste-back |
| `Sources/AccessibilityPaster.swift` | Synthetic `⌘V` behind a permission check |
| `Sources/IgnoreRules.swift` | Trivia deny-list for the terminal panel |
| `Sources/TerminalHistory.swift` | `~/.zsh_history` parser and ranking |
| `Sources/TerminalService.swift` | File watcher, trivia filter, flush-option notice |
| `Sources/HotKeys.swift` | Carbon global shortcuts for panel switching |
| `Sources/MediaRemote.swift` | Private MediaRemote bridge (system-wide now-playing) |
| `Sources/SpotifyBridge.swift` | Direct Spotify control via AppleScript + artwork |
| `Sources/SpotlightState.swift` | Heuristic for "Spotlight is open" |
| `Sources/FullscreenSupport.swift` | SkyLight attach so the island survives fullscreen |

## Notes

- `MediaRemote` and `SkyLight` are private API — fine for a personal build, not
  App Store-able. A sandboxed build could not use them at all.
- Spotlight detection is a heuristic on `com.apple.campo`, not an API. The island
  hides itself while Spotlight is open; it does not open Spotlight.
- The notch itself is 185 × 32 pt of physical bezel with no pixels. Nothing can
  be drawn inside it; only the menu-bar band around it is usable.
- `ISLAND_RENDER` / `ISLAND_RENDER_STATE` / `ISLAND_RENDER_PANEL` render a layout
  preview without opening a window. `ImageRenderer` cannot rasterise
  `ScrollView`, so previews show empty lists.
- `PLAN.md` holds the multi-panel design and the open issues; `MIGRATION.md` is
  the completed rename checklist.
