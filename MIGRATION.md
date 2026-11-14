# Release migration — Dynamic Island → Dev Island

**Status: applied.** Bundle ID `dev.island`, executable `DevIsland`, display name
`Dev Island`, `NSAppleEventsUsageDescription` added, `.gitignore` and README
updated, and `build.sh` now signs with a stable identity instead of ad-hoc.

Verified after the change:

- `codesign -d -r-` is byte-identical across two consecutive rebuilds, so TCC
  grants survive a rebuild (the whole point of the stage).
- Bundle ID is `dev.island`; the `NSAppleEventsUsageDescription` is present in
  the built app, so a first Spotify call prompts instead of terminating.
- One process only when launched twice (the old `count > 1` guard let a
  duplicate through and was rewritten to compare against other processes).
- Panel, clipboard chips and rows all render as before.

**Signing identity:** `Dev Island Local Signing` now exists (valid to 2036) and
is trusted for code signing in the user trust domain, so `build.sh` signs with
it. `ISLAND_SIGN_IDENTITY` overrides, and a single `Apple Development` identity
is the fallback. Creation recipe and the three gotchas are in `PLAN.md` §11.

The original ordering rationale, kept for context: Accessibility grants are keyed on both bundle ID *and* code-signing requirement, so renaming after Phase 2 would discard the grant. Change the bundle ID **before** signing, then re-verify both grants afterwards.

Decisions already made, do not re-litigate:

- **Name:** Dev Island. Avoids Apple's "Dynamic Island" trademark.
- **Bundle identifier:** `dev.island`. Deliberately keeps a personal name out of
  the namespace.
- **Licence:** MIT. The repo is free of BoringNotch code — only geometry
  constants were taken, which are not copyrightable — so there is nothing
  forcing GPL.
- **Distribution:** source only. No Apple Developer Program, no notarization, no
  App Store. People clone and run `./build.sh`. Locally built binaries carry no
  quarantine attribute, so Gatekeeper never gets involved.

---

## 1. Identity

| File | Change |
| --- | --- |
| `Info.plist:10` | `com.haras.dynamicisland` → `dev.island` |
| `Info.plist:14` | `Dynamic Island` → `Dev Island` |
| `Info.plist:30` | `Personal build` → real copyright string, e.g. `MIT licensed` |
| `Sources/App.swift:14` | Single-instance guard compares the old bundle ID string; must match the new one or you get two panels |
| `build.sh:7-8` | `APP="DynamicIsland.app"`, `BIN="DynamicIsland"` → `DevIsland.app`, `DevIsland` |
| folder | `~/Projects/DynamicIsland` → `~/Projects/DevIsland` (already done — see below) |
| `.gitignore` | `DynamicIsland.app/` → `DevIsland.app/` |
| `README.md:1,3` | Title `# Dynamic Island for the MacBook notch` → `# Dev Island`; prose `A personal Dynamic Island for notched Macs` → `A personal dev toolbox for notched Macs` |
| `README.md:26,34` | Launch commands `open DynamicIsland.app` and `./DynamicIsland.app/Contents/MacOS/DynamicIsland` → `DevIsland.app` / `DevIsland` |
| `Sources/MediaRemote.swift:68` | Log prefix `DynamicIsland:` → `DevIsland:` (cosmetic, but it is the string you will grep for when MediaRemote misbehaves) |

**Order matters for the bundle ID.** Change it while the app is *not* running,
then rebuild. macOS keys Automation grants on the bundle identifier, so the new
ID starts with no TCC record:

- System Settings → Privacy & Security → Automation will keep a stale
  `DynamicIsland` entry until it is removed by hand.
- The first Spotify command after the change re-prompts for permission. Accept
  it, or playback control silently fails and falls back to MediaRemote.

Also reset the app's own cached state if any is added later — currently there is
none, so nothing to clear.

## 2. The actual bug: missing usage description

`Info.plist` has no `NSAppleEventsUsageDescription`. Without it macOS can
**terminate** the app the moment it sends the first AppleScript event to Spotify,
rather than showing a permission prompt. This is not a polish item; it makes
Spotify control unreliable on a clean install.

```xml
<key>NSAppleEventsUsageDescription</key>
<string>Dev Island controls Spotify playback so the notch can show and change the current track.</string>
```

## 3. Build portability

`build.sh:18` hardcodes `-target arm64-apple-macos26.0`. Drop the flag and let
`swiftc` use the host triple. It only matters for Intel Macs, but it turns a
confusing "unsupported architecture" error into either a working build or an
honest one.

Also consider `-target`-free but keep `-O`. Debug builds are noticeably janky for
the marquee's 30 fps `TimelineView`.

## 4. Preview fixture

`Sources/App.swift:48` hardcodes a real Eminem track for the headless preview
(`ISLAND_RENDER`). It is a test fixture, not user-facing, but it reads as an
accident. Replace with something neutral — title `"Preview Track"`, artist
`"Artist"` — so nobody wonders why a song is in the source.

The `artwork: nil` in that block is correct and should stay: `ImageRenderer`
cannot fetch, so the preview intentionally shows the no-artwork state.

## 5. Licence

Add `LICENSE` with the MIT text and the year. No dependency on any GPL project,
so no attribution obligations beyond the MIT notice itself.

## 6. No-notch guard

`Sources/IslandController.swift:265-279` — `notchRect` returns `nil` on a Mac
without a cutout, and every caller silently no-ops. The result is an app that
runs, shows a menu bar item, and does nothing visible. On a display without a
notch (external monitor as main, older MacBook, Intel) the app should say so and
exit rather than sit there inert.

Same applies when the main display changes to one without a notch: currently the
panel keeps whatever geometry it last had. `observeScreens` should re-evaluate.

## 7. README

Rewrite for someone who has never seen the app. Required sections:

- What it is, and the one screenshot / GIF at the top
- Requirements: Apple Silicon MacBook with a notch, macOS 26+
- `./build.sh && open DevIsland.app`
- Permissions: why it asks for Automation (Spotify), what breaks if denied
- Known limitations, stated plainly:
  - MediaRemote is private API and unreliable when a non-Spotify player owns the
    session
  - Spotlight detection is a heuristic on `com.apple.campo`, not an API
  - `SkyLight` fullscreen attachment is private API and may break on any release
  - nothing can be drawn inside the cutout itself; only the menu-bar band either
    side is addressable
- `ISLAND_RENDER` / `ISLAND_RENDER_STATE` documented as a contributor tool

---

## Verification after migrating

1. `./build.sh` from the new folder, clean build, no warnings that were not
   already there.
2. `open DevIsland.app` — one panel only, no duplicate process.
3. `pgrep -fl DevIsland.app` shows exactly one PID.
4. Hover the notch: expand, music, scrub, collapse at 50 ms.
5. Play/pause from the island and confirm Spotify responds (proves the
   Automation grant survived the bundle ID change).
6. Fullscreen a video, hover the notch, confirm the island is still there.
7. Open Spotlight, confirm the island hides and stays hidden until Spotlight
   closes.
8. `git status` clean, `.gitignore` correctly excluding `DevIsland.app/`.
9. `git log` intact — the rename must not create a new history.

## Out of scope

Notarization, Developer ID, Sparkle updates, App Store, payment. Source-only
distribution means none of it is needed. If that ever changes, note that a
sandboxed build cannot use MediaRemote or SkyLight, so the App Store version
would be a different, smaller app.
