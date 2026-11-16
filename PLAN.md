# Dev Island — multi-panel plan

Status: **complete, apart from what needs a notched display to confirm.** Phases 0a
and 1–18 are implemented; 0b is the only unrun check (whether *reading* the
pasteboard makes macOS prompt — no prompt has ever appeared, so it is close to
answered by observation), and §15 says exactly which of the newer claims have been
measured and which have not. §1 states facts verified against the source; §13
records the code review; §11 records signing and installation. The accepted rough
edges in §9 are deliberate, not outstanding.

| Phase | State |
| --- | --- |
| 0a — YouTube/Chrome media | **done, verified by use** |
| 0b — macOS pasteboard read prompt | not run; no prompt has ever appeared |
| 1 — panel host | done |
| 1.5 — rename + self-signed signing | done |
| 2 — clipboard panel + auto-paste | done, verified by use |
| 3 — terminal history panel | done |
| 4 — file shelf | **done, verified by use** |
| 5 — music visual upgrade | done |
| 5.5 — strip removed, per-panel sizes, resize rework | done |
| 5.6 — history windows, `EXTENDED_HISTORY`, sandbox | done, verified against invented data |
| 6 — media transport (§7) | done, verified with a browser |
| 7 — browser artwork in a title-less diff | done |
| 8 — paste confirmation | **done, verified** |
| 9 — one music-panel size, aspect-fitted tile | done, verified live |
| 10 — view dedup (review 1B) | **done, pixel-verified** |
| 11–14 — last panel, true black, metrics, icon size | done, confirmed by use |
| 15 — whole-island drop target | **Finder verified; Dock stack unverified** |
| 16 — keyboard selection, for both lists | built; needs a run on the machine |
| 17 — settings panel, clean layout | built, render-verified |
| 18 — merge with the parallel branch (§15) | done |

Goal: turn a single-purpose music notch into a panel host with a clipboard
history panel, a terminal-history panel, a file shelf, a settings panel and a
visual upgrade to the music panel. All of them are built, and media is no longer
Spotify-only: a browser playing YouTube shows its title, channel, position and
thumbnail (§7).

---

## 1. Existing code — verified constraints

These matter because they invalidate some obvious approaches.

**Sources are cited by symbol, not by line.** Line numbers were here first and had
all silently drifted by the time this was reviewed — `islandSize` had moved by 44
lines, `expand()` by more than a hundred. A symbol survives an edit; a line number
does not.

| Fact | Source | Consequence |
| --- | --- | --- |
| `islandSize` derives from `expanded` and `activePanel`, and from `shelf.items` for the shelf **(Phase 1, reworked Phase 5.5)** | `Sources/IslandModel.swift` (`islandSize`) | Size changes no longer rely on snapping the frame in the same turn. The window is grown to `max(old, new)` **before** the shape animates and settles afterwards, driven synchronously from the model's setters, so `islandRect` / `inHotZone` are never wrong for a frame — see §2. Two consequences: `expanded` / `activePanel` must go through their `didSet` rather than a Combine sink, and anything else that changes `islandSize` must re-publish — which is why `IslandModel` subscribes to `shelf.$items`. |
| `expand()` selects `defaultPanel` before flipping `expanded` **(found in Phase 4)** | `Sources/IslandModel.swift` (`expand()`) | Anything wanting a specific panel on expand must select it **after** calling `expand()`; selecting first is silently overwritten. This cost a drop target: the shelf was selected during a drag, `expand()` replaced it with the default panel, and the drop landed on a panel with no drop handler. |
| No SPM, no dependencies — plain `swiftc` | `build.sh` | No GRDB/Realm. Persistence must be `Codable` JSON, capped and debounced. |
| `~/.zsh_history`: ~1,300 lines and growing, **no timestamps**, `\` continuations, non-UTF-8 bytes | measured | Recency must come from file position, not time. The parser must join continuations and decode lossily. `INC_APPEND_HISTORY` is now set in `~/.zshrc`, so the file is written per command rather than on shell exit. `EXTENDED_HISTORY` is still off. |
| `panel.ignoresMouseEvents` centralised in `refreshMousePolicy()` **(Phase 1)** | `Sources/IslandController.swift` (`refreshMousePolicy`) | Policy is `expanded ? false : isPlaying`. During a drag session `mouseMoved` does not fire, so a file dragged at a click-through window never lands: the closed idle window (`notch + 4`, physical cutout only) must stay interactive as an `NSDraggingDestination`, while the `249 pt` playing chin stays click-through because it covers live menu bar. |
| Hover monitors cover `.mouseMoved`, `.leftMouseDown`, `.leftMouseDragged`, `.leftMouseUp` **(Phase 4)** | `Sources/IslandController.swift` (`installMonitors`, `isCarryingContent`) | A held mouse button posts `.leftMouseDragged`, not `.mouseMoved`, so drag-in needs its own event type or the island never expands. The gate is the drag pasteboard's **types**, not its `changeCount`: measured, the count does not move when a drag starts. The pasteboard is cleared on `.mouseMoved` because AppKit leaves the previous drag's types behind. See §5. |
| Polls only run while expanded **(Phase 1)** | `Sources/IslandController.swift` (`$expanded` sink), `Sources/IslandModel.swift` (`startPolling` / `stopPolling`) | Both the Spotlight watch and `PlayerService.startPolling()` / `stopPolling()` are driven off `$expanded`. Verified: zero `osascript` spawns while closed. This is the precedent the `PanelProvider` lifecycle follows. |
| Panel level `.mainMenu + 3`, SkyLight space attach | `Sources/FullscreenSupport.swift` | New panels inherit this; no extra work. |
| Window frame tracks the island **(Phase 2/5)** | `Sources/IslandController.swift` (`updateGeometry`, `scheduleSettle`, `applyWindowSize`, `onGeometryChange`), `IslandView.swift` (`IslandRootView`) | The window is resized **twice per transition** — up to `max(old, new)` before the shape moves, and back to the target after it settles — and never in between. Three things are load-bearing: the window must never be smaller than the shape (that is the whole fix for risk 7), the content must be laid out at the target size rather than the animating one (otherwise every frame reflows text, which was the jank), and `onGeometryChange` must fire **synchronously** from the model setters, before SwiftUI's first frame. `pointerCapture` separately stops a shrink from collapsing the island out from under a stationary pointer — see §2. |
| Click-to-Spotlight (`openSpotlight()`) | `Sources/IslandView.swift` / `IslandModel.swift` | Removed in Phase 1 (`⌘Space` is the precedent); Spotlight avoidance / suppression while `SpotlightState.isOpen` is retained. |
| 30 ms collapse on pointer exit, with an existing `isInteracting` escape hatch | `Sources/IslandController.swift` (`scheduleCollapse`), `Sources/IslandModel.swift` (`isInteracting`) | Collapse is deferred 30 ms and then re-checks three conditions: `!model.locksOpen`, `!isInteracting`, `!inHotZone(mouseLocation)`. Right-click `NSMenu`s, drag-ins and drag-outs all move the pointer outside `islandRect`, so `isInteracting` is the guard. It is set by the drag path in `IslandController` and by `ShelfRowInput` while a context menu or drag-out is tracking — no second flag. |
| `IslandPanel` overrides `canBecomeKey = true` **(Phase 2)** | `Sources/IslandController.swift` (`IslandPanel`) | `becomesKeyOnlyIfNeeded` is now `true`, so a click cannot take key status and swallow the synthetic `⌘V`. Auto-paste verified working by clicking a row and pasting into an editor. |

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

The physical notch (32 pt on the first machine, 37.5 on the second), the panel bar
in that band, and padding consume vertical chrome. Sizes differ by panel:

| Panel | Size (pt) | Why |
| --- | --- | --- |
| Clipboard | 520 × 320 | wide rows: text, source and age on one line; FREQUENT chips stop wrapping |
| Terminal | 520 × 320 | long commands stop truncating |
| Shelf | 440 × 106–260 | **height follows the file count**; 106 with one file on a 32 pt notch, capped at 260 before it scrolls |
| Music | 520 × (notch + 156) | 188 on a 32 pt notch, 193.5 on 37.5: the artwork plus the panel padding above and below; the tile follows the image's aspect so nothing is cropped (§6) |
| Settings | 520 × (notch + 233) | six 34 pt rows with a 1 pt gap between them (§15) |

Clipboard and terminal are deliberately identical, so switching between the two
most-used panels moves nothing at all.

**Fixed heights were the second pass's main layout bug.** The music panel was a
constant 190, tuned on a 32 pt notch; on a 37.5 pt notch the band took 5.5 pt more
of it and the padding under the artwork fell to 9 pt, against 13 at the sides.
Every height that holds content under the band is now `notchHeight + …`, computed
in `IslandModel.islandSize`. The list panels stay a fixed 320 because their lists
scroll, so a taller band only costs a row of visible history.

The shelf's height follows its contents — see §5. It is
`notchHeight + 44 + 31·items − 1` (the 12 pt padding above and below, the 14 pt
header and the 6 pt gap under it, then 30 pt rows with a 1 pt gap between them),
capped at 260. A fixed 260 reserved room for six rows even when one file was
dropped, which left a mostly empty card hanging under the notch.

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
icons left of the notch, three right, in this order:

```
  clipboard  terminal  |  (notch)  |  shelf  music  settings
```

Active at full white, inactive at 0.3. This replaced a bottom nav row, which cost
~22 pt of content height on every panel and put the switcher where the eye is not.

The icons are **anchored to the cutout**, not centred in the side band. Panels
differ in width, so centring would slide all five icons sideways on every switch.
The band is measured from `activePanel.preferredSize`, not from the window, so the
icons stay put even while the window is still the larger of the two sizes.

**Keyboard shortcuts**, because the pointer is often nowhere near the notch:
`⌃⌥↓` opens the island on its last list, `⌥1`–`⌥5` jump straight to a panel in
display order, and `⌃⌘V` / `⌥⇧⌘T` open straight onto a history list (§3).
`⌘1`–`⌘5` is what the hand reaches for and what the system takes first — ⌘-number
and ⌃-number are claimed by tab switching and Spaces before a Carbon hotkey is
consulted, so both the original `⌥⌘1`–`⌥⌘4` set and the later `⌘`-number attempt
never reliably arrived. Plain `⌥` is unclaimed. The open key keeps a second
modifier because, unlike the panel keys, it is registered for the whole process — a
bare `⌥↓` would take next-paragraph away from every text editor all day.

Carbon `RegisterEventHotKey`, not an `NSEvent` monitor — a global key monitor needs
Accessibility and the island never becomes the active app. **Three registration
groups**, each alive only while it can mean something:

| Group | Lifetime | Contents |
| --- | --- | --- |
| always | the process | `⌃⌥↓`; the clipboard shortcut when it is on; `⌥⇧⌘T` |
| panel | while expanded | `⌥1`–`⌥5` |
| mode | while expanded | `←`, `→`, `↑`, `↓`, `↩`, `⌤`, `⎋` |

One Carbon handler serves all three for the process lifetime, and `Slot` is a single
raw-value namespace so a hotkey id identifies exactly one chord — the merge in §15
had to renumber it by hand, because two branches had inserted into it at different
offsets, and §16 renumbered it again when the cycle chords went.

The mode group is the only one whose keys carry no modifier, and the island being up
is what makes that affordable: they are installed from `$expanded` with no
`receive(on:)`, so they are gone the moment the window starts closing, and
`HotKeys.uninstall()` clears them as well in case the subscription ever stops firing.

The bound used to be a separate "keyboard mode" flag, on the theory that a hovered
island might be a cursor parked near the notch while somebody typed elsewhere.
`inHotZone` is `islandRect.insetBy(dx: -8, dy: -4)` — the pointer has to be *on the
island* — so a hover is a pointing gesture, and the theory was wrong. Two entry
conditions for one behaviour was the inconsistency §16 set out to remove, so the flag
went.

Two chords were here and are not any more, because both were worse than they looked:
`⌃⌥←/→` for cycling (three keys for an action the arrows now do, and it had to be
overloaded — the same chord meant "cycle" or "move the row" depending on a mode the
user could not see) and `⌥Tab`/`⌥⇧Tab` (Option-Tab taken from every app while the
island was open). Panels are reachable by number at any time, or by arrow.

**Measured, macOS 26: registration success is not evidence of availability.**
`RegisterEventHotKey` returns `noErr` and a usable reference for a chord another
process already holds — `⌃⌥↓` registered while a second copy of this app held it, and
the same chord registered twice inside one process. It returns `noErr` for chords the
system itself owns: `⌘Space` (Spotlight), `⌃↑` (Mission Control) and `⌘⇥` (the app
switcher). The return value therefore cannot be used to tell someone their shortcut
is taken, because it never varies.

**What that does not establish.** Nothing above says what happens at delivery, or
which process receives an event when two have claimed the same chord. The probe was a
command-line tool with no `NSApplication`, and it received no hotkey at all —
including a control chord nothing had claimed — so it measured nothing about delivery.
*"A taken chord fails at delivery"* and *"a passive `CGEventTap` would make the key
work"* are hypotheses, not findings.

**Consequence: no "shortcut taken" UI.** A warning keyed off registration status could
never fire, which is why the status menu has none and why one should not be added
later. Nor has the failure it was meant to report been observed here: the one occasion
this key appeared dead, the cause was `⌥↓` pressed without `⌃`. What remains is a
rebind, so the open key can be moved without editing `Sources/HotKeys.swift` — a real
feature with a real reason, parked rather than shipped because it was prototyped
alongside the warning and should not arrive as its leftover. A `CGEventTap` would
change how the key is captured rather than what is said about it, and is untested
here.

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

**Last used, by default.** Hover reopens on whichever panel was showing when the
island closed — after dropping a file on the shelf, the next hover shows the shelf,
where it used to snap back to Clipboard. That was the first thing reported on the
second machine. `activePanel` is persisted (`lastPanel`) so it also survives a
relaunch; previews do not write it (`PreviewMode.active`, which until then was set
but read by nothing).

A fixed default is still available — **Default Panel** on the status item, or
*Opens on* in Settings — and **Clipboard** remains the fallback when nothing is
stored: it is the panel that is useful the instant the island opens. A stored
`music` default is still migrated to clipboard, as before.

Two things never become the panel hover reopens on, because both are detours rather
than choices: **Settings** (closing on it returns to the last content panel) and the
**keyboard selection** (it puts back the panel it replaced, unless a different
panel was picked while it was on). `PanelID.contentPanels` is the list for both;
`allCases` — which includes Settings — is what the number keys index, because that
is what makes `⌥5` reach the gear.

### Music while another panel is open

**The closed island shows the track in a "chin": the cutout widens by
`2 * (height - 12) + 20` while music plays**, with 20 pt artwork on one side and a
three-bar waveform on the other.

macOS also draws its own now-playing live activity further along the menu bar, so
both are visible. That was first treated as duplication and the chin was deleted —
but the system's is in the wrong place (it is not the notch) and ours is the only
one that can sit in the cutout's own band. The real problem was cost, and that
turned out to be a choice rather than a property:

| Implementation | Cost |
| --- | --- |
| SwiftUI `repeatForever` implicit animation | **9.0%** of a core |
| `TimelineView` at 8 fps | 3.8% |
| **Core Animation (`CABasicAnimation` on CALayers)** | **0.17%** |

The first two repaint the island in-process every frame. Core Animation commits the
animation to the window server, which interpolates it from then on, so the app is not
woken per frame — which is exactly how the system's own indicator is cheap.

No strip, no pause-grace and no chin state beyond `isPlaying`.

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

### Paste confirmation — done

Auto-paste was invisible: the panel collapses, ⌘V fires, and the only evidence is
text appearing in an app you were already looking at. ⌥-click looked identical, so
"did that do anything?" had no answer on screen.

The acknowledgement is a **toast below the island**, shown for 1.2 s:

| What happened | Message |
| --- | --- |
| Auto-paste | ✓ `Auto-pasted` |
| ⌥-click, or autopaste off, or no grant | `Copied to clipboard` |

A sentence rather than a tick, because that *is* the question — a glyph cannot say
whether it pasted or only copied. "Copied to clipboard" is not a fallback style: with
the grant missing the keystroke is dropped, so claiming a paste would be a lie.

**Why below the island and not in the chin.** The first design put the tick in the
chin. The chin is only ~32 pt either side of the 185 pt camera cutout — enough for
20 pt artwork and three bars, nowhere near enough for words. So the *window* grows
downwards for the duration while the shape stays the island's size:
`IslandModel.windowSize` is what the controller sizes to, `islandSize` still drives
the shape. Transparent band, click-through while it is up.

Always shown. A toggle existed for it in the header for one round and was removed:
an acknowledgement you have to switch on is one you have to remember exists.

### Keyboard selection — both lists

Getting something back used to take the pointer: hover the notch, switch to the
clipboard if it was not the last panel, click. The keyboard selection is that path,
modelled on Windows' ⊞V:

| Key | Does |
| --- | --- |
| `⌃⌥↓` | Opens the island on the last list with its first row selected; closes it when it is already up |
| `⌃⌘V` | Opens on the clipboard, first row selected |
| `⌥⇧⌘T` | Opens on the terminal list, first row selected |
| `←` / `→` | Step between the four content panels |
| `↑` / `↓` | The panel's own: the highlighted row, or the volume on Music |
| `⌥1`–`⌥5` | Jump to a panel, in display order |
| `↩`, keypad Enter | The panel's own: paste, open the file, play/pause |
| `⎋`, a click elsewhere, switching apps | Close |

- **It is not a mode.** The island is keyboard-driven whenever it is open, and the
  keys are registered on `expanded`. A separate flag existed for one round on the
  theory that a hover might be a cursor parked near the notch while somebody typed
  elsewhere; `inHotZone` is the island plus 8 pt, so the theory was wrong.
- **It is not clipboard-specific.** `listSelection` names a panel and a row, and
  `PanelKeyboard` has one conformance per panel, so the terminal list and the shelf
  are driven by the same machinery with no second registration set.
- **The selection is a row, not a mode.** Entering with nothing selected draws no
  highlight; the first `↑`/`↓` creates it. In the old model the selection *was* the
  mode, so an empty list and a panel with no rows both ended it.
- **The selection is an id, not an index.** The lists change under it — a new copy
  arrives at row 0, zsh appends a command, a file is dragged off the shelf — and an
  index silently moves the highlight onto a different row while the user is not
  looking. The index is derived where one is needed; the id is `""` for an empty
  list, which no real id can be.
- **Each panel owns its own paste path.** `PanelKeyboard.activate` is implemented
  per panel: a clipboard row bumps its frecency, a command must not land in clipboard
  history, a shelf row opens.
- **Focus never moves**, for the same reason clicks work (*Focus*, below): Carbon
  hot keys are delivered without activating the app, so the paste lands in the app
  that was in front.
- **`↩` and `⎋` are global while registered** — unmodified keys, taken from every
  app. So they are registered only while `listSelection` is non-nil, from a
  synchronous sink rather than a next-turn one, and **every** exit ends it: a paste,
  a copy, `⎋`, any collapse, an outside click, a panel that is not a list, and
  `didActivateApplicationNotification` (⌘Tab — the same notification that catches
  Spotlight). Risk 13 is what happens if one is ever missed. The bare arrows an
  earlier design also took are gone: row movement rides the panel group instead.
- **The pointer being elsewhere is the normal case**, so `scheduleCollapse` ignores
  pointer exit while the selection is on — and `pinnedOpen` guards the same timer, so
  neither relies on the order of calls inside `handleMouse` (§15).
- **The shortcut is a preset, not a recorder**: `⇧⌘V`, `⌥⌘V`, `⌃⌘V` or off, on the
  status item and in Settings. Each takes over one shortcut elsewhere, which a menu
  cannot hide: `⇧⌘V` is Paste and Match Style in Chrome, Slack, Docs and Notion;
  `⌥⌘V` is Finder's Move Item Here; `⌃⌘V` is the least-used of the three, and is
  the default. Nothing is shown for a failed registration, because registration does
  not fail in a way that can be detected — see §2, *Measured*.

**Inferred, untested**: that a taken chord is what "the shortcut does nothing"
would look like. It has never been reproduced here; the one report was `⌥↓` pressed
without `⌃`.

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
overlaps live menu-bar space and stays click-through (`ignoresMouseEvents = true`);
drag-in still works because the drag detector expands the island before the pointer
reaches it.

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

### Dock stacks — **unverified**

Dragging a file out of the Dock's Downloads stack did nothing; from Finder it
worked. A listen-only probe outside the app — a global monitor, and a 20 Hz poll of
the drag pasteboard and of the window under the pointer — showed the two drags are
the same from outside:

| | Finder | Dock stack |
| --- | --- | --- |
| Global `.leftMouseDragged` delivered | yes | **yes** — 31 to 130 per drag |
| Drag pasteboard | `public.file-url`, … | `public.file-url`, `NSFilenamesPboardType`, `com.apple.finder.node`, `Apple URL pasteboard type`, `CorePasteboardFlavorType 0x6675726C`, two `dyn.` types |

So detection was never the problem — although most of the test drags were released
42–88 pt below the top edge, short of the old hot zone, which the 100 pt reach now
covers. (One press on the Dock produced 349 dragged events and no pasteboard write
at all: almost certainly the stack's own tile being dragged, not a file.)

That leaves the drop. It has three layers now, because which one the Dock trips is
not known:

1. **The operation.** SwiftUI's `onDrop` always proposes a copy, and a source that
   does not offer one gets the no-entry cursor. `FileDropView` reads
   `draggingSourceOperationMask` and takes the first of **copy, link, generic** —
   and refuses a drag that offers nothing but move. Nothing is copied or moved
   whichever it is, because the shelf only records a reference, and advertising a
   move the shelf cannot perform would invite the source to delete or relocate the
   original.
2. **When the data is read.** The first AppKit version read the file URLs in
   `draggingEntered` to decide whether to accept. Finder supplies them at once; a
   source that supplies them only once the drag ends answers with nothing, and the
   drop is refused before it can happen. It still failed from the Dock, so the
   decision now uses the pasteboard's **types** alone, and the URLs are read in
   `performDragOperation`, falling back to `NSFilenamesPboardType`.
3. **A safety net that needs no drop at all.** The hover monitor sees every drag,
   and the drag pasteboard still holds the files after the button comes up. If a
   file is released over the open shelf and no drop has arrived 250 ms later,
   `restorePanelIfDragWasCancelled` reads the files from the drag pasteboard
   itself. `awaitingReleasedFiles` holds the stale-pasteboard clear (*The drag
   detector*, above) off until then, and a press that began on the island — a shelf
   row being dragged out — is excluded, as is any drag `FileDropView` refused. The
   cost, if this is the path that fires, is cosmetic: the source animates the drag
   back while the file lands anyway.

**Why the drop view is not hidden by SwiftUI.** Measured: an `NSHostingView`
registers no drag types of its own; `onDrop` adds a hidden
`_PlatformDraggingDestinationView` registered for `public.data` / `public.item`
over its region. With no `onDrop` inside the island, nothing in the host claims a
drag, so drags fall through to `FileDropView` behind it.

**To verify:** run with `ISLAND_DRAG_PROBE=1 … 2> drag.log` and drag from the
Downloads stack. The log names the path that took the file — `drop target entered
mask=… chosen=…`, `drop performed files=… readTook=…`, or `no drop arrived; safety
net read N file(s)` — and an unexpected mask would show there too.

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
stretching to the panel's full height and leaving the artwork floating. The height
is `190`: 132 pt of artwork plus scrub, times and a 28 pt transport row needs ~150 pt
of content, and the original 310 was mostly empty. (It was `440 × 190` until the
music panel became one width for every source — see below.)

### One size, aspect-fitted tile

The panel is **520 × 190 for everything** — the same width the list panels use —
and only the artwork tile changes shape:

| Artwork | Tile |
| --- | --- |
| Square (aspect ≤ 1.2) — album art | 132 × 132 |
| Wide (aspect > 1.2) — a video frame | height 132, width `132 × aspect`, capped at 236 |

A two-layout version was built first — 440 for square art, 520 for wide — and then
removed. It looked clever and behaved badly: **YouTube publishes a 16:9 thumbnail
for every video, including music videos**, so a music video and a lecture pulled
the same lever, and the island changed width every time the track changed. Watching
it move on each track change is what killed it. One panel size, always; the window
now never depends on what is playing.

The image, not the source, still decides the *tile*: album art is square and a frame
is not, and a square cover in a wide box would lose ~45% of itself. That is the only
thing the artwork's shape controls.

Worth writing down, because it makes "detect a music video" a non-problem: a YouTube
music video's thumbnail is a 16:9 composite with the album art on a colour field.
There is nothing to classify — that *is* the artwork, and showing it whole is the
correct outcome.

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

### Artwork arriving after the metadata — fixed

The thumbnail can arrive as its **own** update, not with the title. The adapter
sends the metadata once and then diffs, and a diff carrying only `artworkData` has
no `title` — so an earlier `decode` that required one discarded it, which is why a
browser showed the title over the music-note placeholder. The same path carried
play/pause and position, so a paused video could keep showing as playing.

`MediaStreamDecoder` now treats a title-less payload as a **patch** applied to the
track already on screen. Thirteen assertions cover it, including that a full
payload for a *different* item does not inherit the previous track's artwork.

**Placeholder glyph — dropped, not deferred.** An idea to draw a video/play glyph
instead of a music note for browser sessions. It only applies to a session that
publishes no artwork at all, which no browser has been seen to do — YouTube always
produces a thumbnail — so it would be code for a case that does not occur. If one
ever shows up with the gradient placeholder, that is the moment to revisit it.

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
  outlive it. `pkill -f mediaremote-adapter.pl` at startup, plus an explicit stop on
  clean quit. Matched on the script's **name**, not its path: the repo's
  `DevIsland.app` is a symlink to `~/Applications`, so a path-keyed sweep left one
  helper alive per launch method — observed, two perl processes streaming at once.

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
| 0b | Does *reading* the pasteboard make **macOS** raise a permission prompt? System behaviour, not ours — the in-app tick is Phase 8 and unrelated | not run; no prompt has ever appeared despite a read on every copy, so this is close to answered |
| 1 | ~~Panel shell: `PanelID`, provider protocol, registry, window resizing, icon nav, default panel~~ **done** | — |
| 1.5 | ~~Rename to `dev.island` + `NSAppleEventsUsageDescription`; self-signed cert; `build.sh` signing; verify grants survive a rebuild~~ **done** | — |
| 2 | ~~Clipboard provider + frequent strip + `AccessibilityPaster`~~ **done** | — |
| 3 | ~~Terminal provider + ignore rules + redaction~~ **done** | — |
| 4 | ~~Shelf: drag-in detector, store with bookmarks and load-time pruning, panel, file-only drop, drag-out~~ **done, verified by use** | — |
| 5 | ~~Music visuals: black glass, 132 pt artwork, white transport circle~~ **done** | — |
| 5.5 | ~~Remove the now-playing strip, per-panel sizes, window resized at endpoints only~~ **done** | — |
| 5.6 | ~~`24h / 7d / 30d / All` windows on both history panels; `EXTENDED_HISTORY`; `ISLAND_DATA_DIR` sandbox~~ **done, verified against invented data** | — |
| 6 | ~~Media transport: vendored `mediaremote-adapter` built from source, streamed through `MediaStream`~~ **done and verified with a real browser session** | — |
| 7 | ~~Artwork arriving in a title-less diff was dropped~~ **done** — patches now applied; browser thumbnails work | — |
| 8 | ~~Paste confirmation: a toast under the island saying what the click did~~ **done, verified by use** | — |
| 9 | ~~One music-panel size; the tile follows the artwork's aspect so a thumbnail is not cropped~~ **done, verified with a live session** | — |
| 10 | ~~View dedup: `PanelEmptyState`, `FrequentChip`, `HistoryRow`, `PanelSectionHeader`~~ **done, pixel-verified** (§13) | — |
| 11 | ~~Reopen on the last panel; Default Panel gains *Last Used*~~ **done** | — |
| 12 | ~~True-black surface; the flared top corners removed~~ **done, confirmed by use** | — |
| 13 | ~~`IslandMetrics`: one 12 pt padding, concentric corners, notch-following heights, symmetric chin, larger transport~~ **done, pixel-measured, confirmed by use** | — |
| 14 | ~~Switcher icons at menu-bar size (14 pt medium)~~ **done, measured** | — |
| 15 | ~~100 pt drag reach; `FileDropView` over the whole island; the Dock-stack layers and safety net~~ | **Finder works; Dock stack unverified** (§5) |
| 16 | ~~`⌃⌘V` keyboard selection; shortcut presets; the same machinery for the terminal list~~ | built; needs a run on the machine |
| 17 | ~~Settings panel; optional clean layout~~ **built, render-verified** | confirm in use |
| 18 | ~~Merge and reconcile: one `HistoryPanel` for both lists, one collapse guard, one safe open path~~ **done — §15** | — |

Phases 1–5.6 are complete. The panel shell did turn each feature into a provider
plus a view: the clipboard and terminal panels each landed without touching the
window controller.

Two prerequisites now live outside the repo, both in `~/.zshrc`:
`setopt INC_APPEND_HISTORY` (without it zsh only flushes history on shell exit, so
the panel shows stale commands and raises a notice strip) and
`setopt EXTENDED_HISTORY` (without it there is no time to filter on — see §2).

---

## 9. Risks

1. **Independent redraw drivers — one was expensive; now it is not.** Measured
   with CPU-time deltas rather than `ps %cpu` (a lifetime average, which hid this
   for days), with music playing and the island closed: **9.0%** of a core with the
   chin's bars on a SwiftUI `repeatForever` animation, 3.8% on an 8 fps
   `TimelineView`, **0.17%** on Core Animation. The first two repaint in-process
   every frame; CA hands the animation to the window server.
   What remains: the marquee (only inside `MusicPanel`, only while expanded), the
   progress bar (1 Hz), and the history ages (1/min). Expanded costs 0.9%, closed
   and idle 0.1%.

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
   Distinct from the **in-app** toast in §3, which is ours and is now in place —
   that one is a deliberate choice; this one is OS behaviour we do not control.
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
   switch: the window held `520 × 320` for the whole animation, then settled to the
   music panel's size (`440 × 190` at the time, since music was narrower then; it is
   `520 × 190` now, so that particular switch no longer resizes at all). The same for
   expand (189 × 32 → 520 × 320) and collapse.
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
11. **A move-only drag cannot be taken (accepted).** The shelf records a reference,
    so a `.move` it accepted would be a promise it cannot keep, and Finder would be
    entitled to relocate the file. Such a drag is refused instead (§5). Every real
    source offers copy or link as well, so the cost is theoretical.
12. **A bare-`↩` lifetime (bounded).** While the keyboard selection is on, `↩` and
    `⎋` do not reach the frontmost app. That is the same trade Windows makes for
    ⊞V, and it is affordable only because every exit unregisters them — which is
    one place (`endKeyboardSelection`), reached by paste, copy, escape, collapse,
    outside click, app switch and a panel with no list. If that ever gains a second
    owner, this becomes a bug that steals Return from every app.
13. **Merging a parallel branch over shared raw values (resolved, 15 Nov).** `Slot`
    is one raw-value namespace for all three registration groups, and two branches
    had inserted into it at different offsets, so a textual resolution would have
    produced duplicate hotkey ids. Swift rejects duplicate raw values, so it fails
    loudly, but the merge renumbered the whole enum by hand (§15).

### Accepted rough edges

Deliberate, not overlooked. Each is a cost that was judged smaller than its fix;
any of them can be reversed.

1. **The empty shelf is taller than a one-file shelf.** 128 pt vs 102 pt, because
   the empty state is two lines of text under an icon and one row is a single row.
   Dropping your first file therefore *shrinks* the card by 26 pt. It is the
   correct height in both cases; it just reads as a wobble.
2. **The settle delays are hand-tuned.** `0.6 s` expand, `0.45 s` collapse, chosen
   to land just past the spring's response (`0.36 s` / `0.24 s`) so the shrink
   cannot fire mid-flight. They are constants, not derived from the animation.
3. **The window was once sampled at `X = -59` for a frame during a display
   reconfiguration**, where it should be `536`. It self-corrected immediately and
   was never reproduced. The likely cause is `targetScreen()` returning a screen
   with a different frame mid-transition; nothing is guarding against it.

---

## 10. Decisions

### Decided

- **Panel sizes:** `520 × 190` (Music), `520 × 320` (Clipboard & Terminal), `440 × content-height` (Shelf, 102–260).
- **Window sizing:** The window is resized **only at the endpoints** of a transition — up to `max(old, new)` before the shape moves, back to the target after it settles — and never in between. The window is therefore never smaller than the shape, which is what removes the see-through (§2, risk 7). Springs stay critically damped because an overshoot would push the shape past the window.
- **Spotlight trigger:** Removed (`⌘Space` is the precedent); Spotlight avoidance / suppression while `SpotlightState.isOpen` is retained.
- **Music layout:** `520 × 190` — one size for every source — `132 pt` artwork with an aspect-fitted tile, scrub bar in the right column beside it (§6).
- **Closed-state Spotify poll:** Gate the `1.5 s` AppleScript timer to `expanded` only; rely on notifications while closed.
- **Click behaviour:** Auto-paste is the default (`⌘V` after collapse); `⌥`-click is copy-only, per click. An **Autopaste** pill reading **On** / **Off** in both history headers toggles the default and is persisted — named for the setting rather than the outcome, because "Paste / Copy" read as an action button rather than a state. A missing Accessibility grant is surfaced as an actionable notice, not as a silent failure — see §3.
- **Terminal panel click:** Auto-paste with trailing newline stripped so a stray Return cannot execute a pasted command.
- **Signing identity:** Self-signed Code Signing certificate (`Dev Island Local Signing`), not ad-hoc, so TCC Accessibility and Automation grants survive rebuilds.
- **Clipboard capture while closed:** Accepted (`0.4 s` `changeCount` integer compare).
- **Paste confirmation is a toast under the island, not a tick in the chin.** The panel is gone by the time ⌘V lands, so the acknowledgement has to survive the collapse. It says what happened — `Auto-pasted` or `Copied to clipboard` — because that is the question, and the chin's two 32 pt wings beside the cutout cannot hold a sentence. Always shown; a toggle for it was tried and removed.
- **Testing never touches real data.** `ISLAND_DATA_DIR` redirects every store plus the instance lock, and `ISLAND_HISTORY` points the terminal panel at a fixture. The time windows were verified that way; the shell history and `clipboard.json` were confirmed untouched afterwards.
- **History windows are a filter, never retention.** `24h / 7d / 30d / All` per panel, applied to both the list and the chips. Nothing is deleted; a shorter clipboard cap is the separate, safe lever if storage ever needs to shrink.
- **Panel ranking:** Highlight by frecency (`uses × 0.5 ^ (days / 14)`), never filter by frequency. The only deny-list is the terminal panel's manual trivia list (§4); the clipboard panel has none, because any copied text is potentially worth pasting back.
- **Ignore rules are manual:** no auto-learning from paste history.
- **Terminal ranking:** by use count, then recency (file position). No time decay, because the history file carries no timestamps — a decay curve would be invented rather than measured. The list is recency-ordered; the chip strip is usage-ordered.
- **Terminal persistence:** none. The history is re-parsed from `~/.zsh_history` on change rather than cached in `terminal.json`.
- **Clipboard vs terminal overlap — kept, not gated.** The clipboard captures commands as well as text, so a command you copied can appear in both panels. *Gating the clipboard to non-commands was considered and rejected:* it would delete exactly the entries the terminal can never hold — commands copied from docs, Slack or the web that have not been run yet. *Deduplicating against shell history was also rejected:* it hides a command you copied only to share, breaking the clipboard's "everything I copied" contract in a surprising way.
  If the overlap becomes annoying in use, the fix is to record the source app per entry (already read from `frontmostApplication` for the password-manager blocklist) and demote terminal-sourced copies — not to filter by kind.
- **Shelf stores references, not copies.** Path plus a plain (non-security-scoped)
  bookmark, deduped by resolved path, capped at 30. Both reference implementations
  do the same, and it is what the shelf is *for*: a staging area where removing an
  item never touches the real file. Copying into Application Support was rejected —
  it duplicates data silently, needs its own size cap and cleanup, and makes
  "remove from shelf" ambiguous about whether the real file is affected (§5).
- **Default panel is Clipboard.** It is the panel that is useful the instant the
  island opens — you open it to get something back, not to look at something.
  Persisted, with a stored `music` migrated because that was the old default rather
  than a choice (§2).
- **Music is a panel, and the closed notch carries it.** A now-playing strip on
  every other panel was built and removed: it was chrome that stayed on screen and
  duplicated what the notch already showed. Music keeps its own full panel, and
  while the island is closed the chin beside the cutout shows artwork and a
  waveform — cheaply, since those bars are Core Animation (§6). macOS draws its own
  live activity further along the menu bar; both are visible on purpose.
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

**None.** Every question this plan raised has been settled by the shipped code, and
the answers are recorded above rather than deleted, so the reasoning is not
re-litigated. The two that were open longest — default panel and music-as-chrome —
are now the *Default panel* and *Music is a panel* bullets.


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
- **`ps %cpu` is a lifetime average**, not an instant reading. It reports a high
  number for a minute after launch and drifts down, so it hid a 9% idle cost for
  several sessions. Measure with CPU-time deltas: `ps -o cputime=` twice, or
  `sample <pid> 3` and look for a process parked in `mach_msg2_trap`.
- `screencapture -l <windowid>` captures a window's whole buffer including
  transparent area, which makes it the fastest way to inspect a panel without
  depending on what is underneath it. **It can also return the previous frame** —
  a stale 440 pt buffer made a correct 520 pt layout look broken. When a
  measurement disagrees with the code, re-capture, and trust the window's own
  frame (`CGWindowListCopyWindowInfo`) over the pixels.
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
| 1B | Duplicated panel subviews | **done** — `PanelChrome.swift`, pixel-verified (§13) |
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

### 1B — the extraction, done

Four pieces, extracted to `Sources/PanelChrome.swift`:

| View | Copies | Notes |
| --- | --- | --- |
| `PanelSectionHeader(title:trailing:)` | 3 | 11 pt semibold, tracking 0.6, `0.3` opacity, 14 pt tall, 8 pt leading, 6 pt trailing |
| `PanelEmptyState(symbol:title:subtitle:)` | 2 | Text is passed in: both history panels distinguish "empty" from "filtered out" |
| `FrequentChip(symbol:text:monospaced:help:action:)` | 2 | 24 pt strip, 22 pt pills, radius 7, `0.055` fill, `0.07` stroke |
| `HistoryRow(symbol:text:monospaced:help:action:trailing:)` | 2 | 26 pt, `8/14` padding, hover fill, 13 pt icon, middle-truncated 12 pt label |

`HistoryRow` takes a trailing `@ViewBuilder` because that is the only place the two
rows differed — a `TimelineView(.everyMinute)` age on one, `"%d×"` on the other.
The age helper became an `Age` enum; `ClipEntry.isMonospaced` carries the
command/code/path face rule.

**Verified by pixel diff rather than by eye**, because the failure mode is a 1 pt
spacing drift that nothing else catches: terminal and shelf came out byte-identical
(0 of 665,600 pixels), and the clipboard differed only in the header band — where
the trailing inset is now consistently 6 pt, having been 0 on that panel and 6 on
the others — plus one age label that ticked `16h → 17h` between captures.

---

## 14. Where things live

One line per file, so a reviewer can go straight to the part they care about.

### Shell

| File | Responsibility |
| --- | --- |
| `App.swift` | Entry point, single-instance `flock`, no-notch guard, status item, headless preview renderer, `applicationWillTerminate` |
| `IslandController.swift` | The `NSPanel`, window geometry (grow to `max(old,new)`, settle), global event monitors, drag detector, the shared "open without the pointer" path, collapse timing (the single authority), mouse policy |
| `IslandModel.swift` | All state: panel selection, last-panel preference, geometry, the row highlight and panel navigation, paste delivery, `PlayerService` (sources, polling, toast). The only `ObservableObject` the views observe besides the services |
| `IslandView.swift` | `IslandRootView`, `NotchShape`, `IslandMetrics`, the shell, the shelf/music/settings panels, the toast, the chips/pills/picker views, `AgeView` |
| `Panels.swift` | `PanelID` (sizes, symbols, order, `contentPanels`), `PanelProvider` protocol, `PanelHost` lifecycle, the five providers |
| `HotKeys.swift` | Carbon `RegisterEventHotKey`, three groups: `⌃⌥↓` + clipboard shortcut + `⌥⇧⌘T` (process lifetime), `⌥1–5` (while expanded), `←`/`→`/`↑`/`↓`/`↩`/`⌤`/`⎋` (while expanded). `ClipboardShortcut` presets |
| `PanelKeyboard.swift` | One conformance per panel saying what its rows are, what `↑`/`↓` do and what `↩` does. Replaced four `switch`es and a hardcoded panel list |
| `SystemVolume.swift` | CoreAudio volume on the default output device, for `↑`/`↓` on Music. System volume, not per-app — MediaRemote has no volume to offer |
| `FullscreenSupport.swift` | SkyLight space attach so the island survives fullscreen Spaces |
| `SpotlightState.swift` | Is Spotlight open — drives suppression |

### Media

| File | Responsibility |
| --- | --- |
| `SpotifyBridge.swift` | AppleScript read + artwork fetch + transport commands. Takes precedence whenever Spotify is playing |
| `MediaRemote.swift` | dlsym bridge for **commands only** (play/pause/next/seek); reading is dead on macOS 15.4+ |
| `MediaStream.swift` | Spawns `/usr/bin/perl` with the vendored adapter, reads JSON lines, restarts on death, sweeps orphans by pid file |
| `MediaStreamDecoder.swift` | JSON line → `NowPlaying`, including the patch rule (title-less payloads merge into the current track) |
| `MusicLayout.swift` | The music panel's width, its notch-parameterised height, and the aspect-fitted tile |
| `CoreAnimationEqualizer.swift` | The chin's three bars, as `CALayer` animations the window server interpolates |

### Panels

| File | Responsibility |
| --- | --- |
| `ClipboardService.swift` | Capture loop, blocklist, window filter, cached frecency, paste-back |
| `ClipboardStore.swift` | `ClipEntry`, `ClipKind`, frecency, 300-entry cap, atomic persistence |
| `TerminalHistory.swift` | `~/.zsh_history` parser: continuations, lossy decode, `EXTENDED_HISTORY` stamps |
| `TerminalService.swift` | File watcher, trivia filter, window filter, cached ranking, flush-option notice |
| `ShelfStore.swift` | File references (path + plain bookmark), dedupe, 30-entry cap, load-time pruning |
| `IgnoreRules.swift` | The manual trivia deny-list (`ignore-rules.txt`) |
| `PanelChrome.swift` | Section header, empty state, `FrequentChip`, `HistoryRow` — shared by three panels |
| `HistoryPanel.swift` | `HistoryList` and `HistoryPanel`: the clipboard and terminal lists drawn once, plus the two adapters that say where they differ |
| `FileDropView.swift` | The window's content view as drop target: whole-island reach, the operation contract (never move), file URLs read at the drop |
| `HistoryWindow.swift` | `24h / 7d / 30d / All` as a pure filter, with the untimestamped rule |
| `AccessibilityPaster.swift` | Posts the synthetic ⌘V, and asks for the grant once per launch |
| `AppSupport.swift` | The Application Support directory, and the `ISLAND_DATA_DIR` sandbox |
| `AtomicJSON.swift` | Encode → temp file → chmod `0600` → `replaceItemAt` |

### Build

| File | Notes |
| --- | --- |
| `build.sh` | Target arch from `uname -m`, identity resolution, `swiftc`, compiles the vendored framework with `clang`, signs framework-then-bundle, installs to `~/Applications` and registers it |
| `Info.plist` | `dev.island`, `LSUIElement` (no Dock icon), AppleEvents usage string |
| `vendor/mediaremote-adapter/` | BSD-3 source, compiled at build time; licence ships in `Contents/Resources` |

---

## 15. Second pass and the merge (15 Nov)

Two branches grew from the same commit. `master` reworked the shortcuts and the
README; `Kami` added the keyboard picker, the settings panel, the metrics refactor,
the whole-island drop target and the last-panel preference. This is what merging
them settled, and why. Where this section and `MERGE-KAMI.md` disagree, this one is
the record: two of that document's recommendations were wrong and are corrected in
*Two corrections*.

### What the merge cost

| | |
| --- | --- |
| `origin/Kami` | one commit on `56d7f83` — the parent `master` was on *before* the shortcut change |
| Divergence | 11 files, +1622 / −406 |
| Conflicted | `PLAN.md`, `README.md`, `Sources/HotKeys.swift` (9 regions), `Sources/IslandController.swift` (1) |

Kami was not a feature branch on top of `master`; it was a parallel branch carrying
the **pre-shortcut** copies of the files `master` had rewritten, which is why the
hotkey file collided at all. `App.swift` auto-merged *and* correctly: `Collapse
Island` and `toggle()` stayed gone while the clipboard submenu and `contentPanels`
came through.

Both docs were rebuilt from `master`'s side rather than hand-merged. `README.md` had
been rewritten around two recordings, so a textual merge was all loss; Kami's
content was ported into it instead.

### Three things a clean text merge would have got wrong

**1. Two collapse guards, each blind to the other.** `master`'s `pinnedOpen` stopped
a collapse being *scheduled* (an early return in `handleMouse`); Kami's
`pickerActive` stopped a scheduled collapse *firing* (a guard in `scheduleCollapse`).
Merged as written, a pinned island survived only because `handleMouse` happened to
return before reaching the timer. The timer is now the single authority —
`!locksOpen && !isInteracting && !pinnedOpen && !keyboardSelectionActive` — and
`pinnedOpen` lives in the model so the guard can read it. The two flags stay separate
concepts: one means the pointer did not ask for this, the other means a row list owns
the pointer-adjacent keys.

**2. Kami's `openPicker()` bypassed the open path.** It did the `suppressed` clear,
the fullscreen attach and the `orderFrontRegardless` inline — the same work as
`expandWithoutPointer()`, written twice — and it set `expanded = true` directly to
avoid `expand()`'s rewrite of `activePanel`. Unifying them has an ordering trap:
`expand()` sets `activePanel`, so the panel to restore has to be captured **before**
expanding, and the target panel selected **after**. `toggleKeyboardSelection()` is
now: capture, expand, select.

`expandWithoutPointer()` also gained an early return while Spotlight is open. It did
not have one, and it needed it: `expand()` is blocked by `suppressed` while the
`orderFrontRegardless()` below it is not, so a Spotlight-open menu click could leave
an invisible panel in front.

**3. The clipboard shortcut's menu label.** Kami's `clipboardShortcutAvailable` — and
the "in use by another app" text built on it — rested on `RegisterEventHotKey`
returning an error for a taken chord. It does not (§2), so the state was removed
rather than shipped. Settings and the menu show which preset is chosen and nothing
about whether it is free; a Carbon error is logged.

### Two corrections to `MERGE-KAMI.md`

- It says the panel index mapping "must use `contentPanels`, not `allCases`". Wrong:
  `allCases` is what makes `⌥5` reach Settings. `contentPanels` is only for "which
  panel does hover reopen on", where Settings must not appear.
- It recommends unifying `togglePicker()` with `expandWithoutPointer()`. Done, but
  not the way it describes: `expand()` rewrites `activePanel` before `openPicker()`
  would have saved the panel to restore, so the capture has to come first.

### The list refactor

`ClipboardPanel` and `TerminalPanel` were 107 and 90 lines that differed in three
places. `PanelChrome` had already extracted the header, empty state, chip and row and
stopped short of the list; `HistoryPanel` finishes it. `HistoryList` is the shape
both services already had, and the two adapters live next to the view so no service
learns about SwiftUI.

The selection became `ListSelection { panel, id }` — the id, not the index, because
both lists change underneath it: a new copy arrives at row 0, zsh appends a command,
and an index would silently move the highlight onto another row. One switch,
`paste(panel:rowID:autoPaste:)`, is the only place the two lists still differ in the
paste path, because a clipboard row bumps frecency and a command must not land in
clipboard history.

### Measured, inferred, unverified

Kept apart deliberately, because the earlier draft of this document ran them
together.

| Claim | Status |
| --- | --- |
| `RegisterEventHotKey` returns `noErr` for a taken chord and for system chords | **measured**, five cases (§2) |
| A warning keyed on registration status can never fire | **follows from the measurement** |
| A taken chord fails at delivery | **inferred** — the probe received no hotkey at all, including an unclaimed control |
| A passive `CGEventTap` would win the chord | **inferred**, untested |
| The one "shortcut does nothing" report was contention | **false** — it was `⌥↓` without `⌃` |
| Finder drops work, including drag-out | **verified** |
| Dock Downloads-stack drops work | **unverified** (§5) |
| Music and Settings heights at 37.5 pt | **computed** from the formula; the music one was confirmed on the second machine, the settings one has not been seen |

### How this pass was checked

`swiftc -typecheck -parse-as-library -swift-version 5 -target
arm64-apple-macos26.0 -framework AppKit -framework SwiftUI Sources/*.swift` after
each commit. That is the whole of it: nothing in this pass has been run on a notched
display, so everything in *Using it* about the keyboard selection is design intent
until it is. The verification list is in `README.md`'s own terms: `⌃⌥↓` from another
app, `⌥1`–`⌥5`, the mode's keys only while armed, `⌃⌘V` while closed, focus staying
in the original app, every exit unregistering them, a mid-selection copy not moving
the highlight, and a move-only drag being refused.

§16 replaced the keyboard layer after this pass. The rest of §15 stands; where it
describes `⌃⌥←/→` or `⌥Tab`, read it as the history of a decision that was reversed.

---

## 16. The keyboard layer, replaced (15 Nov)

Everything in this plan that described `⌃⌥←/→` cycling, `⌥Tab` / `⌥⇧Tab`, `⌥↩`, or a
"keyboard selection" that *was* the mode is superseded here. The merge itself (§15)
stands: only the keyboard layer was rebuilt, on top of it.

### Why it was replaced

The mode's lifetime was `listSelection != nil` — the mode was the selection. Three
consequences, none of them visible until you drew them out:

- `rowCount` is 0 for Shelf, Music and Settings, and `retargetSelection` ended the mode
  when the first row id was empty. So cycling landed on a panel with no rows and
  dropped the keys. `→` from the terminal did exactly that.
- An **empty** list stored a `""` id, every lookup failed, and paste exited. Entering
  on an empty clipboard put you in a mode that ended on the first key.
- `cyclePanel` walked `PanelID.allCases`, so the destination depended on declaration
  order rather than on what could hold a row.

None of that is a bug in one line; it is the model. There is no separate mode any
more — the island is keyboard-driven while it is open — and `listSelection` is only
ever a row.

### The panels declare their own behaviour

`PanelKeyboard` (`Sources/PanelKeyboard.swift`) has one conformance per panel and
answers three questions: what its `rowIDs` are, what `↑`/`↓` do, and what `↩` does.
The model asks the dictionary and never switches on `PanelID`.

```swift
protocol PanelKeyboard: AnyObject {
    var rowIDs: [String]? { get }                     // nil = not a list at all
    func moveVertical(_ delta: Int)
    func activate(_ rowID: String, autoPaste: Bool)
}
```

`rowIDs` is optional for a reason the old code got wrong: `nil` means the panel has no
list (Music), `[]` means the list is empty right now (an empty clipboard). Conflating
them is what made an empty list end the mode.

`←`/`→` are not in the protocol. Changing panel means the same thing everywhere, so it
lives in the model and walks `PanelID.contentPanels` filtered to the panels that have a
conformance — the order they appear on screen, minus Settings.

### The keys

| Key | When | Does |
| --- | --- | --- |
| `⌃⌥↓` | always | open on the last list with its first row selected · close |
| `⌃⌘V` | always | open on the clipboard, first row selected |
| `⌥⇧⌘T` | always | open on the terminal list, first row selected |
| `⌥1`–`⌥5` | while expanded | jump to a panel; `⌥5` reaches Settings |
| `←` / `→` | while expanded | step between the four content panels |
| `↑` / `↓` | while expanded | the panel's own: rows on a list or the shelf, volume on Music |
| `↩`, `⌤` | while expanded | the panel's own: paste, open the file, play/pause |
| `⎋` | while expanded | close |

The named shortcuts no longer toggle. `⌃⌘V` on an island the pointer already holds open
means "show me the clipboard" and closes nothing; `⎋` and `⌃⌥↓` are the close keys. A
key that sometimes closed the window was fine while the island was pointer-only and is
a trap now that hovering opens it.

Removed, and not replaced: `⌃⌥←` / `⌃⌥→`, `⌥Tab` / `⌥⇧Tab`, `⌥↩`, and `⌃C` / `⌘C` —
the last two never shipped, but both were proposed and both were why the copy chord
was reconsidered: `⌃C` is SIGINT in a terminal and the mode is armed exactly when a
terminal is focused, and `⌘C` was unnecessary once `↩` writes the pasteboard on its
way to pasting. ⌥-click still copies without pasting.

`⌥⇧⌘T` rather than `⇧⌘T` or `⌃⌘T`: `⇧⌘T` is Reopen Closed Tab in three browsers and two
editors, which is the `⇧⌘V` mistake again; `⌃⌘T` is free and symmetric with `⌃⌘V` and was
offered instead. Three modifiers buy freedom from collision at the cost of one-handed
reach. **Free is not measured** — it is "no documented shortcut I know of", the same
distinction this plan draws everywhere else.

### The invariant

The bare keys are global, so the only thing making them affordable is that they cannot
outlive the island. Three properties, together:

1. **Registration follows `expanded`, with no `receive(on:)`.** Every other
   subscription in `IslandController` hops to the main run loop; this one must not, or
   the keys stay captured for a frame after the window has closed.
2. **`HotKeys.uninstall()` clears the group too.** It is only reachable from
   `handleExpansion(false)`, so this cannot disarm a live island — it means a
   subscription that stops firing cannot leave `← → ↑ ↓ ↩ ⌤ ⎋` stolen with nothing on
   screen.
3. **Reaching a panel with no rows clears the highlight.** `retargetSelection` drops
   `listSelection` when the target has no `rowIDs`, so a highlight never points at a
   list that is not showing.

The caveat this design accepts: while the island is up, `⎋` and `↩` are captured too,
including for the moment a file drag holds the island open from up to 100 pt away
(`dragZone`). The alternative was a second entry condition for the same behaviour, and
that is the inconsistency this section exists to remove.

### Measured, inferred, and not

| | |
| --- | --- |
| `RegisterEventHotKey` still returns `noErr` for taken and system chords | **measured** (§2) — unchanged by this work |
| Registration follows `expanded` | **observed** — hovering then pressing `←`/`→`/`↑`/`↓` did nothing in the build *before* this change; see the round-2 notes in the implementation record |
| Every exit unregisters the mode's keys | **design intent** — untested; the exit list is `collapse()` and a non-list panel |
| `⌥⇧⌘T` is free | **not measured** — no documented shortcut I know of, which is a weaker claim than the `RegisterEventHotKey` findings above |
| `↑`/`↓` on Music changes the system volume | **unverified** — needs hardware |
| A held `↓` repeats | **unknown** — Carbon may deliver one event per down-stroke |
| The mode's arrows reach an empty list without ending it | **by construction** — `retargetSelection` keeps the `""` id |

Nothing in this section has been run. No build has been installed, and no commit on
this branch has been through a launch.

### Open

- **A held arrow may not repeat.** If Carbon delivers one event per press, the list
  moves one row per press and this needs a timer. This is the first thing to test.
- **`⌃⌘V` no longer puts the panel back.** The mode used to restore the panel it
  detoured from; that was deleted with `endKeyboardSelection`. Because `activePanel`
  persists, a shortcut detour now moves the panel hover reopens on. `⌃⌥↓` has the same
  effect and it is intended there. Undecided whether it should be for `⌃⌘V`.
- **The two recordings predate this.** Both GIFs are captioned with `⌃⌥→`, and
  `docs/panel-tour.gif` walks Clipboard → Terminal → Shelf → Music, which the arrows
  can no longer do. The captions were reworded; the recordings were not re-shot.
- **`player.startPolling()` runs on every expand**, not only on the Music panel
  (`IslandController.swift:842`). It contradicts the single-lifecycle rule in §2.
  Pre-existing, separate from this work.
