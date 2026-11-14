# Dev Island — multi-panel plan

Status: **Phases 0–5 implemented; Phase 6 proposed.** Phase 0 is *partial* — the
YouTube/Chrome test and the paste-notice check were never run. §1 states facts
verified against the source; rows marked *(Phase 1/2/3/4)* describe the code as it
now stands, not the original commit. §11 records the signing setup that is in
place.

| Phase | State |
| --- | --- |
| 0 — YouTube/Chrome, paste notice | **partial**, untested |
| 1 — panel host | done |
| 1.5 — rename + self-signed signing | done |
| 2 — clipboard panel + auto-paste | done, verified by use |
| 3 — terminal history panel | done |
| 4 — file shelf | **done, verified by use** |
| 5 — music visual upgrade | done |
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
| `expand()` selects `defaultPanel` before flipping `expanded` **(found in Phase 4)** | `Sources/IslandModel.swift:86-90` | Anything wanting a specific panel on expand must select it **after** calling `expand()`; selecting first is silently overwritten. This cost a drop target: the shelf was selected during a drag, `expand()` replaced it with the default panel, and the drop landed on a panel with no drop handler. |
| No SPM, no dependencies — plain `swiftc` | `build.sh` | No GRDB/Realm. Persistence must be `Codable` JSON, capped and debounced. |
| `~/.zsh_history`: ~1,300 lines and growing, **no timestamps**, `\` continuations, non-UTF-8 bytes | measured | Recency must come from file position, not time. The parser must join continuations and decode lossily. `INC_APPEND_HISTORY` is now set in `~/.zshrc`, so the file is written per command rather than on shell exit. `EXTENDED_HISTORY` is still off. |
| `panel.ignoresMouseEvents` centralised in `refreshMousePolicy()` **(Phase 1)** | `Sources/IslandController.swift:244-252` | Policy is `expanded ? false : isPlaying`. During a drag session `mouseMoved` does not fire, so a file dragged at a click-through window never lands: the closed idle window (`notch + 4`, physical cutout only) must stay permanently interactive as `NSDraggingDestination`, while the `249 pt` playing chin stays click-through. Phase 4 depends on this. |
| Hover monitors cover `.mouseMoved`, `.leftMouseDown`, `.leftMouseDragged`, `.leftMouseUp` **(Phase 4)** | `Sources/IslandController.swift` (`installMonitors`, `isCarryingContent`) | A held mouse button posts `.leftMouseDragged`, not `.mouseMoved`, so drag-in needs its own event type or the island never expands. The gate is the drag pasteboard's **types**, not its `changeCount`: measured, the count does not move when a drag starts. The pasteboard is cleared on `.mouseMoved` because AppKit leaves the previous drag's types behind. See §5. |
| Polls only run while expanded **(Phase 1)** | `Sources/IslandController.swift:105-119`, `Sources/IslandModel.swift:137-149` | Both the Spotlight watch and `PlayerService.startPolling()` / `stopPolling()` are driven off `$expanded`. Verified: zero `osascript` spawns while closed. This is the precedent the `PanelProvider` lifecycle follows. |
| Panel level `.mainMenu + 3`, SkyLight space attach | `Sources/FullscreenSupport.swift` | New panels inherit this; no extra work. |
| Window frame tracks the island **(Phase 2/5)** | `Sources/IslandController.swift` (`updateGeometry`, `syncWindow`), `:29` (`pointerCapture`) | The window is resized every animation frame from an `Animatable` size probe, so it never exceeds the shape. Three things are load-bearing: the no-op guard (setting the frame re-lays out the hosting view, which re-runs the probe, which calls straight back — unguarded, it redraws at display rate forever), critically-damped springs (any overshoot moves the whole window, not just the shape), and **main-thread confinement** — SwiftUI's async display link invokes the probe off the main thread, where `NSWindow.setFrame` traps with `EXC_BREAKPOINT`, so frames are coalesced and applied on the main queue. `pointerCapture` separately stops a shrink from collapsing the island out from under a stationary pointer — see §2. |
| Click-to-Spotlight (`openSpotlight()`) | `Sources/IslandView.swift` / `IslandModel.swift` | Removed in Phase 1 (`⌘Space` is the precedent); Spotlight avoidance / suppression while `SpotlightState.isOpen` is retained. |
| 30 ms collapse on pointer exit, with an existing `isInteracting` escape hatch | `Sources/IslandController.swift:390-402` (`scheduleCollapse`), `:40` (`isInteracting`) | Collapse is deferred 30 ms and then re-checks three conditions: `!model.locksOpen`, `!isInteracting`, `!inHotZone(mouseLocation)`. Right-click `NSMenu`s, drag-ins and drag-outs all move the pointer outside `islandRect`, so `isInteracting` is the intended guard — it is **declared and already checked**, but nothing sets it yet. Phase 4 wires it up rather than adding a new flag. |
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

**`pointerCapture` covers the one case frame-tracking alone cannot.** Switching to a shorter panel lifts the island's bottom edge above a stationary pointer, which makes `inHotZone` false and collapses the island out from under the cursor. So `model.$activePanel` snapshots the old `panel.frame` into `pointerCapture` when the pointer is inside it (line 143-146), and `handleMouse` treats that rect as inside until the pointer actually leaves it (line 348-354). It is cleared on expand and when the pointer exits the captured rect. This applies whenever a switch makes the island **shorter**; it costs nothing when it grows.

The `32 pt` physical notch, the panel bar in that band, and padding consume
`~40 pt` of vertical chrome. **Every panel is the same size**:

| Panel | Size (pt) |
| --- | --- |
| Clipboard | 440 × 310 |
| Terminal | 440 × 310 |
| Shelf | 440 × 310 |
| Music | 440 × 310 |

A single size is what removes risk 7 rather than mitigating it: switching panels
cannot resize the window, so there is no frame during which the window and the
shape disagree and the desktop shows through. It also means the icons, the strip
and the panel body never move when switching.

### Navigation

The switcher sits **in the menu-bar band either side of the physical cutout**,
which is otherwise dead screen space the island reserves and never uses. Two
icons left of the notch, two right, in this order:

```
  clipboard  terminal  |  (notch)  |  shelf  music
```

Active at full white, inactive at 0.3. This replaced a bottom nav row, which cost
~22 pt of content height on every panel and put the switcher where the eye is not.

Deliberately **no scroll-to-switch**: a clipboard list needs wheel scrolling,
and a global scroll handler fights it.

### Default panel

**Clipboard.** It is the panel that is useful the instant the island opens — you
open it to get something back, not to look at something. Submenu on the existing
status item (`Sources/App.swift`), persisted in `UserDefaults`. No settings window.

A stored `music` is treated as the old default rather than a choice and migrated
to clipboard, so existing installs get the new behaviour instead of being stuck
on a panel nobody picked.

### Music while another panel is open

**28 pt now-playing strip pinned at the top of every non-music panel**: 20 pt
artwork, marquee title, play/pause button.

The strip is chrome, so it does not sit there forever: it is drawn while
something is playing and for `PlayerService.stripGrace` (120 s) after playback
stops or pauses, then disappears and the list reclaims the space. Verified by
shortening the grace to 8 s: strip present while playing, still present 3 s after
pausing, gone at 12 s.

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
| `ShelfPanel` | File icon, name, parent folder, size; click reveals in Finder; right-click Open / Reveal / Copy Path / Remove |
| Drop | `public.file-url` only; anything else is rejected so the drag animates back rather than being silently swallowed |
| Drag-in | Opens the shelf, not the default panel; a cancelled drag restores the previous panel |
| Drag-out | `NSView` + `NSDraggingSource`, 3 pt threshold, copy-only, icon as the drag preview — **verified by use** |

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

Confirmed working by use: dragging a row out delivers the file to the destination.
The context-menu, ✕-removal and scroll-under-row paths were not separately
reported, so treat those as unverified.

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
| Transport | grey circles | `pause.fill` in a filled 28 pt **white** circle with a dark glyph; plain 13 pt glyphs either side, 16 pt apart |

The player block is centred vertically and its right column is pinned to the
artwork's height (`132 pt`), so the title sits beside the artwork instead of
stretching to the panel's full height and leaving the artwork floating.

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
| 4 | ~~Shelf: drag-in detector, store with bookmarks and load-time pruning, panel, file-only drop, drag-out~~ **done, verified by use** | — |
| 5 | ~~Music visuals: blurred backdrop, 92 pt artwork, white transport circle~~ **done** | — |
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
   `NSView` behind the SwiftUI content. See §5 for the full mechanics.
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
7. **See-through during a panel switch (fixed by construction, needs a
   confirmation in use).** The symptom was the desktop appearing behind the island
   mid-switch. Every panel is now the same size, so switching cannot resize the
   window and there is no frame in which the window and the shape disagree — the
   resize animation that produced it no longer exists. This is why the fix is
   structural rather than a faster animation: the earlier attempts all tried to
   make the resize keep up.
   The expand/collapse animation still resizes, and that path measured clean
   (monotonic, no overshoot, solid black throughout) after the redraw-loop fix.
   It also had to be made main-thread-safe — see §1 — because SwiftUI's async
   renderer invokes the size probe off the main thread and `NSWindow.setFrame`
   traps there.
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

1. **Default panel on first hover** — Music or Clipboard?
2. **Music as chrome + one panel** — confirm the 28 pt now-playing strip is
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
| `ISLAND_EXPANDED=1` | Opens the island and sets `model.locksOpen = true`, so it stays open and can be captured |
| `ISLAND_PANEL=music\|clipboard\|terminal\|shelf` | Selects the panel before first paint |
| `ISLAND_RENDER=1` + `ISLAND_RENDER_STATE=expanded\|playing\|wings` + `ISLAND_RENDER_PANEL=…` | Renders a static preview to PNG via `ImageRenderer` |
| `ISLAND_DRAG_PROBE=1` | Logs every `.leftMouseDragged` with both gate inputs (`content`, `count`, `base`, `inside`, `types`) to stderr. The only reliable way to inspect drag events — a standalone binary launched from a terminal does not inherit the app's TCC grant and sees nothing |

`locksOpen` is the reason a screenshot session does not collapse under the
pointer; it is checked in `scheduleCollapse()` alongside `isInteracting` (§1).

**Gotchas that waste time:**

- `ImageRenderer` cannot rasterise `ScrollView`, `LazyVStack`, or
  `NSViewRepresentable`, so preview renders show empty lists. Use a live capture
  for anything with rows.
- `screencapture -x -R` fails with "could not create image from rect" while the
  island window is up. Capture the full screen and crop.
- Captures go black when the display sleeps or is locked (`CGDisplayIsAsleep=1`).
- `screencapture` costs ~66–150 ms per frame, so it cannot resolve a 0.24–0.36 s
  animation unless a temporary slowdown multiplier is in place. This is why risk 7
  is still unresolved rather than disproved.
- The app is single-instance via an exclusive `flock` on
  `~/Library/Application Support/Dev Island/instance.lock`. Kill the old process
  before relaunching, or the new one exits silently:
  `pkill -f "DevIsland.app/Contents/MacOS/DevIsland"`.
