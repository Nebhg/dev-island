# Dev Island — multi-panel plan

Status: **Phases 1–6 implemented and verified by use, browser media included;
7–10 pending.** 0a is answered (it works), 0b — whether *reading* the pasteboard
raises a macOS banner — is still unchecked and is the only unknown left in the
happy path. §1 states facts verified against the source; §13 tracks the code
review; §11 records signing and installation.

| Phase | State |
| --- | --- |
| 0a — YouTube/Chrome media | **done, verified by use** |
| 0b — macOS pasteboard read banner | not run |
| 1 — panel host | done |
| 1.5 — rename + self-signed signing | done |
| 2 — clipboard panel + auto-paste | done, verified by use |
| 3 — terminal history panel | done |
| 4 — file shelf | **done, verified by use** |
| 5 — music visual upgrade | done |
| 5.5 — strip removed, per-panel sizes, resize rework | done |
| 5.6 — history windows, `EXTENDED_HISTORY`, sandbox | done, verified against invented data |
| 6 — media transport (§7) | done, verified with a browser |
| 7 — browser artwork in a title-less diff | pending |
| 8 — paste confirmation | pending |
| 9 — video placeholder glyph | pending, maybe unnecessary |
| 10 — view dedup (review 1B) | pending |

Goal: turn a single-purpose music notch into a panel host with a clipboard
history panel, a terminal-history panel, and a file shelf, plus a visual
upgrade to the music panel. Browser media is **not** assumed any more: §7 shows
the current transport cannot see it.

---

## 1. Existing code — verified constraints

These matter because they invalidate some obvious approaches.

| Fact | Source | Consequence |
| --- | --- | --- |
| `islandSize` derives from `expanded` and `activePanel`, and from `shelf.items` for the shelf **(Phase 1, reworked Phase 5.5)** | `Sources/IslandModel.swift:103` | Size changes no longer rely on snapping the frame in the same turn. The window is grown to `max(old, new)` **before** the shape animates and settles afterwards, driven synchronously from the model's setters, so `islandRect` / `inHotZone` are never wrong for a frame — see §2. Two consequences: `expanded` / `activePanel` must go through their `didSet` rather than a Combine sink, and anything else that changes `islandSize` must re-publish — which is why `IslandModel` subscribes to `shelf.$items`. |
| `expand()` selects `defaultPanel` before flipping `expanded` **(found in Phase 4)** | `Sources/IslandModel.swift:86-90` | Anything wanting a specific panel on expand must select it **after** calling `expand()`; selecting first is silently overwritten. This cost a drop target: the shelf was selected during a drag, `expand()` replaced it with the default panel, and the drop landed on a panel with no drop handler. |
| No SPM, no dependencies — plain `swiftc` | `build.sh` | No GRDB/Realm. Persistence must be `Codable` JSON, capped and debounced. |
| `~/.zsh_history`: ~1,300 lines and growing, **no timestamps**, `\` continuations, non-UTF-8 bytes | measured | Recency must come from file position, not time. The parser must join continuations and decode lossily. `INC_APPEND_HISTORY` is now set in `~/.zshrc`, so the file is written per command rather than on shell exit. `EXTENDED_HISTORY` is still off. |
| `panel.ignoresMouseEvents` centralised in `refreshMousePolicy()` **(Phase 1)** | `Sources/IslandController.swift:383` | Policy is `expanded ? false : isPlaying`. During a drag session `mouseMoved` does not fire, so a file dragged at a click-through window never lands: the closed idle window (`notch + 4`, physical cutout only) must stay permanently interactive as `NSDraggingDestination`, while the `249 pt` playing chin stays click-through. Phase 4 depends on this. |
| Hover monitors cover `.mouseMoved`, `.leftMouseDown`, `.leftMouseDragged`, `.leftMouseUp` **(Phase 4)** | `Sources/IslandController.swift` (`installMonitors`, `isCarryingContent`) | A held mouse button posts `.leftMouseDragged`, not `.mouseMoved`, so drag-in needs its own event type or the island never expands. The gate is the drag pasteboard's **types**, not its `changeCount`: measured, the count does not move when a drag starts. The pasteboard is cleared on `.mouseMoved` because AppKit leaves the previous drag's types behind. See §5. |
| Polls only run while expanded **(Phase 1)** | `Sources/IslandController.swift` (`$expanded` sink), `Sources/IslandModel.swift` (`startPolling` / `stopPolling`) | Both the Spotlight watch and `PlayerService.startPolling()` / `stopPolling()` are driven off `$expanded`. Verified: zero `osascript` spawns while closed. This is the precedent the `PanelProvider` lifecycle follows. |
| Panel level `.mainMenu + 3`, SkyLight space attach | `Sources/FullscreenSupport.swift` | New panels inherit this; no extra work. |
| Window frame tracks the island **(Phase 2/5)** | `Sources/IslandController.swift` (`updateGeometry`, `scheduleSettle`, `applyWindowSize`, `onGeometryChange`), `IslandView.swift` (`IslandRootView`) | The window is resized **twice per transition** — up to `max(old, new)` before the shape moves, and back to the target after it settles — and never in between. Three things are load-bearing: the window must never be smaller than the shape (that is the whole fix for risk 7), the content must be laid out at the target size rather than the animating one (otherwise every frame reflows text, which was the jank), and `onGeometryChange` must fire **synchronously** from the model setters, before SwiftUI's first frame. `pointerCapture` separately stops a shrink from collapsing the island out from under a stationary pointer — see §2. |
| Click-to-Spotlight (`openSpotlight()`) | `Sources/IslandView.swift` / `IslandModel.swift` | Removed in Phase 1 (`⌘Space` is the precedent); Spotlight avoidance / suppression while `SpotlightState.isOpen` is retained. |
| 30 ms collapse on pointer exit, with an existing `isInteracting` escape hatch | `Sources/IslandController.swift:566` (`scheduleCollapse`), `Sources/IslandModel.swift:49` (`isInteracting`) | Collapse is deferred 30 ms and then re-checks three conditions: `!model.locksOpen`, `!isInteracting`, `!inHotZone(mouseLocation)`. Right-click `NSMenu`s, drag-ins and drag-outs all move the pointer outside `islandRect`, so `isInteracting` is the guard. It is set by the drag path in `IslandController` and by `ShelfRowInput` while a context menu or drag-out is tracking — no second flag. |
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

SwiftUI animates `NotchShape` inside a fixed-size `NSPanel`. **The window is
resized at the endpoints of a transition, never during it** — this is the
BoringNotch trick, and it is why their animation is smoother than a window that
is resized every frame.

```
panel switch:  window jumps to max(old, new)  →  shape springs inside it
                                                       ↓ 0.6 s
                                          window settles to the new size
```

Two consequences, both load-bearing:

- **The window is never smaller than the shape.** It can only be *larger*, which
  shows as transparent margin around an already-drawn island — not as the desktop
  through it. Risk 7 is therefore impossible by construction, not merely rare.
- **The content never reflows mid-animation.** `IslandRootView` lays the panel out
  once at the *target* size and animates only the frame around it, so a switch
  costs one reflow instead of one per frame. That per-frame reflow — text
  re-wrapping, the marquee re-measuring with `NSString.size(withAttributes:)` —
  was the actual jank, and it also used to drive `NSWindow.setFrame` from
  SwiftUI's async display-link thread, which traps.

The settle is the only reason the window is ever larger than the island, and it
exists so the island does not inherit BoringNotch's permanent dead zone: their
window is permanently `640 × 210`, which swallows every click in the menu-bar
space beside a smaller panel. During the settle of a *collapse* the window is
still panel-sized over live menu bar, so `ignoresMouseEvents` is forced on until
it has shrunk.

Both springs stay critically damped (`dampingFraction: 1`). BoringNotch uses 0.8
because it has 20 pt of shadow padding for the overshoot to live in; here an
overshoot would push the shape past the window and clip it.

`onGeometryChange` is called **synchronously** from the model's `expanded` /
`activePanel` setters rather than from a Combine sink, because the window has to
be grown before SwiftUI renders the first frame of the animation.

**A display change that removes the notch collapses rather than hides.** `observeScreens`
used to call `panel.orderOut` alone, which left `expanded = true` while the window
was invisible — so the Spotlight watch and the player poll kept running, which is
the one rule this app does not break, and the island came back open when the notch
returned. It now cancels any pending settle, collapses, then hides. The settle also
resolves `targetScreen()` inside its work item rather than capturing the screen at
scheduling time, so a display change mid-settle cannot apply the old screen's
frame.

**`pointerCapture` covers the case the window cannot.** Switching to a shorter
panel lifts the island's bottom edge above a stationary pointer, which makes
`inHotZone` false and collapses the island out from under the cursor. So
`model.$activePanel` snapshots the old `panel.frame` into `pointerCapture` when
the pointer is inside it, and `handleMouse` treats that rect as inside until the
pointer actually leaves it. It is cleared on expand and when the pointer exits
the captured rect.

The `32 pt` physical notch, the panel bar in that band, and padding consume
`~40 pt` of vertical chrome. Sizes differ by panel:

| Panel | Size (pt) | Why |
| --- | --- | --- |
| Clipboard | 520 × 320 | wide rows: text, source and age on one line; FREQUENT chips stop wrapping |
| Terminal | 520 × 320 | long commands stop truncating |
| Shelf | 440 × 102–260 | **height follows the file count**; 102 with one file, capped at 260 before it scrolls |
| Music | 440 × 190 | 132 pt artwork + scrub + times + transport ≈ 150 pt of content |

Clipboard and terminal are deliberately identical, so switching between the two
most-used panels moves nothing at all.

The shelf is the one panel that is not a fixed size — see §5. Its height is
`notchHeight + 38 + 31·items + 1`, capped at 260. A fixed 260 reserved room for six
rows even when one file was dropped, which left a mostly empty card hanging under
the notch.

Adding or removing a file resizes the window the same way a panel switch does, and
this is the case that shows why the trigger has to live in the model. **The
controller resizing the window is not enough**: `islandSize` is read by the view to
decide where the shape is heading, so the model also has to re-publish or SwiftUI
never re-renders and the shape stays at the old height while the window grows. The
first version subscribed in `IslandController` only, and the newly added row was
clipped until some unrelated change re-rendered the view. `IslandModel` now
subscribes to `shelf.$items`, sends `objectWillChange` and then calls
`onGeometryChange`.

**Anything that changes `islandSize` needs that pair**, not just the geometry call:
`expanded` and `activePanel` get it from their `didSet` (SwiftUI is already
watching those), and the shelf cannot, because it is a different object.

### Navigation

The switcher sits **in the menu-bar band either side of the physical cutout**,
which is otherwise dead screen space the island reserves and never uses. Two
icons left of the notch, two right, in this order:

```
  clipboard  terminal  |  (notch)  |  shelf  music
```

Active at full white, inactive at 0.3. This replaced a bottom nav row, which cost
~22 pt of content height on every panel and put the switcher where the eye is not.

The icons are **anchored to the cutout**, not centred in the side band. Panels
differ in width, so centring would slide all four icons sideways on every switch.
The band is measured from `activePanel.preferredSize`, not from the window, so the
icons stay put even while the window is still the larger of the two sizes.

Deliberately **no scroll-to-switch**: a clipboard list needs wheel scrolling,
and a global scroll handler fights it.

### Time window

The panel header carries `24h · 7d · 30d · All`, persisted per panel in
`UserDefaults`. It is a **view filter, not retention**: choosing 24h hides older
rows and deletes nothing. Deleting on toggle would be a trap — pick 24h once and
the month is gone, with no undo — and the terminal's history belongs to zsh, so
there is nothing of ours to delete anyway.

Both the list and the `FREQUENT` chips filter, or the chips would advertise
30-day commands above a 24-hour list. The command count shows the filtered total,
so clicking a window gives immediate feedback. When a window matches nothing, the
chip row collapses and the empty state says "Nothing in the last 24 hours / Pick
All to see older commands" rather than "No history yet" — with 300 entries sitting
behind a filter, the latter reads as broken.

`ISLAND_HISTORY` points the provider at a fixture file, which is how the windows
are tested without touching real shell history.

### Default panel

**Clipboard.** It is the panel that is useful the instant the island opens — you
open it to get something back, not to look at something. Submenu on the existing
status item (`Sources/App.swift`), persisted in `UserDefaults`. No settings window.

A stored `music` is treated as the old default rather than a choice and migrated
to clipboard, so existing installs get the new behaviour instead of being stuck
on a panel nobody picked.

### Music while another panel is open

**No strip. Music is only visible in the closed notch.** A 28 pt now-playing
strip was built on every non-music panel and then removed: it was chrome that
stayed on screen, it duplicated what the closed notch already shows, and it cost
~34 pt at the top of every list.

The closed notch already carries it — `WingContent` plus the chin, which widens
the island by `2 * (height - 12) + 20` while `isPlaying`, giving artwork on one
side and a waveform or pause glyph on the other. Nothing is shown when nothing is
playing, and a paused track collapses back to the bare cutout.

Consequence, accepted: a paused track is invisible until the island opens. That
is the trade for not having chrome on the lists.

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
  Both stores write through `AtomicJSON.write` — encode, write a temp file, chmod
  it, then `replaceItemAt`. The chmod has to land on the **temp** file: creating the
  real file and fixing its mode afterwards leaves a window where clipboard history
  is world-readable.

### Entry model

```swift
struct ClipEntry: Codable, Identifiable {
    let hash: String        // SHA256 of normalised text
    var text: String
    var kind: ClipKind      // .text .command .url .path .code
    var firstSeen: Date
    var lastUsed: Date     // last use: drives frecency and eviction
    var lastCopied: Date?  // last time it entered the clipboard; what the row shows
    var uses: Int
}
```

Dedupe by hash; re-copying moves an entry to the top and increments `uses`.
Cap 300, evict oldest-by-`lastUsed`.

**Two timestamps, deliberately.** `lastUsed` moves on every paste and drives
frecency and eviction; `lastCopied` moves only when the text actually goes onto
the clipboard, and is the one the row's age chip shows. A single field made a
path copied yesterday read "1m" because it had been clicked once — which looks
like the clock is broken rather than like "last used". `touch` therefore also
leaves the row where it is: pasting something is not copying it, and reordering
on use made the list shuffle under the pointer right after a click.

`lastCopied` is optional so stores written before it still decode, falling back to
`firstSeen`. Load sorts by `copiedAt` rather than trusting file order, because the
old order was by last use and the age column would otherwise jump around.

Ages refresh on `TimelineView(.everyMinute)`. Not `.periodic(from: .now, ...)`:
`.now` is re-evaluated on every render, which restarts the schedule and pins a
core at 6%.

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

### Paste confirmation (planned — Phase 8)

Auto-paste works but is **invisible**: the island collapses, ⌘V fires, and the
only evidence is that text appears in the app you were already looking at. Click a
row and nothing acknowledges it, so it reads as "did that do anything?" —
especially on ⌥-click, where copy-only is deliberate and looks identical.

The confirmation has to appear **after the collapse**, because the panel is gone
by the time the keystroke lands. So it goes in the closed notch, reusing the chin
that already exists for "music playing": the island widens for ~1 second and shows
a checkmark plus "Pasted". That also means it cannot be a row highlight, a notice
strip, or anything else inside the panel.

Design constraints:

- **Two outcomes, two signals.** Auto-paste shows ✓ Pasted; ⌥-click shows
  "Copied" instead, so the difference is visible rather than something you have to
  remember.
- **The toggle is a small icon in the clipboard header**, beside the window
  picker, persisted in `UserDefaults`. Off means no chin and no widening at all —
  not a dimmed one.
- **It must not fight the music chin.** If a track is playing, the chin is already
  showing artwork and a waveform; the confirmation takes precedence for its second
  and then reverts, rather than the two trying to share the band.
- **Failure must stay loud.** `AccessibilityPaster.postPaste()` returning false
  must not double as a failure report: with the grant missing the keystroke is
  dropped silently, so a tick would be a lie. The Accessibility notice is the only
  signal for that case.

Open question, deliberately not decided here: whether a 1 s chin is better than
delaying the collapse by ~600 ms and showing the confirmation in the panel. Delay
is more legible but makes every paste feel slower, and the keystroke would land
late. Chin is the current choice.

### Timing

There is **no collapse-completion callback** — `collapse()` sets `expanded =
false` and the `$expanded` sink updates state synchronously; SwiftUI's animation
is cosmetic and invisible to the controller (and `ignoresMouseEvents` flips
immediately even while the window waits ~0.4 s to shrink). Post ⌘V after `0.08 s`
(`asyncAfter(deadline: .now() + 0.08)`, `IslandModel.deliverPaste`), treating the
80 ms as empirical: measure whether the target app still holds the old pasteboard
contents, and lengthen only if it does. A plain next-turn `async` was too early.

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

- **Posting a synthetic ⌘V needs the Accessibility grant, and only the app's own
  grant counts.** This cost a full detour, so it is worth stating precisely:
  launched *from a terminal*, both preflights report `true`; launched from
  Spotlight or Finder, both report `false`. A terminal-launched process is
  attributed to the terminal, which already holds the grant; a LaunchServices
  launch is its own responsibility. Auto-paste therefore appeared to work in every
  test that ran the binary directly — including the ones that "proved" TCC
  survived the move to `~/Applications` — and failed the moment the app was opened
  the way a person opens it.
- **Never test TCC from a terminal launch.** It reports the terminal's grant, not
  the app's. Use `open --env … -a "Dev Island"` if the panel needs to be open, or
  launch it from Spotlight.
- **First run prompts, and the prompt worked.** `AXIsProcessTrustedWithOptions`
  with the prompt option is called once at launch, so a new install gets the
  system dialog before it is ever needed rather than after the first dead paste.
  Verified on this machine: the dialog appeared, the grant was enabled, auto-paste
  began working with no relaunch.
- The notice strip is a **button** that opens Privacy & Security → Accessibility,
  for anyone who dismissed the dialog. Computed from the live grant, so granting
  clears it on the next panel open.
- `postPaste()` is not gated on the check: with no grant the event is dropped
  anyway, so attempting costs nothing.
- **Auto-paste has a toggle** — a pill reading `Autopaste On` / `Autopaste Off` in
  both history headers, persisted, on by default. Named for the setting rather than
  the outcome: "Paste / Copy" read as an action button instead of a switch. Off
  means copy-only, the same result as ⌥-click, which keeps working either way, and
  no notice is shown while it is off.

---

## 4. Terminal history panel

### Ingest

- **Prerequisite:** `setopt INC_APPEND_HISTORY` in `~/.zshrc` (without `INC_APPEND_HISTORY` or `SHARE_HISTORY`, macOS zsh only flushes on shell exit). The terminal provider checks `~/.zshrc` on load and renders a dismissible hint strip when missing instead of silently showing stale history.
- **Second prerequisite** (for the time windows, §2): `setopt EXTENDED_HISTORY`, so zsh prefixes each entry with `: <epoch>:<elapsed>;`. Without it the file carries bare command lines and there is no time to filter on — only order. The parser accepts both shapes; entries written before the option was enabled have no timestamp and appear **only** under the "All" window, because inventing a time for them would be a guess and hiding them from "All" would lose them.
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

`~/Library/Application Support/Dev Island/ignore-rules.txt`, one regex per line. Status item gains
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

A **staging area in transit**, not a file manager. The job: one impossible drag
becomes two trivial ones, with unlimited time in between. It holds references
rather than copies, so the disk stays clean and removing an item from the shelf
never touches the real file.

### How the two reference implementations do it

**NotchNook** (closed source; behaviour from lo.cafe's own guides):

- **Tray** — drag files to the top of the screen to keep them, drag them out to
  the destination later. Files are referenced, not copied.
- **Pockets** — shake the pointer mid-drag and a pocket opens holding the files;
  Pro allows several, one per destination.
- **Drop Area actions** — keep, AirDrop, convert format.
- The shelf is a row in the expanded panel and can be toggled off entirely to
  reclaim the space.

**boring.notch** (read from source; a real subsystem — 9 services, 3 view models,
5 views):

| Concern | Their answer |
| --- | --- |
| Item model | `enum ShelfItemKind { file(bookmark: Data), text(string:), link(url:) }` |
| Persistence | One JSON array in App Support, written on every mutation, survives restart |
| File identity | **Security-scoped** bookmarks (`.withSecurityScope`), resolved on use, stale ones refreshed and written back |
| Non-file drops | Written to `NSTemporaryDirectory()/<uuid>/`, bookmarked, flagged `isTemporary`, deleted on removal |
| Drop in | SwiftUI `.onDrop(of: [.fileURL, .url, .utf8PlainText, .plainText, .data])` on the panel |
| Drop onto the **closed** notch | `DragDetector`: global monitors on `leftMouseDown`/`leftMouseDragged`/`leftMouseUp`, comparing `NSPasteboard(name: .drag).changeCount` to distinguish a content drag from a window drag, then hit-testing the pointer against the notch rect to expand |
| Drag out | One `NSItemProvider` per item, plus a combined provider for multi-selection |
| Stale files | `bookmark.validate()` on launch; items whose file is gone are dropped |
| Dedupe | By `identityKey` |
| Not needed by us | QuickLook, thumbnail generation, AirDrop/Quick Share, image processing |

### What is built

| Piece | State |
| --- | --- |
| `ShelfStore` | Path + plain bookmark, dedupe by resolved path, cap 30, immediate `0600` write, dead references pruned on load |
| `ShelfPanel` | File icon, name, parent folder, size; click reveals in Finder; right-click Open / Reveal / Copy Path / Remove. **Panel height follows the item count** — 102 pt with one file, +31 per file, capped at 260 where the list starts scrolling |
| Drop | `public.file-url` only; anything else is rejected so the drag animates back rather than being silently swallowed |
| Drag-in | Opens the shelf, not the default panel; a cancelled drag restores the previous panel |
| Drag-out | `NSView` + `NSDraggingSource`, 3 pt threshold, copy-only, icon as the drag preview — **verified by use** |

**All exercised by hand, 15 Nov.** The row context menu (Open / Reveal / Copy
Path / Remove), the hover `✕` removal and scroll-wheel forwarding through
`ShelfRowInput` all work, as does dragging a file onto the closed notch now that
dropping one grows the panel by `31 pt` per file. Those three were the parts most
likely to bite, because they share one `NSView` that owns the mouse.

### Design

- Drop target covers the **closed island** too, not just the open panel —
  flicking a file at the notch is the point. A drag entering the hot zone
  expands straight to the Shelf panel.
- **References, not copies.** `ShelfItem { path, bookmark, added }`, deduped by
  resolved path, capped at 30: this is a staging area, not a library.
- **Plain bookmarks, not security-scoped.** boring.notch needs
  `.withSecurityScope` only because it is sandboxed (`app-sandbox = true` in its
  entitlements). Dev Island ships **no entitlements file** and `build.sh` signs
  without `--entitlements`, so it is unsandboxed and a bare path would work
  forever. A plain `bookmarkData` is still worth the ~10 lines: it resolves
  across renames and moves, which a path never does. Store both — path for
  display and cheap comparison, bookmark for resolution.
- **Drag out** via `NSURL` as the pasteboard writer, which writes `public.file-url`
  for Finder and browser upload fields. (`NSItemProvider` is the obvious choice but
  does not conform to `NSPasteboardWriting` on this SDK.) This is the half that
  makes it a tool rather than a list.
- Click: **Reveal in Finder** — the dev-relevant action, and free.
- Right-click: Reveal in Finder, Copy Path, Remove.
- **Files only.** Text and links are the clipboard's job: copying them is one
  keystroke, the clipboard already captures them automatically, and a shelf row
  would only add a second place to look for the same string. A file is the one
  thing the clipboard cannot hand back as a usable reference. So the drop target
  accepts `public.file-url` only, and dragging text at the notch does nothing at
  all rather than opening a target that then refuses the drop.

Not building **Pockets** — NotchNook's shake-the-pointer-to-open-a-pocket feature
(Pro allows several, one per destination). Shake detection plus multi-pocket
management is a lot of machinery for a marginal gain over one shelf.

### Storage: references (decided)

| Mode | Behaviour | Verdict |
| --- | --- | --- |
| **References** | Path + bookmark; the shelf never owns the file | **Chosen.** Matches both reference implementations and the shelf's purpose |
| Copies | Copy into `~/Library/Application Support/Dev Island/Shelf/` | Rejected: duplicates data silently, needs a size cap and a cleanup story, and makes "remove from shelf" ambiguous about whether the real file is affected |

Copy-on-drop would only earn its place for files that are *about to be deleted*,
which is too narrow to design around.

### Drag-in mechanics — and the bug this exposes

`NSItemProvider`/`NSDraggingDestination` must be hosted in an `NSView` behind the
SwiftUI content, and the window must not be click-through mid-drag. Keep the
closed idle window (`notch + 4` wide — physical cutout only, nothing clickable
behind it) permanently interactive (`ignoresMouseEvents = false`) as an
`NSDraggingDestination`. When music is playing while closed, the `249 pt` chin
overlaps live menu-bar space and stays click-through
(`ignoresMouseEvents = true`); supporting drag-in while music is playing would
need a separate cutout-only drop window later.

**Selecting the shelf is not enough — `expand()` overwrites it.** `IslandModel`
sets `activePanel = defaultPanel` inside `expand()` before flipping `expanded`.
Selecting the shelf on drag-in was therefore immediately undone: the island opened
to the default panel, that panel has no drop handler, and the drop landed on
nothing. Symptom was "the notch opens but the file panel doesn't and the file never
appears" — two complaints with one cause. The shelf is now selected *after*
`expand()`, and the panel to restore on cancel is computed the same way
(`expanded ? activePanel : defaultPanel`) — what `expand()` is about to show, not
what was left over from last time.

**The existing hover monitor cannot see a drag.** `IslandController` monitors
only `.mouseMoved` and `.leftMouseDown` (`installMonitors`, line 331). While a
mouse button is held the system posts `.leftMouseDragged`, **not** `.mouseMoved`,
so dragging a file toward the notch produces no events at all: `inHotZone` never
becomes true and the island never expands. This is precisely why boring.notch
built `DragDetector` around `.leftMouseDragged`. Phase 4 therefore needs a small
detector of its own. See risk 8.

Because of that, the collapse guard has to be driven explicitly. Right-click
`NSMenu`s and drag-outs also move the pointer outside `islandRect`, and while a
drag is in flight the pointer crosses the hot-zone boundary constantly, so without
a guard the shelf collapses mid-drag.

**That guard already exists.** `IslandController` declares
`var isInteracting = false` (line 40) and `scheduleCollapse()` already refuses to
collapse while it is true (line 395), alongside `model.locksOpen`. Nothing sets it
yet. Phase 4 is therefore wiring, not new state:

| Event | `isInteracting` |
| --- | --- |
| `draggingEntered` | `true` |
| `performDragOperation` | `false` |
| `draggingEnded` | `false` |
| `leftMouseUp` (from the drag detector) | `false` — the reliable fallback |
| `NSDraggingSource` drag-out ends | `false` |
| Right-click `NSMenu` opens / closes | `true` / `false` |

**Do not clear on `draggingExited`.** It fires every time the pointer crosses the
hot-zone boundary mid-drag, which is constant while dragging, so clearing there
would drop the guard at precisely the moment it is needed and collapse the island
under the pointer. `draggingEnded` is the terminal event and is delivered even
when the drop lands outside the island. The global `leftMouseUp` from the drag
detector is the belt-and-braces path, since it does not depend on destination
callbacks arriving in any particular order.

### The drag detector — built and measured

A naive `.leftMouseDragged` monitor fires on every window move, so dragging a
window across the notch would expand the island. The gate has to tell a content
drag from a window drag, and **the obvious signal does not work**:

> `NSPasteboard(name: .drag).changeCount` is not a drag-start signal.

Measured with `ISLAND_DRAG_PROBE` over eight drags. One file drag produced 167
dragged frames inside the hot zone over 3.8 s with `public.file-url` present and
the count **unchanged the whole time**, so a count-based gate silently rejected a
real file drag. Another drag bumped the count mid-session with `types=[]` for a
single frame — that is Finder lazily rewriting the pasteboard, not a drag
starting. boring.notch gates on this count; on this evidence it would fail
intermittently for them too.

**What actually works — two parts:**

1. **Gate on the pasteboard's types alone** — `public.file-url`, since the shelf
   takes files and nothing else. Text drags therefore do not open a target that
   would refuse them.
2. **Clear the drag pasteboard when a drag ends.** AppKit leaves the last drag's
   types behind, so after one file drag *every* window drag looked like a content
   drag — measured: 886 events across five drags, all reporting `public.file-url`,
   window drags included. `mouseMoved` never fires while a button is held, so its
   arrival proves no drag is in flight; clearing there (and once at launch) makes
   a live drag the only time the pasteboard has types. The clear is skipped unless
   a drag was actually seen, so pointer movement does not pay an IPC round trip.

Verified after the fix: 302 dragged events with empty types (window drags,
correctly ignored) and 288 with `public.file-url` (file drags, correctly
accepted), and the user confirmed a window no longer opens the island while a
file does.

**Spike status (14 Nov):**

| Question | Result |
| --- | --- |
| Does drag-out work from a non-activating panel? | **Yes.** `.copy` operation, payload delivered into TextEdit, app never activated (risk 9) |
| Does a global `.leftMouseDragged` monitor fire during a Finder drag? | **Yes.** 1,028 events in one session. No `CGEvent` tap needed (risk 10) |
| Does a drop on the closed idle cutout reach `NSDraggingDestination`? | **Moot.** Drag-in expands the island before the pointer arrives, so the drop lands on the open panel. Only matters if the detector ever fails to fire |

A standalone spike binary cannot answer the monitor question: launched from a
terminal it does not inherit the app's TCC grant and receives nothing, which looks
identical to Finder swallowing the events. The probe inside the signed app is the
only reliable way to ask.

### Drag-out mechanics — built and verified

Confirmed working by use: dragging a row out delivers the file to the destination,
as do the context menu, ✕-removal and scroll-under-row — all confirmed 15 Nov.

Dragging a row out is what makes the shelf a tool rather than a list, and it
cannot be done with SwiftUI's `.onDrag`. `.onDrag` and `.onTapGesture` compete
for the same gesture, so click-versus-drag becomes unpredictable. Each row is
overlaid with a transparent `NSView` (`RowInputView`) that owns the mouse:

```
mouseDown   → record the event, do NOT act
mouseDragged → if hypot(dx, dy) > 3 pt, beginDraggingSession(with:source:)
mouseUp     → if no drag started, click: remove-hit-rect → remove, else reveal
```

The SwiftUI row still draws everything; the `NSView` is input only, so the visuals
stay declarative. Details that matter:

- **Fire the click on `mouseUp`, not `mouseDown`.** boring.notch fires on
  mouse-down unconditionally, so pressing a row and then dragging both reveals the
  file in Finder *and* starts a drag. The threshold does not prevent this — it
  only stops the drag from starting on a small movement. This is the one place we
  deliberately diverge.
- **`NSURL` is the pasteboard writer, not `NSItemProvider`.** `NSItemProvider`
  does not conform to `NSPasteboardWriting` on this SDK, so the obvious choice does
  not compile; `NSURL` writes `public.file-url` for a file URL, which is what
  Finder and upload fields accept.
- **Copy only, unconditionally.** A shelf holds references, so dragging out must
  never *move* the real file onto another volume. boring.notch exposes the same
  behaviour as a `copyOnDrag` preference; here it is not negotiable. Consequence
  worth knowing: dropping a row onto a Finder folder **duplicates** the file.
- **The hover affordance is drawn, not clickable.** The `NSView` covers the row,
  so a SwiftUI button would never receive the click. The ✕ is an `Image` and the
  view hit-tests its rect, which keeps one owner for the mouse.
- **Forward `scrollWheel`.** The overlay sits above SwiftUI's content, so without
  forwarding, the list stops scrolling whenever the pointer is over a row.
- **Suppress collapse for both paths.** `isInteracting` now lives on `IslandModel`
  rather than the controller, because views need it too: a context menu moves the
  pointer off the island, and a drag-out leaves it entirely. Set around the menu
  call and around the drag session.
- The drag preview is the file's icon at 32 pt. A row render would look nicer but
  costs an `ImageRenderer` pass per drag for little gain.
- No multi-selection yet, so one `NSDraggingItem` per session. When selection
  arrives, register one writer per item so Finder receives N files.

### What not to take from boring.notch

| Their approach | Why not |
| --- | --- |
| Security-scoped bookmarks, `accessSecurityScopedResource` | Pure sandbox workaround; we ship no entitlements file |
| Temp files (`NSTemporaryDirectory()/<uuid>/`) for text and URL drops | Exists only so sandboxed QuickLook has a file to preview |
| `ThumbnailService` + `ImageProcessingService` | Real per-item CPU cost; `NSWorkspace.icon(forFile:)` is already cached by the system |
| QuickLook panel integration | `QLPreviewPanel` wants key window and would fight `becomesKeyOnlyIfNeeded`. Polish, high risk |
| Shift-click range selection with an anchor | Worth it at their item counts, not in a 440 pt panel capped at ~30 |
| Their structure — 9 services, 3 view models, 5 views, one view model at 1,113 lines | Over-built for a staging area. Ours is a store, a provider, and one view |
| `Animation.spring(.bouncy(duration: 0.4))` | Does not transfer: their shape animates inside a fixed window, while our window resizes to follow the shape, so any overshoot moves the real window. Our critically-damped springs are a consequence of our architecture, not a style choice |

### Licence boundary

boring.notch is **GPL-3** and Dev Island is **MIT**. Nothing may be copied from
it — not files, not functions, not comments. What is taken is approach: which
system APIs to use, which signals to gate on, which thresholds work, and which
pitfalls to avoid. Facts, API usage and standard technique are not copyrightable;
a reimplementation written from an understanding of the behaviour is. The
existing precedent is the notch geometry constants, taken the same way.

**`vendor/mediaremote-adapter` is a different case.** It is **BSD-3-Clause**, not
GPL, so it is vendored as source and compiled by `build.sh` rather than
reimplemented — and its copyright notice ships in
`Contents/Resources/MediaRemoteAdapter-LICENSE.txt` as the licence requires. That
keeps the app buildable from a clone with no blob, while staying MIT.

---

## 6. Music panel — black glass, not colour — done

A blurred colour backdrop was built first and then removed. It looked good on its
own but broke the island: colour next to the black cutout makes the notch's edge
visible, and it made the music panel the only panel that was not black. The
replacement is one shared surface for every panel:

- **The notch band stays pure black**, so the cutout is invisible against it.
- **Below it, a glass pane**: a faint white gradient (5.5% → 1.2%) with a 0.5 pt
  hairline along its top edge. Enough to read as a surface rather than a flat
  rectangle, not enough to compete with content.
- Deliberately **not** `.ultraThinMaterial`: a material samples the desktop behind
  the window, which would make the island's edge visible against the bezel — the
  exact thing the black band exists to prevent.

| Element | Was | Now |
| --- | --- | --- |
| Artwork | 60 pt | 132 pt, continuous 20 pt corners, soft shadow |
| Title | 15 semibold | 19 semibold |
| Artist | 12 @ 0.55 | 14 @ 0.5 |
| Scrub bar | full-width row below the content | 3 pt, in the right column under the artist, times beneath it |
| Times | inline | 10 pt monospaced digit, elapsed / remaining |
| Transport | grey circles | `pause.fill` in a filled 28 pt **white** circle with a dark glyph; plain 13 pt glyphs either side, 16 pt apart, centred under the text column |

The player block is centred vertically and its right column is pinned to the
artwork's height (`132 pt`), so the title sits beside the artwork instead of
stretching to the panel's full height and leaving the artwork floating. The panel
is `440 × 190`: 132 pt of artwork plus scrub, times and a 28 pt transport row
needs ~150 pt of content, and 310 was mostly empty.

Not proposed: tap-artwork-to-flip. No value, extra state.

---

## 7. Browser / YouTube media

**Verified working, 15 Nov.** A YouTube video playing in Microsoft Edge appears in
the island with its title, channel, duration and position. The path is:

```
Edge → system now-playing session → vendored helper (perl) → MediaStream → NowPlaying
```

What the session actually carries, read from the helper:

```
bundleIdentifier:     com.microsoft.edgemac
title:                This Is Dead By Daylight Late At Night 28
artist:               Skermz              ← the channel
duration:             912.281     elapsedTime: 144.383827
artworkData:          base64 JPEG, ~16 KB
artworkMimeType:      image/jpeg
playing:              False
```

So the browser publishes the **thumbnail**, and general YouTube videos work — not
just YouTube Music. That was the whole point of preferring this route over a
per-site integration.

### Two things this settled

**There is no artwork URL, only bytes.** The schema has `ArtworkData`,
`ArtworkDataWidth`, `ArtworkDataHeight` and `ArtworkMIMEType` — no `ArtworkURL`.
The thumbnail is whatever the playing app hands over; it cannot be chosen or
downloaded by us. Which is why an earlier idea — fetch the thumbnail ourselves —
was never possible.

**The old transport was dead, and it hid behind Spotify.** `MediaRemote` returns an
empty dictionary to an unentitled caller (measured: 8 polls, `keys=0`), so a
browser looked identical to Spotify-paused: nothing. Every track the island had
shown came from the Spotify AppleScript bridge, which wins whenever Spotify runs —
so the direct path was never exercised.

### Outstanding: artwork arriving after the metadata

The thumbnail shows in the panel (verified), but it can be **missed** when it
arrives as its own update. `MediaStream.decode` requires a `title`, and a diff
payload that only adds `artworkData` has none, so the update is dropped and the
placeholder stays. That is the likely cause of "title appears, artwork does not".

Fix shape: keep the last decoded track and, for a payload with no title but with
artwork, attach the image to it rather than discarding the line.

**Fallback if a session genuinely has no artwork:** the gradient placeholder
currently draws a music note. A video/play glyph reads better for a browser
session, and `bundleIdentifier` / `mediaType` are both available to choose with.
Deferred until the diff bug above is fixed — it may not be needed at all.

### The transport, as built

**`MediaStream` + a vendored, source-built helper.** The app spawns
`/usr/bin/perl <bundle>/Resources/mediaremote-adapter.pl
<bundle>/Frameworks/MediaRemoteAdapter.framework stream` and reads JSON lines from
stdout. Commands still go through the direct dlsym path in `MediaRemote`: sending
was never gated, only reading.

- **Built from source, not shipped as a blob.** 15 plain Objective-C files with no
  dependencies compile in ~3 s with the system `clang`; `cmake` (which the
  upstream project expects) is not installed and is not needed. So `git clone &&
  ./build.sh` remains the whole build.
- **Artwork arrives as base64 in the payload** and is decoded once per item,
  cached by `contentItemIdentifier`, because a 75 KB JPEG per update would be
  absurd. `carryingArtwork(from:)` covers the updates that arrive without it —
  that rule stopped being inert the moment the transport started working.
- **Cost, measured:** helper 0.0% CPU / 22 MB; app 0.0% CPU closed and paused.
  It is the second deliberate exception to "nothing runs unless the panel is
  visible", because the closed notch shows what is playing and a stale title there
  is worse than 22 MB. The clipboard capture is the first.
- **The helper is swept on launch.** The adapter writes only when the session
  changes, so a killed app does not reliably close the pipe and the child can
  outlive it — observed: two orphans after a few relaunches. `pkill -f <script>`
  at startup, plus an explicit stop on clean quit.

Precedence is unchanged: Spotify's AppleScript bridge wins whenever it is actually
playing, and the stream covers everything else — a browser, Music, VLC.

**Verified against a real browser session** — see the top of this section. Chrome
and Edge both surface through the same session; the helper's own `get` command is
the fastest way to inspect what a player is publishing:

```
/usr/bin/perl DevIsland.app/Contents/Resources/mediaremote-adapter.pl \
  "$PWD/DevIsland.app/Contents/Frameworks/MediaRemoteAdapter.framework" get
```

---

## 8. Phasing

| Phase | Work | Effort |
| --- | --- | --- |
| 0a | Test YouTube/Chrome against the island (§7) | **done, works** — title, channel, duration, position, thumbnail |
| 0b | Does *reading* the pasteboard trigger a macOS "pasted from" banner? (Distinct from the in-app paste confirmation in §3) | not run |
| 1 | ~~Panel shell: `PanelID`, provider protocol, registry, window resizing, icon nav, default panel~~ **done** | — |
| 1.5 | ~~Rename to `dev.island` + `NSAppleEventsUsageDescription`; self-signed cert; `build.sh` signing; verify grants survive a rebuild~~ **done** | — |
| 2 | ~~Clipboard provider + frequent strip + `AccessibilityPaster`~~ **done** | — |
| 3 | ~~Terminal provider + ignore rules + redaction~~ **done** | — |
| 4 | ~~Shelf: drag-in detector, store with bookmarks and load-time pruning, panel, file-only drop, drag-out~~ **done, verified by use** | — |
| 5 | ~~Music visuals: black glass, 132 pt artwork, white transport circle~~ **done** | — |
| 5.5 | ~~Remove the now-playing strip, per-panel sizes, window resized at endpoints only~~ **done** | — |
| 5.6 | ~~`24h / 7d / 30d / All` windows on both history panels; `EXTENDED_HISTORY`; `ISLAND_DATA_DIR` sandbox~~ **done, verified against invented data** | — |
| 6 | ~~Media transport: vendored `mediaremote-adapter` built from source, streamed through `MediaStream`~~ **done and verified with a real browser session** | — |
| 7 | Artwork arriving in a title-less diff is dropped, so a browser thumbnail can be missed (§7) | ~30 min |
| 8 | Paste confirmation in the closed notch, toggleable from the clipboard header (§3) | ~1 hour |
| 9 | Video placeholder glyph for sessions with no artwork — only if 7 leaves gaps (§7) | ~30 min, maybe unnecessary |
| 10 | View dedup: `PanelEmptyState`, `FrequentChip`, `HistoryRow`, `PanelSectionHeader` (§13) | ~1.5 hours |

Phases 1–5.6 are complete. The panel shell did turn each feature into a provider
plus a view: the clipboard and terminal panels each landed without touching the
window controller.

Two prerequisites now live outside the repo, both in `~/.zshrc`:
`setopt INC_APPEND_HISTORY` (without it zsh only flushes history on shell exit, so
the panel shows stale commands and raises a notice strip) and
`setopt EXTENDED_HISTORY` (without it there is no time to filter on — see §2).

---

## 9. Risks

1. **Independent redraw drivers.** The marquee runs at 30 fps (`TimelineView`),
   the progress bar ticks every second, and the equaliser animates
   `repeatForever`. Measured after the polling fix: **0.0% closed and idle, ~2%
   closed and playing**. The marquee is now effectively gated — it only exists
   inside `MusicPanel`, which only exists while expanded — so the remaining cost
   is the equaliser, which is the live activity and therefore intentional.
   See the accepted rough edge in §9.
2. **Drag-and-drop into a `.mainMenu + 3` panel.** Works, but the window must
   not be click-through mid-drag, and drag types must be registered on an
   `NSView` behind the SwiftUI content. See §5 for the full mechanics.
3. **Provider lifecycle vs Spotlight handoff.** Both react to `expanded`.
   Suppression must stay authoritative over panel start/stop, or the island can
   start providers while Spotlight owns the screen.
4. **Clipboard polling is unavoidable.** macOS has no pasteboard change
   notification. 0.4 s integer compare is the cheapest available option, but it
   is still a wakeup while the app is idle.
5. **Reading pasteboard contents may show a macOS paste notice (unverified).**
   This is check 0b and it has never been run deliberately. No notice has been
   observed while capturing, but that is absence of evidence rather than a check.
   Distinct from the **in-app** paste confirmation in §3/Phase 8 — that one is
   ours and is being added because auto-paste is otherwise invisible.
6. **Signing identity and TCC (resolved, with a correction).** Ad-hoc signing
   produced a new designated requirement on every build, so TCC grants dropped and
   auto-paste failed silently. `build.sh` now signs with `Dev Island Local
   Signing` (§11), `|| true` is gone, and the requirement was verified
   byte-identical across two consecutive rebuilds. The certificate expires in 2036;
   recreating it means re-issuing the Accessibility grant.
   A stable requirement is necessary but not sufficient: the app also has to be
   *granted*, and testing it from a terminal hid that, because a terminal-launched
   process inherits the terminal's grant (§3). First run now prompts properly and
   the grant is verified working.
7. **See-through during a panel switch (fixed by construction, verified).**
   The symptom was the desktop appearing behind the island mid-switch. The window
   is now resized only at the endpoints of a transition, and always to
   `max(old, new)`, so it is never smaller than the shape. A window that is larger
   only ever shows transparent margin around an already-drawn island, which is
   indistinguishable from the island growing.
   Verified by sampling the window bounds every 60 ms through a clipboard→music
   switch: the window held `520 × 320` for the whole animation, then settled to
   `440 × 190`. The same for expand (189 × 32 → 520 × 320) and collapse.
   The earlier attempts all tried to make a per-frame window resize keep up; this
   removes the per-frame resize instead.
   The 8x slowed captures that never reproduced the bug are consistent with this:
   at 8x the window had time to catch up between frames.

8. **Hover cannot detect a drag (resolved, 14 Nov).** `installMonitors` used to
   subscribe to `.mouseMoved` and `.leftMouseDown` only. While a button is held the
   system posts `.leftMouseDragged` instead of `.mouseMoved`, so dragging a file
   toward the notch generated no events at all. The monitor now includes
   `.leftMouseDragged` and `.leftMouseUp`, gated on the drag pasteboard's types, and
   a content drag over the island holds it open through the existing
   `isInteracting`. Verified: a window drag across the notch leaves it closed, a
   file drag opens it. See §5.
9. **Drag-out from a non-activating panel (resolved by spike, 14 Nov).** Confirmed
   working: a spike panel with the island's exact window configuration
   (`.nonactivatingPanel`, `canBecomeKey = true`, `becomesKeyOnlyIfNeeded = true`,
   level `.mainMenu + 3`, copy-only operation) started a drag session and delivered
   its payload into TextEdit — `session ended, operation=1` (`.copy`). The menu bar
   stayed on TextEdit throughout, so the panel never activated the app. Drag-out is
   not a risk; build it.
10. **Global `.leftMouseDragged` during a Finder drag (resolved, 14 Nov).**
    Confirmed working: 1,028 dragged events arrived during Finder file drags with
    `public.file-url` present. No `CGEvent` tap is needed, and neither is its extra
    permission story.
    The standalone spike could not answer this and must not be trusted for it: a
    binary launched from a terminal does not inherit the app's TCC grant and
    receives nothing, which is indistinguishable from Finder swallowing the events.
    `AXIsProcessTrusted`/`CGPreflightListenEventAccess` reported `true` in the
    development shell while the terminal-launched binary still saw no events, and
    synthetic events cannot substitute because `CGEvent`-posted events are filtered
    from global monitors. The `ISLAND_DRAG_PROBE` inside the signed app is the only
    reliable way to ask.
    The real trap was in the gate, not the monitor: see §5 for why `changeCount` is
    not a drag-start signal.

### Accepted rough edges

Deliberate, not overlooked. Each is a cost that was judged smaller than its fix;
any of them can be reversed.

1. **A paused track is invisible while the notch is closed.** The chin is gated on
   `isPlaying`, so pausing collapses the island back to the bare cutout and the
   artwork disappears even though the track is still loaded. Correct for "nothing
   is happening", annoying if you paused to talk to someone. *Fix:* gate on
   `nowPlaying != nil` with a 2–3 minute grace, the way the deleted strip did —
   which is exactly the behaviour the strip was removed for, so this needs a
   decision rather than a patch.
2. **The empty shelf is taller than a one-file shelf.** 128 pt vs 102 pt, because
   the empty state is two lines of text under an icon and one row is a single row.
   Dropping your first file therefore *shrinks* the card by 26 pt. It is the
   correct height in both cases; it just reads as a wobble.
3. **The settle delays are hand-tuned.** `0.6 s` expand, `0.45 s` collapse, chosen
   to land just past the spring's response (`0.36 s` / `0.24 s`) so the shrink
   cannot fire mid-flight. They are constants, not derived from the animation.
4. **The equaliser animates while the island is closed and music is playing** —
   that is the live activity, and it costs roughly 2% CPU for as long as it is on
   screen. Pausing stops it. This is risk 1 in its remaining form.
5. **The window was once sampled at `X = -59` for a frame during a display
   reconfiguration**, where it should be `536`. It self-corrected immediately and
   was never reproduced. The likely cause is `targetScreen()` returning a screen
   with a different frame mid-transition; nothing is guarding against it.

---

## 10. Decisions

### Decided

- **Panel sizes:** `440 × 190` (Music), `520 × 320` (Clipboard & Terminal), `440 × content-height` (Shelf, 102–260).
- **Window sizing:** The window is resized **only at the endpoints** of a transition — up to `max(old, new)` before the shape moves, back to the target after it settles — and never in between. The window is therefore never smaller than the shape, which is what removes the see-through (§2, risk 7). Springs stay critically damped because an overshoot would push the shape past the window.
- **Spotlight trigger:** Removed (`⌘Space` is the precedent); Spotlight avoidance / suppression while `SpotlightState.isOpen` is retained.
- **Music layout:** `440 × 190`, `132 pt` artwork, scrub bar in the right column beside it (§6).
- **Closed-state Spotify poll:** Gate the `1.5 s` AppleScript timer to `expanded` only; rely on notifications while closed.
- **Click behaviour:** Auto-paste is the default (`⌘V` after collapse); `⌥`-click is copy-only. An **Autopaste On / Off** pill in both history headers toggles the default and is persisted. A missing Accessibility grant is surfaced as an actionable notice, not as a silent failure — see §3.
- **Terminal panel click:** Auto-paste with trailing newline stripped so a stray Return cannot execute a pasted command.
- **Signing identity:** Self-signed Code Signing certificate (`Dev Island Local Signing`), not ad-hoc, so TCC Accessibility and Automation grants survive rebuilds.
- **Clipboard capture while closed:** Accepted (`0.4 s` `changeCount` integer compare).
- **Auto-paste is a preference, not a constant.** A pill labelled **Autopaste** with **On** or **Off** in both history headers — named for the setting rather than for the outcome, because "Paste / Copy" read as an action button rather than a state. Persisted; ⌥-click remains per-click copy-only. One setting shown on both panels.
- **Paste confirmation lives in the closed notch, not in the panel.** The panel is gone by the time ⌘V lands, so the acknowledgement has to survive the collapse: the chin widens for ~1 s with ✓ Pasted, or "Copied" for ⌥-click. Toggleable from the clipboard header and off means off — no chin at all. Phase 8.
- **Testing never touches real data.** `ISLAND_DATA_DIR` redirects every store plus the instance lock, and `ISLAND_HISTORY` points the terminal panel at a fixture. The time windows were verified that way; the shell history and `clipboard.json` were confirmed untouched afterwards.
- **History windows are a filter, never retention.** `24h / 7d / 30d / All` per panel, applied to both the list and the chips. Nothing is deleted; a shorter clipboard cap is the separate, safe lever if storage ever needs to shrink.
- **Panel ranking:** Highlight by frecency (`uses × 0.5 ^ (days / 14)`), never filter by frequency. The only deny-list is the terminal panel's manual trivia list (§4); the clipboard panel has none, because any copied text is potentially worth pasting back.
- **Ignore rules are manual:** no auto-learning from paste history.
- **Terminal ranking:** by use count, then recency (file position). No time decay, because the history file carries no timestamps — a decay curve would be invented rather than measured. The list is recency-ordered; the chip strip is usage-ordered.
- **Terminal persistence:** none. The history is re-parsed from `~/.zsh_history` on change rather than cached in `terminal.json`.
- **Clipboard vs terminal overlap — kept, not gated.** The clipboard captures commands as well as text, so a command you copied can appear in both panels. *Gating the clipboard to non-commands was considered and rejected:* it would delete exactly the entries the terminal can never hold — commands copied from docs, Slack or the web that have not been run yet. *Deduplicating against shell history was also rejected:* it hides a command you copied only to share, breaking the clipboard's "everything I copied" contract in a surprising way.
  If the overlap becomes annoying in use, the fix is to record the source app per entry (already read from `frontmostApplication` for the password-manager blocklist) and demote terminal-sourced copies — not to filter by kind.
- **Shelf accepts files only.** Text and links were implemented and then removed:
  the clipboard already captures both automatically and copying is faster than
  dragging, so a shelf row for them was a second place to look for the same
  string. The one thing the clipboard cannot hold as a usable reference is a file.
  Non-file entries are pruned on load, and the drag detector ignores non-file
  drags so the shelf does not open for them. The `ShelfItem` kind enum went with
  them — the model is now `path`, `bookmark`, `added`.
- **Shelf prunes dead references at load**, the way boring.notch validates on
  launch, and rewrites `shelf.json` so they do not come back. Deliberately not on
  every render: a file deleted while the panel is open should not make its row
  vanish under the pointer mid-interaction.
- **Shelf drag-in opens the shelf**, and a cancelled drag restores the previous
  panel. The restore check is deferred 250 ms because item loading is
  asynchronous and the drop flag is not set the instant the button comes up.
- **Shelf storage: references, decided.** Path plus a plain (non-security-scoped)
  bookmark, deduped by resolved path, capped ~30. Copies were rejected: they
  duplicate data silently, need a size cap and cleanup story, and make "remove
  from shelf" ambiguous about whether the real file is affected. Copies would only
  earn their place for files about to be deleted, which is too narrow to design
  around.
- **Shelf click vs drag:** a row is a click *or* a drag, disambiguated by a 3 pt movement threshold in a small `NSView`. The click fires on `mouseUp`, not `mouseDown`, so press-then-drag cannot also trigger the click (§5).
- **Shelf drag operation is copy-only, unconditionally.** A shelf holds references, so dragging out must never move the real file onto another volume. boring.notch makes this a preference; here it is not negotiable.
- **No second collapse flag:** Phase 4 wires the existing `isInteracting` rather than adding an `isStuckWhileDragging`-style flag.
- **Not building:** Pockets, QuickLook integration, thumbnails, shift-click range selection, and shelf copies — reasons per row in §5.

### Open decisions

1. ~~**Default panel on first hover**~~ — Clipboard. Done.
2. ~~**Music as chrome + one panel**~~ — neither. The strip was removed; music
   lives in the closed notch only. Done.

---

## 11. Signing and re-identification (done)

**Status: done.** `Dev Island Local Signing` exists in the login keychain, is
trusted for code signing in the user trust domain, and is valid until 2036.
`build.sh` signs with it and the designated requirement is stable across
rebuilds.

### Installing, so ⌘Space finds it

A `.app` in a source tree is not an Application as far as Spotlight and
LaunchServices are concerned, so it cannot be launched by typing its name.
`build.sh` now moves the signed bundle to `~/Applications/Dev Island.app` and runs
`lsregister -f` on it, which is what makes it appear immediately rather than on the
next metadata pass.

- **Moved, not copied**, and the repo path becomes a symlink to the installed
  bundle. Two real bundles would both be indexed and Spotlight would offer the
  same app twice; the symlink keeps `./DevIsland.app/...` working for scripts and
  tests while exactly one bundle exists.
- **The spaced name matters.** Installed as `DevIsland.app` it indexed as
  "DevIsland" and `open -a "Dev Island"` could not find it at all — the display
  name comes from the file name, not `CFBundleName`.
- **TCC survives the move**, verified: the clipboard panel opens with no "Grant
  Accessibility" notice, because grants key on the designated requirement
  (identifier plus certificate), not on the path.
- Set `ISLAND_NO_INSTALL=1` to build without installing, or `ISLAND_INSTALL_DIR`
  to install somewhere else.

Quit is the status item's Quit, which calls `NSApp.terminate` and so runs
`applicationWillTerminate` → `PlayerService.shutdown()` → the media helper is
terminated. There is deliberately **no login item**: the app runs when asked for.

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

### The plist landmine (resolved)

`Info.plist` originally had **no `NSAppleEventsUsageDescription`**, which is
harmless only while an Automation grant already exists. Because the rename and the
new certificate both reset that grant, the next Spotify call on a clean TCC state
would be the first time the app had to *prompt* — and without the description
string macOS can terminate the app instead of prompting.

Phase 1.5 added it, and it is present in `Info.plist` today:

```xml
<key>NSAppleEventsUsageDescription</key>
<string>Dev Island controls Spotify playback so the notch can show and change the current track.</string>
```

`CFBundleIdentifier` is `dev.island`. Note that the old identifier
(`com.haras.dynamicisland`) is gone from the bundle but may still exist as stale
TCC entries; those are harmless and can be left, or reset with `tccutil reset
AppleEvents dev.island`.

---

## 12. Inspecting a state

Every claim in §1 and §5 was checked against a running app, so the reviewer can
re-check them the same way.

**Environment variables** (read in `IslandController.init`):

| Variable | Effect |
| --- | --- |
| `ISLAND_EXPANDED=1` | Opens the island and sets `model.locksOpen = true`, so it stays open and can be captured. **Pass it through `open --env`** when the test depends on TCC: `open --env ISLAND_EXPANDED=1 --env ISLAND_PANEL=clipboard -a "Dev Island"`. A direct `./DevIsland.app/...` launch inherits the terminal's Accessibility grant and will report permissions the app does not actually have. Under `open --env` the window behaves identically; allow a second longer for the first paint |
| `ISLAND_PANEL=music\|clipboard\|terminal\|shelf` | Selects the panel before first paint |
| `ISLAND_RENDER=<path>` + `ISLAND_RENDER_STATE=expanded\|playing\|wings` + `ISLAND_RENDER_PANEL=…` | Renders a static preview to PNG via `ImageRenderer` |
| `ISLAND_DATA_DIR=<path>` | Sandboxes **every** store and the single-instance lock: clipboard history, shelf, ignore rules, `instance.lock`. Nothing under the real Application Support directory is read or written, which is how the time windows were exercised against invented data without risking real history. Also gives the test instance its own lock file, so it can run beside a real one |
| `ISLAND_MEDIA_PROBE=1` | Logs every now-playing update the helper delivers (title, whether artwork decoded) to stderr |
| `ISLAND_HISTORY=<path>` | Point the terminal panel at a fixture instead of `~/.zsh_history`, so window filters and parsing can be exercised without touching real shell history |
| `ISLAND_DRAG_PROBE=1` | Logs every `.leftMouseDragged` with both gate inputs (`content`, `count`, `base`, `inside`, `types`) to stderr. The only reliable way to inspect drag events — a standalone binary launched from a terminal does not inherit the app's TCC grant and sees nothing |

`locksOpen` is the reason a screenshot session does not collapse under the
pointer; it is checked in `scheduleCollapse()` alongside `isInteracting` (§1).

**Gotchas that waste time:**

- `ImageRenderer` cannot rasterise `ScrollView`, `LazyVStack`, or
  `NSViewRepresentable`, so preview renders show empty lists. Use a live capture
  for anything with rows.
- `screencapture -x -R` fails with "could not create image from rect" while the
  island window is up. Capture the full screen and crop.
- Captures go black when the display sleeps, and **fail outright** when the screen
  is locked: `screencapture -l` returns "could not create image from window" and
  `CGWindowListCopyWindowInfo` reports nonsense bounds (a 0.9-scaled, offset
  rectangle). Check `ioreg -n Root -d1 -a | grep CGSSessionScreenIsLocked` before
  believing any measurement taken during a run. The offscreen `ISLAND_RENDER`
  path still works while locked, which is why the previews were usable then.
- `screencapture` costs ~66–150 ms per frame, so it cannot resolve a 0.24–0.36 s
  animation. Do not try to see a transition that way — the window bounds are the
  thing to measure, not the pixels: sample `CGWindowListCopyWindowInfo` every 60 ms
  and check that the window is never smaller than the island (risk 7).
- `screencapture -l <windowid>` captures a window's whole buffer including
  transparent area, which makes it the fastest way to inspect a panel without
  depending on what is underneath it.
- A second launch while the first is still shutting down exits on the `flock`, and
  the window you then inspect belongs to the *old* process — which is exactly how a
  stale 32 pt window got misdiagnosed as a collapse bug. Sleep 2–3 s after
  `pkill` and confirm `pgrep` is empty before launching.
- The app is single-instance via an exclusive `flock` on
  `~/Library/Application Support/Dev Island/instance.lock`. Kill the old process
  before relaunching, or the new one exits silently:
  `pkill -f "DevIsland.app/Contents/MacOS/DevIsland"`.

---

## 13. Code review (15 Nov)

A full pass over `Sources/` against this plan produced the findings below. Half of
them were already fixed when the document was read, because it was taken before
`8fbfbbd` and `7d13423` — check a finding against the tree before acting on it.

| # | Finding | Status |
| --- | --- | --- |
| 1A | Application Support boilerplate in four places | **done** — `AppSupport.directory()` (`ff2505e`) |
| 1B | Duplicated panel subviews | **pending** — Phase 10, see below |
| 1C | Atomic JSON write duplicated in both stores | **done** — `AtomicJSON.write` (`ff2505e`) |
| 2.1 | `PlaceholderPanel` unreachable since `ExpandedPanel` became exhaustive | **done** — deleted (`674f7e3`) |
| 2.2 | Orphaned doc comment left mid-sentence above `NoticeStrip` | **done** — deleted (`674f7e3`) |
| 2.3 | Five stale references in this file | **done** — `7d13423` |
| 3.1 | Shelf item-count change did not resize the panel | **done** — `8fbfbbd`, with a correction below |
| 3.2 | `observeScreens` hid the panel but left the timers running | **done** — `8fbfbbd` |
| 3.3 | Sorting inside `body`, on every render | **done** — `674f7e3` |

**Correction to 3.1.** The finding said nothing subscribed to `shelf.$items`, and
proposed subscribing in `IslandModel`. `IslandController` was already subscribed
and did resize the window. What was missing was `objectWillChange`: `islandSize`
is read by `IslandRootView` to decide where the shape is heading, so without a
re-publish SwiftUI never re-rendered and the shape stayed at the old height while
the window grew, clipping the new row. The subscription did move into
`IslandModel`, but for that reason. **Anything that changes `islandSize` needs
both** the re-publish and the geometry call — §2.

### 1B — the deferred extraction

Four duplicated views across `ClipboardPanel`, `TerminalPanel` and `ShelfPanel`:

| View | Copies | Notes |
| --- | --- | --- |
| Empty state | 2 | Clipboard and terminal only; both are now *filter-aware*, so the strings have to be parameters, not baked in |
| Frequent chip | 2 | Identical pill: 24 pt tall, radius 7, `0.055` fill, `0.07` stroke, 9 pt icon, 11 pt label |
| History row | 2 | 26 pt, `8/14` padding, hover fill, 10 pt icon at width 13, 12 pt middle-truncated label |
| Section header | 3 | 11 pt semibold, tracking 0.6, `0.3` opacity, 14 pt tall, 8 pt leading |

Deferred rather than skipped because it is ~200 lines of view code whose failure
mode is **subtle spacing drift** — a 1 pt padding difference that no compiler and
no test catches. It wants before/after captures of all three panels, which is more
work than the extraction itself.

Shape, so it does not get re-derived:

```swift
PanelEmptyState(symbol: String, title: String, subtitle: String)
FrequentChip(symbol: String, text: String, monospaced: Bool, help: String, action: () -> Void)
HistoryRow(icon: String, text: String, monospaced: Bool, trailing: () -> Content)
PanelSectionHeader(title: String, trailing: (() -> Content)?)
```

`HistoryRow` needs the trailing `@ViewBuilder` because the rows differ only there:
the clipboard puts a `TimelineView(.everyMinute)` age, the terminal puts `"%d×"`.
