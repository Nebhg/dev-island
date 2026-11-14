# Dev Island — multi-panel plan

Status: **Phases 0–3 implemented; Phases 4–6 proposed.** Phase 0 is *partial* —
the YouTube/Chrome test and the paste-notice check were never run. §1 states facts
verified against the source; rows marked *(Phase 1/2/3)* describe the code as it
now stands, not the original commit. §11 records the signing setup that is in
place.

| Phase | State |
| --- | --- |
| 0 — YouTube/Chrome, paste notice | **partial**, untested |
| 1 — panel host | done |
| 1.5 — rename + self-signed signing | done |
| 2 — clipboard panel + auto-paste | done, verified by use |
| 3 — terminal history panel | done |
| 4 — file shelf | not built |
| 5 — music visual upgrade | not built |
| 6 — browser-media fallback | only if Phase 0 demands it |

Goal: turn a single-purpose music notch into a panel host with a clipboard
history panel, a terminal-history panel, and a file shelf, plus a visual
upgrade to the music panel and browser-media support.

---

## 1. Existing code — verified constraints

These matter because they invalidate some obvious approaches.

| Fact | Source | Consequence |
| --- | --- | --- |
| `islandSize` returns `activePanel.preferredSize` while open **(Phase 1)** | `Sources/IslandModel.swift:53-61` | The resize invariant must still hold in one turn: **snap `NSPanel` frame → update `activePanel` / `islandSize` → recompute `islandRect` / `inHotZone`**, otherwise `handleMouse` sees a mismatch and collapses mid-click. |
| No SPM, no dependencies — plain `swiftc` | `build.sh` | No GRDB/Realm. Persistence must be `Codable` JSON, capped and debounced. |
| `~/.zsh_history`: ~1,300 lines and growing, **no timestamps**, `\` continuations, non-UTF-8 bytes | measured | Recency must come from file position, not time. The parser must join continuations and decode lossily. `INC_APPEND_HISTORY` is now set in `~/.zshrc`, so the file is written per command rather than on shell exit. `EXTENDED_HISTORY` is still off. |
| `panel.ignoresMouseEvents` centralised in `refreshMousePolicy()` **(Phase 1)** | `Sources/IslandController.swift:244-252` | Policy is `expanded ? false : isPlaying`. During a drag session `mouseMoved` does not fire, so a file dragged at a click-through window never lands: the closed idle window (`notch + 4`, physical cutout only) must stay permanently interactive as `NSDraggingDestination`, while the `249 pt` playing chin stays click-through. Phase 4 depends on this. |
| Polls only run while expanded **(Phase 1)** | `Sources/IslandController.swift:105-119`, `Sources/IslandModel.swift:137-149` | Both the Spotlight watch and `PlayerService.startPolling()` / `stopPolling()` are driven off `$expanded`. Verified: zero `osascript` spawns while closed. This is the precedent the `PanelProvider` lifecycle follows. |
| Panel level `.mainMenu + 3`, SkyLight space attach | `Sources/FullscreenSupport.swift` | New panels inherit this; no extra work. |
| Window frame tracks the island **(Phase 2)** | `Sources/IslandController.swift` (`updateGeometry`, `syncWindow`) | The window is resized every animation frame from an `Animatable` size probe, so it never exceeds the shape. Two things are load-bearing: the no-op guard (setting the frame re-lays out the hosting view, which re-runs the probe, which calls straight back — unguarded, it redraws at display rate forever), and critically-damped springs (any overshoot moves the whole window, not just the shape). |
| Click-to-Spotlight (`openSpotlight()`) | `Sources/IslandView.swift` / `IslandModel.swift` | Removed in Phase 1 (`⌘Space` is the precedent); Spotlight avoidance / suppression while `SpotlightState.isOpen` is retained. |
| 50 ms collapse on pointer exit | `Sources/IslandController.swift:242-250` (`scheduleCollapse`) | Right-click `NSMenu`s and drag-outs move the pointer outside `islandRect`. Collapse must be guarded while a menu or drag session is active. |
| `IslandPanel` overrides `canBecomeKey = true` **(Phase 2)** | `Sources/IslandController.swift:5-8` | `becomesKeyOnlyIfNeeded` is now `true`, so a click cannot take key status and swallow the synthetic `⌘V`. Auto-paste verified working by clicking a row and pasting into an editor. |

Environment: Apple Silicon, macOS 26 (27.3 beta), screen 1512 × 982 @2x, notch
185 × 32 pt. Shell is zsh. Browsers installed: Chrome, Edge, Safari. Media app:
Spotify only.

---

## 2. Architecture

### Panel host

```
IslandModel
├── activePanel: PanelID        // .music .clipboard .terminal .shelf
├── defaultPanel: PanelID       // persisted, opened on first hover
└── registry: [PanelID: PanelProvider]

protocol PanelProvider {
    var id: PanelID { get }
    func start()   // panel visible AND island open
    func stop()    // otherwise
}
```

**Single lifecycle rule:** a provider's timers exist only while its panel is on
screen. Driven off `model.$expanded` combined with `activePanel`. This is the
same discipline that removed the always-on Spotlight poll, and it is why the
shell must land before the features — otherwise each feature grows its own
timer and the app idles at 5–10% CPU.

### Panel sizes

SwiftUI animates `NotchShape` inside a non-animated `NSPanel`. The window follows the shape **frame by frame** rather than being snapped to the target: an `Animatable` size probe reports each interpolated size and the controller resizes the window to match, so the window is never larger than the island. Both springs are critically damped (`dampingFraction: 1`), because any overshoot moves the whole window rather than being clipped inside it. See risk 7 for the outstanding see-through report.

The `32 pt` physical notch, `28 pt` now-playing strip, `28 pt` bottom nav, and gaps/padding consume `~116 pt` of vertical chrome on non-music panels:

| Panel | Size (pt) | Rationale |
| --- | --- | --- |
| Music | 440 × 162 | unchanged from today (scrub bar beside 92 pt artwork) |
| Clipboard | 440 × 310 | ~194 pt content area for frequent strip + 6 rows |
| Terminal | 440 × 310 | same shape, same reason |
| Shelf | 440 × 240 | ~124 pt content area for 4 file rows |

### Navigation

Row of 4 SF Symbol buttons along the bottom, 20 pt: active at full white,
inactive at 0.3 opacity. Click switches panel and resizes the window.

Deliberately **no scroll-to-switch**: a clipboard list needs wheel scrolling,
and a global scroll handler fights it.

### Default panel

Submenu on the existing status item (`Sources/App.swift:81`), persisted in
`UserDefaults`. No settings window.

### Music while another panel is open

**28 pt now-playing strip pinned at the top of every non-music panel**: 20 pt
artwork, marquee title, play/pause button.

This is the answer to "I want to use the new panels while music plays". Music
stops being a panel you must visit and becomes chrome plus one full panel. The
alternative — keeping a music sidebar in every panel — costs ~110 pt of width
in a 440 pt panel and makes the lists unusable.

### Persistence

One JSON file per store in `~/Library/Application Support/Dev Island/`, written
debounced (~2 s) and atomically (`0600` permissions on `clipboard.json`):

- `clipboard.json` — capped at 300 entries
- `shelf.json` — file references/bookmarks
- `ignore-rules.txt` — plain lines, regex per line
- `defaults` in `UserDefaults` (default panel, per-panel prefs)

No `terminal.json`: the history is re-parsed from `~/.zsh_history` on change
(~50 KB, well under a millisecond), so there is no cache to keep in sync and no
second copy of commands on disk.

---

## 3. Clipboard panel

### Capture

- Poll `NSPasteboard.general.changeCount` every 0.4 s. Reading the *count* does
  not trigger macOS's paste notice; reading the *string* can on macOS 15+.
- Runs even when the island is closed — an integer compare, effectively free.
  Without it there is no history.

### Privacy rules (non-negotiable)

- Skip items carrying `org.nspasteboard.TransientType` or
  `org.nspasteboard.ConcealedType` — drop before persistence, never written to `clipboard.json`.
- Skip when the frontmost app is in a blocklist — seeded with password managers
  (1Password, Bitwarden, Keychain Access) if installed.
- Never persist anything matched by the secret heuristic below; write `clipboard.json` with `0600` file permissions.

### Entry model

```swift
struct ClipEntry: Codable, Identifiable {
    let hash: String        // SHA256 of normalised text
    var text: String
    var kind: ClipKind      // .text .command .url .path .code
    var firstSeen: Date
    var lastUsed: Date
    var uses: Int
}
```

Dedupe by hash; re-copying moves an entry to the top and increments `uses`.
Cap 300, evict oldest-by-`lastUsed`.

**Write-back loop guard:** `writeText` syncs `lastChangeCount` to the count its
own write caused, so the poll's `changeCount` equality check skips it. Do **not**
add a separate "ignore next change" flag on top: the equality check returns first,
so the flag is never consumed and silently eats the user's next real copy. That
exact bug shipped once and made repeated copies stop appearing.

### Frequent strip

Frecency: `uses × 0.5 ^ (daysSinceLastUse / 14)` — top 3 rendered as chips, with a
`FREQUENT` label above and a kind icon per chip. Ties break by recency, otherwise
equal-scoring chips reorder arbitrarily between renders.

The terminal panel does **not** share this ranking: the history file carries no
timestamps, so a decay curve would be invented rather than measured. It ranks by
use count, then file position (§4).

### Row rendering

- Kind icon at the leading edge, so the list scans by shape
- Fixed 26 pt rows, always one line, middle truncation so paths stay readable
- Whitespace runs collapsed, so a multi-line paste does not become a ragged row
- Relative age right-aligned (`now`, `4m`, `3h`, `2d`)

### Click path (auto-paste)

```
click row
  → write text to NSPasteboard.general
  → sync lastChangeCount so the write-back loop guard skips our own write
  → collapse island
  → after ~80 ms, post ⌘V
```

- No target is captured: the ⌘V goes to whatever has focus. That works because
  the panel is non-activating, so clicking it never moves focus away from the
  editor.
- ⌥-click = copy only, no keystroke. Plain click = copy + paste.

### Timing

There is **no collapse-completion callback** — `collapse()` sets `expanded =
false` and the `$expanded` sink updates state synchronously; SwiftUI's animation
is cosmetic and invisible to the controller (and `ignoresMouseEvents` flips
immediately even while the window waits ~0.4 s to shrink). Post ⌘V on the next
runloop turn (`DispatchQueue.main.async`), treating ~80 ms as empirical: measure
whether the target app still holds the old pasteboard contents, and lengthen only
if it does.

### Focus

`IslandPanel` overrides `canBecomeKey` to `true`, so a click could take key
status without activating the app and swallow the synthetic ⌘V. Fixed by setting
`becomesKeyOnlyIfNeeded = true`: the panel takes key status only when a control
needs keyboard input, and every control here is a button, so in practice it never
does.

The belt-and-braces path (capture the frontmost app, re-activate before posting)
was **not** built — auto-paste was verified working without it, and keeping an
untested fallback would have been dead code pretending to be insurance.

### Permission handling

- `CGPreflightPostEventAccess()` is the single source of truth for "can this
  process post a synthetic key event". It checks without prompting.
- `AXIsProcessTrusted()` alone is not sufficient and is not the gate for event
  posting; if a prompt is wanted, use
  `AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt: true])`.
- Never block a click on a prompt. First run shows the notice strip; the click
  path re-checks every time.
- If the post is refused, fall back to copy-only and set `panelNotice` to
  `"Grant Accessibility to paste directly."`.

---

## 4. Terminal history panel

### Ingest

- **Prerequisite:** `setopt INC_APPEND_HISTORY` in `~/.zshrc` (without `INC_APPEND_HISTORY` or `SHARE_HISTORY`, macOS zsh only flushes on shell exit). The terminal provider checks `~/.zshrc` on load and renders a dismissible hint strip when missing instead of silently showing stale history.
- *Future note:* adding a `precmd` hook in `~/.zshrc` that writes to a dedicated `~/.dev-island-history` file would be a cleaner long-term alternative that works regardless of zsh history options.
- Watch `~/.zsh_history` with a `DispatchSource` file watcher handling `.delete`/`.rename` by closing the old descriptor and re-arming on the path (zsh atomically replaces on some operations). No polling. Ignore `~/.zsh_sessions/*` — the main file covers it.

### Parse

- Re-parse the full file on change (~50 KB / ~1,300 lines is <1 ms) rather than incremental tailing, avoiding double-counting and offset-reset bugs
- Reassemble trailing `\` continuations into one logical command, joined with a **space**, not a newline: the row is a single line, and a pasted command containing newlines would execute line by line. Only the continuation's leading indentation is dropped — internal spacing is preserved, because it can matter inside quotes
- Strip blanks and leading whitespace
- `uses` = occurrence count; recency = last position in the file (no timestamps available)
- Handle the `": <start>:<elapsed>;<command>"` prefix even though `EXTENDED_HISTORY` is off, so turning it on later does not break parsing
- Decode lossily (`String(decoding:as:)`): real history files contain non-UTF-8 bytes from zsh's metafying, and a strict decode fails outright

### Ignore rules

A **trivia deny-list, not a frequency filter.** Frequency decides what to
highlight; this decides what is never worth retrieving. A command being common is
not a reason to hide it — `python -m backend.main` (89x) is both the most frequent
command in the measured history *and* the most useful entry.

The question a pattern answers is *"would I ever want to paste this back?"*, not
*"is this common?"*. Keep the list short, manual and editable. Do **not**
auto-learn from what has been pasted: that hides things precisely until the first
time they are needed, which is the one moment the panel would have helped.

JSON file in Application Support, one regex per line. Status item gains
"Edit Ignore Rules" which opens it in the default editor. A missing file is
created from the defaults below; an **empty** file means hide nothing, so
deleting every line is a valid way to turn the list off.

Defaults are anchored to the **bare** form deliberately. `^cd` would also hide
`cd ~/Projects/DevIsland`, which is exactly the kind of entry the panel exists to
surface:

```
^cd\s*$
^cd\s+\.{1,2}\s*$
^ls\s*$
^pwd\s*$
^clear\s*$
^exit\s*$
^\.\s*$
```

Measured top commands — `python -m backend.main` (89x), `./dev.sh` (65x) — must
survive the defaults. That is the check to run whenever a pattern is added.

### Redaction

Anything matching the secret heuristic renders masked in the panel (everything
after the first `=` or `:` becomes `••••`), because this panel often sits on
screen during a screen share. Clicking still pastes the real command — that is
the point of the panel. Nothing is written to disk, so the redaction is display
only and there is no second copy to leak.

### Action

Plain click **auto-pastes** via the same `AccessibilityPaster` path as the clipboard panel, with the trailing newline stripped so a stray Return cannot execute a pasted command (⌥-click = copy only). It never executes commands directly.

---

## 5. File shelf

- Drop target covers the **closed island** too, not just the open panel —
  flicking a file at the notch is the point. A drag entering the hot zone
  expands straight to the Shelf panel.
- Default: store references (`[URL]`, persisted as security-scoped bookmarks).
  Optional mode: copy into a shelf folder, for files about to be deleted.
- Drag **out** to Finder / Slack / a browser upload field via `NSItemProvider`.
  This is the half that makes it a tool rather than a list.
- Right-click: Reveal in Finder, Copy Path, Remove.

### Blocker

`NSItemProvider`/`NSDraggingDestination` must be hosted in an `NSView` behind the SwiftUI content. Because `mouseMoved` does not fire during a drag session, keep the closed idle window (`notch + 4` wide — physical cutout only, nothing clickable behind it) permanently interactive (`ignoresMouseEvents = false`) as `NSDraggingDestination`. When music is playing while closed, the `249 pt` chin overlaps live menu-bar space and stays click-through (`ignoresMouseEvents = true`); supporting drag-in while music is playing would require a separate cutout-only drop window later. Right-click `NSMenu`s and drag-outs must also suppress `scheduleCollapse()`. See §1.

---

## 6. Music panel visual upgrade

The detail that makes NotchNook look the way it does is a **blurred artwork
backdrop**, not shadows:

```swift
artwork
  .scaledToFill()
  .blur(radius: 45)
  .saturation(1.6)
  .opacity(0.5)
  .overlay(Color.black.opacity(0.55))
  .clipShape(NotchShape(topRadius: 19, bottomRadius: 24))
```

Layout changes:

| Element | Now | Proposed |
| --- | --- | --- |
| Artwork | 60 pt | 92 pt, continuous corners, soft shadow |
| Title | 15 semibold | 17 semibold |
| Artist | 12 @ 0.55 | 13 @ 0.5 |
| Scrub bar | below text | 3 pt, inside the right column beneath title/artist (fits 162 pt; tighten top/bottom padding to ~38/12 pt or place transport beside title/artist) |
| Times | inline | 10 pt monospaced, elapsed / remaining |
| Transport | plain glyphs | `play.fill` in a filled 28 pt circle, 16 pt neighbours |

Not proposed: tap-artwork-to-flip. No value, extra state.

---

## 7. Browser / YouTube media

**Hypothesis: this already works and needs no code.** YouTube publishes a Media
Session; Chrome and Safari forward it to the same system now-playing session
that `MediaRemote` already reads. Pressing play/pause from the island while the
tab is backgrounded should control it.

Must be tested before any code is written:

1. Play a YouTube video in Chrome, background it
2. Hover the notch — does the title appear?
3. Press pause from the island — does the video stop?

If it works: nothing to do, document it.

If it does not, fallback is AppleScript `do JavaScript` pausing every `<video>`
element in Chrome/Safari. This satisfies "pause the tab I'm not looking at" but
requires Develop → *Allow JavaScript from Apple Events* **and** Automation
permission. Per-tab targeting needs tab enumeration — doable, considerably
uglier. Build only if step 2 fails.

Note: `PlayerService.refresh()` (`Sources/IslandModel.swift`) currently prefers
Spotify whenever it is running, falling back to MediaRemote. With a browser
playing and Spotify merely *running but paused*, this ordering is worth
re-checking — it may mask the browser session.

---

## 8. Phasing

| Phase | Work | Effort |
| --- | --- | --- |
| 0 | Test YouTube/Chrome against the island; confirm clipboard paste-notice behaviour on this macOS build | **partial — never run** |
| 1 | ~~Panel shell: `PanelID`, provider protocol, registry, window resizing, icon nav, default panel, now-playing strip~~ **done** | — |
| 1.5 | ~~Rename to `dev.island` + `NSAppleEventsUsageDescription`; self-signed cert; `build.sh` signing; verify grants survive a rebuild~~ **done** | — |
| 2 | ~~Clipboard provider + frequent strip + `AccessibilityPaster`~~ **done** | — |
| 3 | ~~Terminal provider + ignore rules + redaction~~ **done** | — |
| 4 | Shelf, drag in/out | day |
| 5 | Music visuals | half day |
| 6 | Browser fallback, only if Phase 0 demands it | half day |

Phases 1–3 are complete. The panel shell did turn each feature into a provider
plus a view: the clipboard and terminal panels each landed without touching the
window controller.

Phase 3 added one prerequisite outside the repo: `setopt INC_APPEND_HISTORY` in
`~/.zshrc`. Without it zsh only flushes history on shell exit, so the panel would
show stale commands; it renders a notice strip when the option is missing.

---

## 9. Risks

1. **Three independent redraw drivers.** Marquee at 30 fps (`TimelineView`), the
   progress bar ticking every second, and the waveform. Gate `MarqueeText` to
   `model.expanded` and pause `Equalizer` when hidden, or idle CPU creeps back
   to where it was before the polling fix.
2. **Drag-and-drop into a `.mainMenu + 3` panel.** Works, but the window must
   not be click-through mid-drag, and drag types must be registered on an
   `NSView` behind the SwiftUI content.
3. **Provider lifecycle vs Spotlight handoff.** Both react to `expanded`.
   Suppression must stay authoritative over panel start/stop, or the island can
   start providers while Spotlight owns the screen.
4. **Clipboard polling is unavoidable.** macOS has no pasteboard change
   notification. 0.4 s integer compare is the cheapest available option, but it
   is still a wakeup while the app is idle.
5. **Reading pasteboard contents may show a macOS paste notice (unverified).**
   Phase 0 was never run, so this was never deliberately tested. No notice has
   been observed while capturing, but that is absence of evidence rather than a
   check.
6. **Signing identity and TCC (resolved).** Ad-hoc signing produced a new
   designated requirement on every build, so TCC grants dropped and auto-paste
   failed silently. `build.sh` now signs with `Dev Island Local Signing` (§11),
   `|| true` is gone, and the requirement was verified byte-identical across two
   consecutive rebuilds. The certificate expires in 2036; recreating it means
   re-issuing the Accessibility grant.
7. **Window-follows-shape animation is still not right (open, user-reported).**
   The window is now resized every animation frame from an `Animatable` probe so
   it tracks the shape instead of being pre-sized. Measured good: expand is
   monotonic with no overshoot, the window is solid black through both growth and
   shrink, and a redraw loop (`syncWindow` re-triggering itself at display rate)
   was found and fixed. **The user still reports seeing the desktop behind the
   island during a panel switch.** Not reproduced in captures taken at 8x slowed
   speed, so either it is a frame-timing artefact too fast for `screencapture`
   (~150 ms/frame) to resolve, or it is the cross-fade of two differently-sized
   panel contents rather than the window itself.
   Remaining suspects, in order: (a) one-frame lag between the SwiftUI shape
   render and the window-server resize, (b) the `NotchShape` top taper leaving
   transparent slivers at the top corners by design, (c) the content cross-fade.
   Fix direction if it persists: stop resizing the window per frame and instead
   put the `NSHostingView` in a container at a fixed max size, letting the window
   clip — at the cost of laying smaller panels out in a taller box.

---

## 10. Decisions

### Decided

- **Panel sizes:** `440 × 162` (Music), `440 × 310` (Clipboard & Terminal), `440 × 240` (Shelf).
- **Window sizing:** The window tracks the animated shape frame by frame through an `Animatable` size probe (`syncWindow`), rather than being snapped to the target. Both springs are critically damped so the window itself does not bounce. See risk 7 for the outstanding see-through report.
- **Spotlight trigger:** Removed (`⌘Space` is the precedent); Spotlight avoidance / suppression while `SpotlightState.isOpen` is retained.
- **Music layout:** Keep `162 pt` height; place scrub bar in the right column beside `92 pt` artwork.
- **Closed-state Spotify poll:** Gate the `1.5 s` AppleScript timer to `expanded` only; rely on notifications while closed.
- **Click behaviour:** Auto-paste is in v1 (`⌘V` after collapse; `⌥`-click = copy only). Degrades silently to copy-only with `panelNotice` (`"Grant Accessibility to paste directly."`) when event-posting permission is absent.
- **Terminal panel click:** Auto-paste with trailing newline stripped so a stray Return cannot execute a pasted command.
- **Signing identity:** Self-signed Code Signing certificate (`Dev Island Local Signing`), not ad-hoc, so TCC Accessibility and Automation grants survive rebuilds.
- **Clipboard capture while closed:** Accepted (`0.4 s` `changeCount` integer compare).
- **Panel ranking:** Highlight by frecency (`uses × 0.5 ^ (days / 14)`), never filter by frequency. The only deny-list is the terminal panel's manual trivia list (§4); the clipboard panel has none, because any copied text is potentially worth pasting back.
- **Ignore rules are manual:** no auto-learning from paste history.
- **Terminal ranking:** by use count, then recency (file position). No time decay, because the history file carries no timestamps — a decay curve would be invented rather than measured. The list is recency-ordered; the chip strip is usage-ordered.
- **Terminal persistence:** none. The history is re-parsed from `~/.zsh_history` on change rather than cached in `terminal.json`.
- **Clipboard vs terminal overlap — kept, not gated.** The clipboard captures commands as well as text, so a command you copied can appear in both panels. *Gating the clipboard to non-commands was considered and rejected:* it would delete exactly the entries the terminal can never hold — commands copied from docs, Slack or the web that have not been run yet. *Deduplicating against shell history was also rejected:* it hides a command you copied only to share, breaking the clipboard's "everything I copied" contract in a surprising way.
  If the overlap becomes annoying in use, the fix is to record the source app per entry (already read from `frontmostApplication` for the password-manager blocklist) and demote terminal-sourced copies — not to filter by kind.

### Open decisions

1. **Shelf storage** — references by default, or copy files into a shelf folder?
2. **Default panel on first hover** — Music or Clipboard?
3. **Music as chrome + one panel** — confirm the 28 pt now-playing strip is
   preferable to keeping music permanently visible.

---

## 11. Signing and re-identification (done)

**Status: done.** `Dev Island Local Signing` exists in the login keychain, is
trusted for code signing in the user trust domain, and is valid until 2036.
`build.sh` signs with it and the designated requirement is stable across
rebuilds.

Created with OpenSSL rather than the Keychain Access GUI, which is reproducible:

```zsh
openssl req -x509 -newkey rsa:2048 -sha256 -days 3650 -nodes \
  -keyout dis-key.pem -out dis-cert.pem \
  -subj "/CN=Dev Island Local Signing/O=Dev Island/C=US" \
  -addext "basicConstraints=critical,CA:false" \
  -addext "keyUsage=critical,digitalSignature" \
  -addext "extendedKeyUsage=critical,codeSigning"

openssl pkcs12 -export -legacy -inkey dis-key.pem -in dis-cert.pem \
  -out dis.p12 -passout pass:temp -name "Dev Island Local Signing"

security import dis.p12 -k ~/Library/Keychains/login.keychain-db \
  -P temp -A -T /usr/bin/codesign

security add-trusted-cert -p codeSign dis-cert.pem
```

Two things that cost time and are worth remembering:

- An **empty** PKCS#12 password fails with `MAC verification failed`. Use a
  real password.
- `-legacy` is required: OpenSSL 3 defaults to AES-256, which `security import`
  cannot read.
- Without the final `add-trusted-cert` the identity exists but is flagged
  `CSSMERR_TP_NOT_TRUSTED`, and `codesign` hangs on a keychain prompt instead of
  failing.

**In `build.sh`:** it resolves `ISLAND_SIGN_IDENTITY` → `Dev Island Local
Signing` → a single `Apple Development` identity → fail. No `|| true`: a silently
unsigned build is indistinguishable from a dropped permission.

**Verification:**

```zsh
codesign -d -r- DevIsland.app            # designated requirement — must be identical after a rebuild
codesign -dv --verbose=4 DevIsland.app   # CDHash will differ; that is expected
```

TCC keys grants on the **designated requirement** (which embeds the leaf
certificate hash), not the CDHash. A stable certificate gives a stable
requirement, which is why the grant survives.

### The plist landmine

`Info.plist` has **no `NSAppleEventsUsageDescription`**. Today this is harmless
because an Automation grant for `com.haras.dynamicisland` already exists. The
rename and the new certificate both reset that grant — so the next Spotify call
on a clean TCC state is the first time the app has ever had to *prompt*, and
without the description string macOS can terminate the app instead of prompting.
Phase 1.5 must add it:

```xml
<key>NSAppleEventsUsageDescription</key>
<string>Dev Island controls Spotify playback so the notch can show and change the current track.</string>
```
