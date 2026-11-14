# Dynamic Island for the MacBook notch

A personal Dynamic Island for notched Macs (macOS 26+). Geometry and corner
radii follow [BoringNotch](https://github.com/TheBoredTeam/boring.notch) — the
open-source equivalent of NotchNook — with a music player and a Spotlight
handoff.

## Behaviour

- **Closed / idle** — exactly the camera cutout, so it is invisible.
- **Closed / playing** — the cutout plus a "chin" either side showing artwork
  and an animated waveform. Width is `notch + 4 + 2 × (height − 12) + 20`.
- **Hover** — expands into a 440 × 162 black panel with a 60 pt artwork,
  title, artist, transport controls and a draggable progress bar. Collapses
  50 ms after the pointer leaves.
- **Click** — hands off to Spotlight (`spotlight://`). The window hides itself
  and stays hidden until Spotlight is closed again.

Corners: `top 6 / bottom 14` closed, `top 19 / bottom 24` open, with a 1 pt
black strip across the top to hide the seam against the bezel.

## Run it

```sh
./build.sh
open DynamicIsland.app
```

Accessory app — no Dock icon. A menu bar item exposes expand / collapse / quit.

Launch expanded and pinned, for screenshots:

```sh
ISLAND_EXPANDED=1 ./DynamicIsland.app/Contents/MacOS/DynamicIsland
```

## Layout

| File | Role |
| --- | --- |
| `Sources/App.swift` | Entry point, status item, single-instance guard, offscreen preview renderer |
| `Sources/IslandController.swift` | Borderless `NSPanel` at status-bar level, hover tracking, Spotlight handoff |
| `Sources/IslandView.swift` | SwiftUI island: `NotchShape`, closed chin, open panel, scrub bar |
| `Sources/IslandModel.swift` | Presentation state, geometry, `PlayerService` |
| `Sources/MediaRemote.swift` | Private MediaRemote bridge (system-wide now-playing) |
| `Sources/SpotifyBridge.swift` | Direct Spotify control via AppleScript + artwork fetch |
| `Sources/SpotlightState.swift` | Heuristic for "Spotlight is open" |

## Notes

- `MediaRemote` is private API — fine for a personal build, not App Store-able.
- Spotify is driven through AppleScript, so macOS asks for Automation
  permission on first use. Deny it and Spotify falls back to MediaRemote,
  which is unreliable when another player owns the session.
- The notch itself is 185 × 32 pt of physical bezel with no pixels. Nothing can
  be drawn inside it; only the menu-bar band around it is usable.
- Spotlight position cannot be changed, so the island yields instead.
- `ISLAND_RENDER` / `ISLAND_RENDER_STATE` render a layout preview without
  opening a window.
