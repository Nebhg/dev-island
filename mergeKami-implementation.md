# mergeKami — implementation record

Companion to `mergeKami.md`. That file is the plan; this one is what was built, why it
was built that way, and where the code and the plan disagree. Updated at the end of
every phase.

Read the two side by side: where a phase below says **differs**, the plan is wrong or
incomplete and this file is the correction.

| phase | commit | state |
|---|---|---|
| 1 | `Make the keyboard mode a mode, not a selection` | committed `e0bd007` — typechecks |
| 2 | `Register the mode's keys against the mode` | **built, uncommitted** — typechecks |
| 3 | `Cycle the two list panels with the arrows` | committed `b917550` — typechecks |
| 4 | `Drop the cycle chords and the Tab aliases` | committed `0769198` — typechecks |
| 5 | `Arm the island from the toggle key` | committed `166ec74` — typechecks |
| 6 | `Document the keyboard layer that exists` | **built, uncommitted** |

Nothing has been built into an app, installed, or run. Every "works" below means
"typechecks and reads correctly", not "observed".

---

## Phase 1 — the mode stops being a selection

**Plan:** §12 commit 1 — `keyboardMode`, `beginKeyboardMode(on:)`, `retargetSelection`
rewrite, `collapse()` teardown, delete `endKeyboardSelection`.
**Actually changed:** `Sources/IslandModel.swift`, `Sources/IslandController.swift`.

### What was done

| before | after |
|---|---|
| `var keyboardSelectionActive: Bool { listSelection != nil }` | `@Published private(set) var keyboardMode = false` |
| `beginKeyboardSelection(restoring:)` | `beginKeyboardMode(on:)`, guarded to `.clipboard` / `.terminal` |
| `endKeyboardSelection()` | `private func endKeyboardMode()` |
| `private var panelBeforeSelection: PanelID?` | deleted |
| `retargetSelection`: ended the mode when the first row id was empty | keeps the empty id; ends only on a non-list panel |
| `collapse()`: `guard expanded` then `endKeyboardSelection()` | `endKeyboardMode()` **above** the guard |

Call sites moved in `IslandController.swift`: the `onPanelKey` fork, the app-switch
observer, `toggleKeyboardSelection`, and the `scheduleCollapse` guard. The
`scheduleCollapse` comment was rewritten with them — it said "a selected row is driven
from the keyboard", which is no longer what the flag means.

`toggleKeyboardSelection` lost its captured `restore` and now ends with
`model.beginKeyboardMode(on: .clipboard)`.

### Where reality differs from the plan

**1. §5's "`keyboardMode = false` in `collapse()` and nowhere else" cannot be
implemented literally.** §3 also requires `⌥3`/`⌥4`/`⌥5` to end the mode *without*
collapsing the island — and that panel change goes through `retargetSelection`, not
`collapse()`.

Implemented as: **one assignment site, two callers.** `endKeyboardMode()` is the only
place the flag is written; `collapse()` and `retargetSelection` both call it. The
invariant the plan is protecting — that the bare keys have exactly one route to
becoming unregistered, and no path clears and re-arms them behind the user's back — is
unchanged. "Nowhere else" was describing the wrong thing; "no second assignment site"
is what it meant.

**2. Deleting `panelBeforeSelection` is a real behaviour change, and the plan
under-sold it.** §6 says closing "leaves `activePanel` where it is, which is the same
thing `reopensLastPanel` wants anyway". That is only half true:

| | old | new |
|---|---|---|
| `⌃⌘V` while on Music, then `⎋` | back on Music | stays on Clipboard |
| `lastPanel` in `UserDefaults` | unchanged by the detour | **now Clipboard** |
| next hover | Music | Clipboard |

Because `activePanel`'s `didSet` persists, a shortcut that was meant to be a detour now
moves the panel the island reopens on. That is a persistent change caused by a
keystroke, which is exactly what `reopensLastPanel`'s comment says it is not.

Kept as planned rather than reverted, because the plan is the approved document and
this is a comparison, not a rewrite. **Revert is about eight lines**: restore a
`panelBeforeMode: PanelID?`, set it in `beginKeyboardMode`, and put the guarded restore
back in `endKeyboardMode`. Say the word and it goes in phase 5, where `⌃⌥↓` starts
arming the mode on the last-used panel — at which point "the mode moved my default
panel" stops being a corner case for one shortcut and becomes the normal path.

**3. `endKeyboardMode()` early-outs when already clear.** Not in the plan. `@Published`
publishes on every assignment even when the value is unchanged, and `collapse()` runs on
every hover-out. The guard keeps a needless publish, and the view invalidation behind
it, off the hover path.

**4. `beginKeyboardMode` sets `activePanel` before `keyboardMode`.** Not in the plan,
but phase 2 hangs hotkey registration off `$keyboardMode`. Whoever observes that
publisher must not see the mode on while the island is still showing the previous
panel, or the first frame after arming is the old panel with the new keys live.

### Verification

```
swiftc -typecheck -parse-as-library -swift-version 5 \
  -target arm64-apple-macos26.0 \
  -framework AppKit -framework SwiftUI Sources/*.swift
→ clean (exit 0)
```

Grep for `keyboardSelectionActive`, `beginKeyboardSelection`, `endKeyboardSelection`,
`panelBeforeSelection` across `Sources/`: no matches.

Not verified: anything at runtime. Not built, not installed, not launched.

### Known-broken after phase 1, by design

These are the phases that follow, listed so a reviewer does not read them as bugs:

- Registration still hangs off `$listSelection`, not `$keyboardMode` (phase 2). The two
  are equivalent today because nothing sets one without the other, but the sink is
  still keyed on the thing that is no longer the mode.
- `cyclePanel` still walks `PanelID.allCases`, so it is still possible to cycle onto a
  panel with no rows. `⌥3`–`⌥5` now end the mode through the corrected
  `retargetSelection` instead of through an empty row id, which is the intended path;
  the arrow chords that made it easy to hit are removed in phase 4.
- `⌃⌥←/→` and `⌥Tab`/`⌥⇧Tab` are still registered (phase 4).
- `⌃⌥↓` still closes an expanded island rather than arming it (phase 5).

### Open, carried forward

- Auto-repeat on a held arrow is still unmeasured.
- The two GIFs still show `⌃⌥→` (phase 6, and needs a decision first).
- `⌃⌘V` no longer restores the panel it detoured from — item 2 above.

---

## Phase 2 — register the mode's keys against the mode

**Plan:** §12 commit 2 — `$keyboardMode` sink, `installModeKeys`, the
`expanded && keyboardMode` condition.
**Actually changed:** `Sources/HotKeys.swift`, `Sources/IslandController.swift`,
`Sources/PanelChrome.swift`.

### What was done

| before | after |
|---|---|
| `model.$listSelection` sink | `model.$keyboardMode.combineLatest(model.$expanded)` |
| `PickerKey` | `ModeKey` |
| `pickerKeys` / `pickerRefs` | `modeKeys` / `modeRefs` |
| `installPickerKeys()` / `uninstallPickerKeys()` | `installModeKeys()` / `uninstallModeKeys()` |
| `onPickerKey` | `onModeKey` |
| `handlePickerKey` | `handleModeKey` |

Two stale comments fixed with them: the `HotKeys` group description said "picker — while
a history row is being driven from the keyboard", and `PanelChrome.swift:114` said "The
keyboard picker's current row". Both now say mode.

`uninstall()` also clears `modeRefs`, which the plan did not ask for — see item 3.

### Where reality differs from the plan

**1. The rename landed in one phase instead of three.** §4 said "rename while touching
them", which would have spread `PickerKey` → `ModeKey` across phases 2, 3 and 4 and
produced three commits that are mostly the same word changing. One mechanical commit
that typechecks is easier to review than three partial ones. No behavioural risk —
the compiler catches every site.

**2. `combineLatest` gives an ordering the plan did not claim.** `endKeyboardMode()`
runs before `collapse()` clears `expanded`, and `$keyboardMode` is the first term, so
the first emission already unregisters. The old sink hung off `$listSelection`, which
was cleared *after* `expanded = false` in the previous `collapse()`, so this is a
slightly earlier teardown than before. Small, but in the right direction: the keys are
gone before the window starts closing rather than after.

**3. `uninstall()` now clears the mode's refs as well.** Not in the plan, and not
redundant with the sink. §5's whole concern is bare keys outliving the island; with
registration hanging off a Combine chain, a sink that stops firing leaves them stolen
with no island on screen and nothing to press to get out. `uninstall()` is only ever
reached from `handleExpansion(false)`, which only ever runs from a collapse, so
clearing there cannot disarm a mode that should still be live. This makes the
invariant structural — "no panel keys, no mode keys" — rather than a property of one
subscription.

### Verification

```
swiftc -typecheck … → clean (exit 0)
```

`grep -rn "picker\|Picker" Sources/` returns only the unrelated UI types
(`PillPicker`, `HistoryWindowPicker`) and one comment in `toggleKeyboardSelection`
that says there is no separate picker. No `PickerKey`, `onPickerKey`,
`installPickerKeys` or `pickerRefs` anywhere.

Not verified at runtime.

### Known-broken after phase 2, by design

- The mode group still holds `↩`, `⌥↩`, `⎋` only. `← → ↑ ↓` arrive in phase 4, which is
  why the arrows cannot switch panels yet.
- `cyclePanel` still walks `allCases`; the arrow chords that made that easy to hit are
  removed in phase 4.
- `⌃⌥↓` still closes an expanded island rather than arming it (phase 5).

### Open, carried forward

Unchanged from phase 1: auto-repeat unmeasured, GIFs undecided, `⌃⌘V` no longer
restores the panel it detoured from.

---

## Phase 3 — cycle the two list panels with the arrows

**Plan:** §12 commit 3 — `cycleListPanel`, `ModeKey.cyclePanel` / `.moveRow`, delete the
`onPanelKey` fork.
**Actually changed:** `Sources/IslandModel.swift`, `Sources/HotKeys.swift`,
`Sources/IslandController.swift`.

### What was done

- `IslandModel.cycleListPanel(by:)` — walks `[.clipboard, .terminal]` and wraps.
- `ModeKey` gains `.cyclePanel(Int)` and `.moveRow(Int)`, named apart.
- `Slot` gains `left = 15`, `right = 16`, `up = 17`, `down = 18`.
- `modeKeys` gains the four arrow chords at `modifiers: 0`.
- `dispatch` maps them; `handleModeKey` calls `cycleListPanel` / `moveSelection`.

### Where reality differs from the plan

**1. The arrows are registered here, not in phase 4.** As planned, phase 3 added
`ModeKey.cyclePanel` / `.moveRow` but the `← → ↑ ↓` chords arrived in phase 4 — which
meant phase 3 would ship two `switch` arms with nothing that could ever reach them.
§12 leaves the case with no producer for a commit, and the repo has already dropped
dead code once for exactly this reason (`4fea189`). Pulling registration forward makes
every commit self-contained: phase 3 adds a working feature, phase 4 removes the
chords it replaces.

**2. `Slot` numbers were appended as 15–18 instead of renumbered immediately.** They
sit after `close = 14`, so the namespace stays contiguous. Phase 4 removes six cases
from the middle and renumbers to 0–12 — doing it twice would make both diffs harder to
read than either.

**3. `cyclePanel` is still here and now has one caller.** `⌃⌥←/→` outside the mode still
walks every panel, which is the documented behaviour until phase 4 deletes those
chords. When phase 4 does, `cyclePanel` loses its last caller and must go with them —
it is not left in place as an unused function.

**4. The `.step` fork in `onPanelKey` survives this commit.** In keyboard mode
`⌃⌥←/→` still move the row through it, which is now a duplicate of `↑`/`↓`. Removing the
fork, `PanelKey.step` and the two cycle slots is one operation, and it belongs with the
commit that removes the chords feeding them.

### Verification

```
swiftc -typecheck … → clean (exit 0)
```

Not verified at runtime. In particular the claim that a held `↓` repeats is still a
hypothesis: Carbon may deliver one press per physical down-stroke, in which case the
list moves one row per press and this needs a timer.

### Known-broken after phase 3, by design

- `⌃⌥←/→` and `⌥Tab`/`⌥⇧Tab` are still registered, and still compete with the arrows
  for "what does the mode's left/right mean" — the arrows win because they are
  separate chords, but both paths are live until phase 4.
- `⌥↩` still copies from the keyboard; phase 4 removes it with the `copy` slot.
- `⌃⌥↓` still closes an expanded island rather than arming it (phase 5).

### Open, carried forward

Auto-repeat unmeasured; GIFs undecided; `⌃⌘V` no longer restores the panel it detoured
from.

---

## Phase 4 — drop the cycle chords and the Tab aliases

**Plan:** §12 commit 4 — `Slot` renumbered, `←→↑↓` in, `⌃⌥←/→` and `⌥Tab` out, comments
rewritten.
**Actually changed:** `Sources/HotKeys.swift`, `Sources/IslandController.swift`,
`Sources/IslandModel.swift`.

### What was done

| removed | replaces it |
|---|---|
| `Slot.previous`, `.next` (`⌃⌥←`, `⌃⌥→`) | `.left`, `.right` |
| `Slot.tabForward`, `.tabBackward` (`⌥⇧Tab`, `⌥Tab`) | `.up`, `.down` |
| `Slot.copy` (`⌥↩`) | nothing — `↩` already writes the pasteboard |
| `PanelKey.step(Int)` | `ModeKey.cyclePanel(Int)` / `.moveRow(Int)` |
| `IslandModel.cyclePanel(by:)` | `cycleListPanel(by:)` |
| `pasteSelection(copyOnly:)` | `pasteSelection()` |

`Slot` renumbered to a contiguous 0–13:

| | | | |
|---|---|---|---|
| 0 toggle | 1–5 panel1–5 | 6 clipboard | 7 left |
| 8 right | 9 up | 10 down | 11 paste |
| 12 pasteKeypad | 13 close | | |

The `keys` group is now five entries — `⌥1`–`⌥5` and nothing else. Its doc comment was
rewritten to record what used to be there and why both are gone, rather than to keep
arguing for them.

### Where reality differs from the plan

**1. `⌥↩` went in this commit, not its own.** §3 lists it as removed but §12 never
assigns it to a phase. It belongs here: it is the `copy` slot, and the `copy` slot is
part of the renumber. Leaving it for later would have meant renumbering twice.

**2. §8 said to *delete* the `⌥Tab` justification paragraph. I replaced it instead.**
The plan's objection was that the paragraph "argues for a chord that no longer exists".
That is right, and it was the paragraph's purpose, not its wording. The replacement
argues the opposite — why the chord went — in the same place, so the next person
reading `keys` finds out why the obvious aliases are missing rather than adding them
back. Same for the old paragraph in `modeKeys` that explained why the arrows were *not*
registered; it now explains why they are.

**3. `cyclePanel(by:)` is gone, so nothing walks all five panels any more.** Phase 3
kept it for `⌃⌥←/→`; with those removed it has no caller. Panels are reachable by
number at any time, and by arrow once the mode is armed. Verified by typecheck — an
unused private method would not fail, so this is a deliberate deletion rather than a
compiler-visible one.

**4. `pasteSelection()` no longer takes `copyOnly`.** `↩` writes the row to the
pasteboard on its way to pasting, so a "copy instead" key only restated it. ⌥-click
still copies without pasting (`HistoryPanel.swift:180-181`), which is the path that
needs it: a mouse has no Return to press.

### Verification

```
swiftc -typecheck … → clean (exit 0)
```

`grep -rn "cyclePanel(by\|\.step(\|tabForward\|tabBackward\|kVK_Tab\|copyOnly"` returns
only `HistoryPanel.swift:180-181`, the mouse path that is supposed to keep it.

**This is the first commit where the plan's key set is fully in place.** What is still
missing is the way in: `⌃⌥↓` still closes an expanded island rather than arming it, so
the only route into the mode is `⌃⌘V` on the clipboard.

### Known-broken after phase 4, by design

- `⌃⌥↓` closes rather than arms (phase 5).
- There is no arrow path to Shelf or Music at all now. `⌥3`/`⌥4` reach them; both end
  the mode.
- `⌥5` reaches Settings and ends the mode, because Settings is not a list.

### Open, carried forward

Auto-repeat unmeasured; GIFs undecided; `⌃⌘V` no longer restores the panel it detoured
from.

---

## Phase 5 — arm the island from the toggle key

**Plan:** §12 commit 5 — three-state `⌃⌥↓`, `⌃⌘V` as the same mode.
**Actually changed:** `Sources/Panels.swift`, `Sources/IslandModel.swift`,
`Sources/IslandController.swift`.

### What was done

- `PanelID.isList` — the predicate had been written out three times.
- `IslandModel.lastListPanel`, updated in `activePanel.didSet` alongside
  `lastContentPanel`.
- `IslandModel.keyboardLandingPanel` — where the mode should arm.
- `IslandModel.expand(on:)` — optional landing override.
- `IslandController.expandWithoutPointer(on:)` — passes it through.
- `toggleExpanded()` is now three-state; `armKeyboardMode()` is the shared arm step.
- `toggleKeyboardSelection()` → `openKeyboardMode()`, and it passes `.clipboard`.

### The state machine

| island | `⌃⌥↓` |
|---|---|
| closed | open on `keyboardLandingPanel`, arm |
| open, not armed | arm where it is |
| armed | close |

Opening on the landing panel *before* the window is ordered is the reason for
`expand(on:)`. Arming after `expand()` would have set `activePanel` twice in one turn —
once to `panelOnOpen`, then to the landing — and the geometry callback runs from that
setter, so the island would have animated to the wrong panel first.

### Where reality differs from the plan

**1. `keyboardLandingPanel` prefers the panel already on screen.** The plan said "arm,
and jump to the last list panel" for a non-list panel, without saying what an island
already up on the clipboard should do. It should stay: the user is looking at it.
So the landing is `expanded ? activePanel : panelOnOpen`, falling back to
`lastListPanel` only when that is not a list.

**2. `lastListPanel` is new state the plan did not mention.** §5 says "jump to the last
list panel" as though one existed; nothing did. It is four lines, and without it the
fallback would be a hardcoded `.clipboard`, which would send `⌃⌥↓` to the clipboard
even for someone who only ever uses the terminal list.

**3. `expandWithoutPointer` had to name its parameter `landing`.** The controller
already has a stored `panel` of type `IslandPanel`, and the compiler read the new
parameter as shadowing it. Caught by typecheck, not by review.

**4. The status menu still does not arm.** `App.swift:207` calls
`expandWithoutPointer()` with no argument, so "Open Island" opens without taking any
keys. That is deliberate and now load-bearing: choosing a menu item is not asking to
drive the island from the keyboard, and a menu that silently took the arrow keys would
be the worst possible place to discover the mode.

### Verification

```
swiftc -typecheck … → clean (exit 0)
```

Not verified at runtime. The three-state toggle is the change most likely to feel wrong
in the hand, and there is no way to know from here whether "second press arms" reads as
progress or as nothing happening — arming is only visible as a row highlight, and on a
panel already showing a row there is nothing to see at all.

### The `⌃⌘V` restore question is now live

Phase 1 deleted `panelBeforeSelection`, so `⌃⌘V` no longer returns to the panel it
detoured from. With `⌃⌥↓` now arming on the last-used panel, the two paths disagree:

- `⌃⌥↓` on Music → lands on the last list, **and that becomes `lastPanel`**.
- `⌃⌘V` on Music → lands on clipboard, **and that becomes `lastPanel`**.
- Neither returns you to Music.

Both are now persistent panel changes caused by a keystroke. This is the item to decide
before phase 6, because whatever the README says about reopening the last panel has to
match what actually happens.

### Known-broken after phase 5, by design

- Documentation still describes `⌃⌥←/→` and `⌥Tab` (phase 6).
- The GIF captions still name the retired chord (phase 6).

### Open, carried forward

Auto-repeat unmeasured; GIFs undecided; the restore question above.

---

## Phase 6 — document the keyboard layer that exists

**Plan:** §12 commit 6 — README, `PLAN.md`, and the `6f358ee` note.
**Actually changed:** `README.md`, `PLAN.md`.

### What was done

`README.md`:

| where | was | is |
|---|---|---|
| caption, `docs/autopaste.gif` | "`⌃⌥→` cycles panels" | "`⌃⌥↓` opens it from the keyboard and arms the arrows" |
| caption, `docs/panel-tour.gif` | "Clipboard → Terminal → Shelf → Music, on `⌃⌥→`" | the tour, plus a note that the arrows cover the two lists and Shelf/Music are a click or `⌥3`/`⌥4` |
| *Open from the keyboard* | "toggles the island open or closed" | the three states, and that hovering never arms |
| *Switch panels* | "`⌥1`–`⌥5`, or `⌃⌥←`/`⌃⌥→` to cycle (also `⌥Tab`/`⌥⇧Tab`)" | `⌥1`–`⌥5` any time; arrows only while armed; no arrow path to Shelf/Music/Settings |
| *Paste from history* | `⌃⌥←`/`⌃⌥→` choose a row, `⌥↩` copies | `↑`/`↓` rows, `←`/`→` lists, `↩` pastes, `⎋` etc. ends; `⌃⌘V` then `→` reaches the terminal |
| *Why the shortcuts sit on `⌃⌥`* | — | added the paragraph about there being no "shortcut taken" warning, and why one cannot exist |

`PLAN.md`:

| where | change |
|---|---|
| §2 Navigation | the prose paragraph, the group table, and a new subsection on the mode group and the two chords that went |
| §3 key table | rewritten for the new keys, plus three bullets: not clipboard-specific, the mode is not a selection, nothing is armed on hover |
| §14 file table | `HotKeys.swift` row now lists the new groups |
| §15 tail | "both cycle methods only while expanded" corrected, and a pointer to §16 |
| **§16** | new — why the layer was replaced, the key table, the invariant, a measured/inferred/not table, and four open items |

### Where reality differs from the plan

**1. §16 is new; the plan did not ask for a new numbered section.** §12 said "README,
PLAN.md, and the `6f358ee` note". A pointer note would have left the plan's own §2 and
§3 contradicting the code with only a footnote. The document's purpose is to be the
argument for the design; it cannot argue for a design that no longer exists. §16 also
gives the reference in §2 something to point at.

**2. The GIF captions were reworded rather than re-recorded.** The recordings still
show `⌃⌥→`, and `panel-tour.gif` still walks four panels. Captions now describe what
the panels are and what the arrows actually do, without claiming the GIF demonstrates a
chord. That is honest but incomplete; the recordings are stale and the open item says so
rather than pretending otherwise. Re-recording needs a build, a restart and a screen
capture, none of which have happened.

**3. The *#15* record was corrected rather than left alone.** Its closing verification
list still named "both cycle methods", which no longer exist. Left as-is it would have
been a checklist for a design that was gone. It now names the mode's keys and points at
§16 for the rest.

**4. README's panel-reopening bullet was left untouched.** It says the island "reopens
on whichever panel you left it on", which is true, but a keyboard detour now counts as
leaving it there — the item carried since phase 1. Deliberately not papered over with a
parenthetical, because the behaviour is undecided. If the restore comes back, the
sentence is already right; if it does not, it needs a clause. See below.

### Verification

Nothing to typecheck — documentation only. `swiftc -typecheck` still clean at this
commit, since no source changed after phase 5.

`grep -rn "⌃⌥←\|⌃⌥→\|⌥⇧Tab\|⌥Tab\|⌥↩" README.md PLAN.md` returns three lines, all of
them explaining that those chords are gone.

---

## Where the series ended up

Six commits, each typechecking alone:

```
166ec74 Arm the island from the toggle key
0769198 Drop the cycle chords and the Tab aliases
b917550 Cycle the two list panels with the arrows
1a2b672 Register the mode's keys against the mode
e0bd007 Make the keyboard mode a mode, not a selection
c326208 Write the keyboard plan and its implementation record
```

The branch is `merge-kami`, now 13 commits ahead of `master` and still unpushed.
`master` is unchanged.

### What the plan got right

- The mode/selection split as the central change, and the three bugs it fixes.
- The group structure and the two-term registration condition.
- `⌃C` as unacceptable, and copy-only as unnecessary once `↩` writes the pasteboard.
- The list-panel restriction on arrows.

### What the plan got wrong

| plan | reality |
|---|---|
| "`keyboardMode = false` in `collapse()` and nowhere else" | one *assignment site*, two callers — `⌥3`–`⌥5` must end the mode without collapsing |
| "delete `panelBeforeSelection`, it is what `reopensLastPanel` wants" | it is not; a shortcut detour now moves the persistent last panel |
| phase 3 ships `ModeKey` cases with no producer | registration pulled forward so no commit has unreachable arms |
| "delete the `⌥Tab` paragraph" | replaced with why the chord went; deleting the only record is how it comes back |
| §8's slot table assumed one renumber | two, because phase 3 appends and phase 4 removes |
| nothing about where `⌃⌥↓` lands | `keyboardLandingPanel` + `lastListPanel`, both new |

### Still to do, in the order they matter

1. **Build, install, launch.** Nothing in this pass has run. Every claim above is
   typecheck and reading.
2. **Held-arrow auto-repeat.** If Carbon does not repeat, `↑`/`↓` need a timer; this is
   the difference between a list that scrolls and a list you press forty times.
3. **The exit audit — the release gate.** After `⎋`, `↩`, a click elsewhere, `⌘Tab` and
   the toggle key, confirm `←→↑↓↩⌤⎋` reach the frontmost app again. Any path that
   leaves them captured is a blocker.
4. **Decide the `⌃⌘V` restore.** Either restore `panelBeforeMode`, or add the clause to
   the README that a keyboard detour counts as choosing a panel.
5. **Re-record or cut `docs/panel-tour.gif`.** The captions no longer claim what the
   recording shows, but the recording is still of the old chords.

---

## Round 2 — after the first runtime look

Ben ran it. First observations: `⌃⌥↓` then `←`/`→` and `↑`/`↓` work; hovering does not
arm. That confirmed phase 5 and converted three "unverified" lines to "observed",
and it produced three changes of direction, below.

### Phase 7 — arm the keyboard whenever the island is open

**Why:** the mode existed to bound a global key capture, and the bound was chosen on a
wrong premise. `inHotZone` is `islandRect.insetBy(dx: -8, dy: -4)` — the pointer has to
be *on the island* — so a hover is a pointing gesture, not a cursor parked near the
notch. The exposure the flag was protecting against does not exist, and two entry
conditions for one behaviour is the kind of inconsistency the rewrite was meant to
remove.

**What was done**

| before | after |
|---|---|
| `keyboardMode` flag | deleted |
| `$keyboardMode.combineLatest($expanded)` | `$expanded` alone, still with no `receive(on:)` |
| `endKeyboardMode()` | `clearSelection()`; there is no mode to end |
| `⌃⌥↓` three-state | two-state: open + select, or close |
| `⌃⌘V` toggled | always lands on the clipboard and selects; it no longer closes |
| `moveSelection` required a selection | seeds from nothing, first press creates it |
| `retargetSelection` seeded on every panel change | returns early when nothing is selected |
| collapse guard tested `keyboardMode` | tests `pinnedOpen` only |
| app-switch observer tested `keyboardMode` | tests `expanded` |

**The visual rule this buys.** Keys follow `expanded`; the *highlight* follows the
first arrow press. So a hovered island looks exactly as it did before — no row
highlighted until you reach for the keyboard. `↑` from nothing lands on the first row,
not the second.

**Where this differs from the phase-1…6 reasoning.** `retargetSelection` used to seed a
selection on any panel change, which was right when the selection *was* the mode. It is
now wrong: switching panels by icon or `⌥`-number is not a request for a highlight. The
guard was inverted rather than deleted, so `⌥2` after `⌃⌘V` still keeps the highlight
you had.

**Still broken after this commit, by design:** `cycleListPanel` only knows the two list
panels, so `←`/`→` do nothing while Music is showing. Fixed in phase 8.

### Recorded but not yet checked

- **Auto-repeat** on a held arrow is still unmeasured — Ben's report covers single
  presses.
- **The exit audit** has not been run. That is still the release gate.

### Phase 8 — let each panel declare its own rows

**Why:** the same fact was written down four times — `rowCount`, `rowID`,
`selectedRowIndex`, and `cycleListPanel`'s hardcoded `[.clipboard, .terminal]` — plus
`PanelID.isList`, which was a fifth. Nothing made them agree, and adding a panel meant
editing all of them.

**What was done**

New `Sources/PanelKeyboard.swift`:

```swift
protocol PanelKeyboard: AnyObject {
    var rowIDs: [String]? { get }          // nil = not a list at all
    func moveVertical(_ delta: Int)        // ↑ / ↓
    func activate(_ rowID: String, autoPaste: Bool)  // ↩ and the click path
}
```

Four conformances — `ClipboardKeyboard`, `TerminalKeyboard`, `ShelfKeyboard`,
`MusicKeyboard` — registered into `model.keyboardPanels` at the end of `IslandModel.init`.

| deleted | replaced by |
|---|---|
| `rowCount(of:)` | `keyboardPanels[panel]?.rowIDs?.count` |
| `rowID(of:at:)` | the same array |
| `selectedRowIndex` | `rows.firstIndex(of:)` at the one call site |
| `paste(panel:rowID:autoPaste:)`'s switch | `keyboardPanels[panel]?.activate(_:autoPaste:)` |
| `cycleListPanel` + `[.clipboard, .terminal]` | `cyclePanel` over `navigablePanels` |
| `PanelID.isList` | `rowIDs != nil` |

`navigablePanels` is `PanelID.contentPanels.filter { keyboardPanels[$0] != nil }` — the
panels as they appear on screen, minus any without a conformance. **`←`/`→` now reach
all four content panels**, including Music, and step over Settings because it was never
in `contentPanels`.

**The empty-list distinction is why `rowIDs` is optional.** `nil` means "no list at
all" (Music); `[]` means "a list that is empty right now". The old code could not tell
them apart, which is the bug that killed the mode in phase 1.

**Shelf joined, and its view had to join too.** `↩` opens the file (`shelf.open`), which
already existed. `ShelfRow` gained the same `selected ? 0.11 : hovering ? 0.06 : 0` fill
as `HistoryRow`, the list gained a `ScrollViewReader` that follows the selection, and
each row is addressable by `.id(item.id.uuidString)` — the keyboard's row id is the UUID
*string*, so `ShelfItem`'s own `UUID` id would never have matched and `scrollTo` would
have silently done nothing.

**Music joined with no rows.** `rowIDs` is `nil`, so it takes part in `←`/`→` and has
no highlight. `↑`/`↓` call `SystemVolume.adjust`, `↩` is play/pause. That is what makes
it "navigation access and functionality" rather than a panel the arrows skip.

### Where reality differs from the plan

**1. Phases 8 and 9 (shelf highlight) are one commit.** They cannot be split: the
wrapper makes the shelf selectable, and without the highlight a selectable panel with no
visible selection is a bug rather than a step. Shipping the model half alone would mean
a commit where `↑` moves through shelf rows invisibly.

**2. The volume work is new code with no precedent in the repo.** There was no audio
code at all — `MediaRemote` has transport only, `SpotifyBridge` seeks only. `SystemVolume`
is ~90 lines of CoreAudio against the default output device. It tries the main element
first and falls back to channels 1 and 2, because a stereo device advertises the channels
and no main element, and writing only one channel would move half the volume.

**3. It cannot be verified from here.** No device, no audio. A machine that reports no
settable element fails silently, deliberately: the alternative is an error dialog for a
key press. There is also **no on-screen feedback** — the system volume HUD only appears
for the system's own volume keys — so the only confirmation is the sound.

### Phase 9 — the terminal shortcut

**Decision:** `⌥⇧⌘T`, at Ben's request.

**Why not `⇧⌘T`:** Reopen Closed Tab in Chrome, Safari and Firefox, Reopen Closed Editor
in VS Code and Sublime. Registered process-wide, it would be the `⇧⌘V` mistake again and
in the apps you are most likely to be in when you reach for terminal history.

**Why not `⌃⌘T`:** free, and symmetric with `⌃⌘V`. Offered and declined; three modifiers
buy near-certain freedom from collision at the cost of one-handed reach.

**`⌥⇧⌘T` is free as far as I know.** That is "not a documented system shortcut", not
"measured" — the same distinction `PLAN.md` §2 draws everywhere else.

**What was done:** `Slot.terminalShortcut = 14`, registered by
`installTerminalShortcut()` at launch beside the toggle key, dispatching `onTerminal` to
`openKeyboardMode(on: .terminal)`. The two named shortcuts now share one function with
the panel as a parameter.

**Kept out of the clipboard preset deliberately.** A preset that moved both chords would
offer `⇧⌘V`/`⇧⌘T`, and `⇧⌘T` is exactly the chord this avoids. Only the clipboard
shortcut is configurable because only it had a free choice.

**Behaviour change from phase 7:** neither named shortcut toggles any more. `⌃⌘V` on an
island that is already up lands on the clipboard and selects, rather than closing it.
`⎋` and `⌃⌥↓` are the close keys.

### Phase 10 — documentation

`README.md`: the intro captions, the panel table (Shelf `↩`, Music volume), and the
*Using it* bullets rewritten around one rule — the keyboard drives whatever is showing,
because the island is up. The old three-state "arms / armed" wording is gone, and so is
the claim that there is no arrow path to Shelf and Music.

`PLAN.md`: §2's shortcut paragraph, its registration table and its "mode group" note;
§3's key table and four bullets; §14's file table (two new rows); and §16, which now
describes the two changes that came after it — `keyboardMode` deleted, and the panels
declaring their own rows. §16's measured table gained three rows, two of them honest
"unverified".

**Deliberately not rewritten:** §8's phasing table, §9's risks and §10's decisions.
They are the record of a design that was replaced, and §16 opens by saying so. Editing
them would erase the reasoning that produced the current one, which is the only thing
that makes the history worth keeping.

---

## Round 2 — what is now where

| | |
|---|---|
| Commits | `109b867` arm on hover · `18e0475` panels declare rows · `470991d` terminal shortcut · this docs commit |
| Branch | `merge-kami`, 18 ahead of `master`, unpushed |
| Typecheck | clean at every commit and at the tip |
| Run state | phases 7–9 have never been built or launched |

### The rule, in one sentence

**While the island is open, the arrow keys belong to it**; `←`/`→` pick the panel,
`↑`/`↓` drive that panel, `↩` acts on the highlighted thing, `⎋` closes.

### Still to verify, in order of what would embarrass me most

0. ~~The exit audit~~ — **confirmed by Ben**: the keys come back after every exit.
   The release blocker from phase 5 onward is closed.
1. **`↑`/`↓` on Music.** `SystemVolume` is untested against real hardware, and a
   device with no settable element fails silently. If the volume does not move, the
   first thing to check is whether any element reported settable — not the arithmetic.
2. **The exit audit.** `⎋`, `↩`, a click away, `⌘Tab`. Any path that leaves
   `← → ↑ ↓ ↩ ⌤ ⎋` captured in the frontmost app is the release blocker it has been
   since phase 5.
3. ~~Held-arrow repeat~~ — **confirmed working and confirmed to feel right** at 60 ms. `SystemVolume` amplifies the problem: a
   non-repeating arrow means one sixteenth per press, which is slow to traverse.
4. **`←`/`→` through four panels.** The order comes from `PanelID.contentPanels`, so a
   press on Music should land back on Clipboard rather than stalling.
5. **Shelf highlight and scroll.** The row is addressable by `.id(item.id.uuidString)`
   and the scroll is keyed on `model.listSelection`; both are new and neither has run.

---

## Round 3 — open key, terminal key, and the hover report

### The hover report was a stale binary

`~/Applications/Dev Island.app` was built at **19:53**; `109b867` (arm on hover) lands at
**20:57**. The running process started at 21:02 but is executing that 19:53 binary, so
the behaviour Ben saw was the pre-hover build — arrow keys working only after `⌃⌥↓`,
which is exactly what phase 5 did. No code change was needed for it, and the check that
settles it is `ps -o lstart=` against the binary's mtime, not a rebuild.

### Key changes

| | was | is |
|---|---|---|
| Open / close | `⌃⌥↓` | `⌘⌥↓` |
| Terminal | `⌥⇧⌘T` | `⌘⌥B` |

`⌘⌥↓` costs VS Code's Insert Cursor Below, and its forks inherit that. `⌘⌥B` costs
Safari's Show Bookmarks. Both are registered for the life of the process, so both are
trades rather than free chords — noted in the code and in `PLAN.md` §16, not hidden.

The terminal chord stays out of the `ClipboardShortcut` preset on purpose: a preset
would offer `⇧⌘V` / `⇧⌘T`, and `⇧⌘T` is Reopen Closed Tab in three browsers and two
editors.

### The terminal shortcut is now switchable

New `@Published var terminalShortcutEnabled` (persisted, on by default), a Settings row
("Terminal shortcut", `settingsRowCount` 6 → 7), and a status-menu item. It is the only
way to refuse a chord that is otherwise fixed, and the open key cannot be refused — so
if `⌘⌥↓` turns out to be a problem in an editor, the fix is another code change, not a
setting. That asymmetry is deliberate: one of the two had a configurable preset already,
so only one got a second control.

### The volume, hardened before building

Three separate `return`s in `SystemVolume.adjust` are now the documented failure modes
(no default output device, no settable element, no readable element), and the read moved
from *the first element in the list* to *the first element that answers*. A device can
advertise a settable main element and still refuse to be read; taking the head of the
list would then have failed the whole adjustment while the two channels beside it were
usable. That is the bug worth catching before it is reported as "volume doesn't work".

Still unverifiable here: whether any of it moves the volume on real hardware.

---

## Round 4 — after the first working build

Confirmed live: hover arms the arrows, `↑`/`↓` move from a standing start, `⌘⌥B` lands
on the terminal, `↩` pastes and the arrows keep working afterwards. Three reports came
back.

### 1. Volume did nothing

**It is not the CoreAudio code.** A probe against the real device:

```
default device status=0 id=81
name: MacBook Pro Speakers
element 0: has=true settable=true getStatus=0 value=0.375
element 1: has=false
element 2: has=false
```

and a write/read round trip moved it 0.375 → 0.4375 → 0.375. The API call was never the
problem.

**What was:** two things, neither of them the arithmetic.

- **No feedback.** There is no system HUD for a CoreAudio volume write, so a working
  adjustment and a key that never arrived looked identical. The panel now borrows the
  artist line to show `Volume 44%` for a second.
- **The panel was often not Music.** The landing bug below meant `⌘⌥↓` could reopen on
  Shelf, where `↑`/`↓` move shelf rows.

A **failed** adjustment now writes `No volume control` to the same line, so "nothing
happened" and "this output device has no volume" are no longer the same experience. The
three failure modes (no device, no settable element, nothing readable) stay distinct
early returns for the same reason.

### 2. Music did not keep its panel

`keyboardLandingPanel` sent the landing panel to `lastListPanel` whenever the target had
no rows — which is Music. So closing on Music and reopening put you on whatever list was
last visited. The fallback existed because a panel with no list "had nowhere to put a
highlight", which stopped being true when the highlight became something only an arrow
press creates. Deleted, along with `lastListPanel`: `⌘⌥↓` now lands on `panelOnOpen` like
every other open path.

### 3. Settings is a navigation target

`SettingsRow` (new, `Panels.swift`) is the panel's row list: it is what the view renders
*and* what the arrows walk, so the two orders cannot drift. `settingsRowCount` is derived
from it instead of being a constant beside a hand-written list.

`〈↩〉` **advances** the highlighted row — a switch flips, a picker moves to its next value.
One verb for both, which is why there is no second key and no way to go backwards: the
sets are two to five items and cycling reaches everything.

`navigablePanels` moved from `contentPanels` to `allCases`, so `←`/`→` now walk all five
panels. Settings keeps its "detour" property: `collapse()` still sends you back to
`lastContentPanel`.

### Where this differs from what was asked

Nothing was declined. Worth recording that the volume fix was **a feedback fix plus a
landing fix**, not an audio fix — the audio code was correct on the first try and had
been measured as correct before the report arrived.

---

## Round 5 — repeat, volume direction, Settings highlight

### Holding an arrow

Carbon fires `kEventHotKeyPressed` once per physical press and has no release event, so
this had to be generated. `KeyRepeater` starts a 0.32 s delay on the press, then ticks
every 60 ms and asks `CGEventSource.keyState(.hidSystemState, key:)` whether the key is
still down. When it is not, the timer stops.

Polling the *hardware* state rather than waiting for an event is what makes this safe:
it also covers the cases where no release would ever arrive — the island collapsing
mid-hold, the app deactivating, the key being let go while another app had focus. The
repeater is stopped from `uninstallModeKeys()` as well, so a held key cannot outlive its
registration, and `HotKeys.deinit` stops it because the run loop owns the timer.

Only `↑`/`↓`. Holding `←`/`→` through the panels is a slide, not a repeat, and there is
nothing to count.

### Volume was inverted

`↑` sent `-1`, which is correct for a list — up is the *previous* row — and wrong for a
volume. Negated in `MusicKeyboard` only, with the reason written next to it, rather than
inverting the convention that every other panel relies on.

### Settings highlight stopped short of the row

The row's content is inset unevenly: `textInset` on the left, `textInset -
PillSize.regular.padding` on the right, because the pill's own padding has to be
subtracted so the last label lands on the text edge. The background was painted on that
uneven box, so the fill ended short on the right and read as a cropped band.

The row now claims `maxWidth: .infinity` before the fill is drawn, and the fill's inset
dropped from 4 pt to 2 pt. Content padding is unchanged — the fix is about what box the
background covers, not where the text sits.

### Confirmed live by this round

Hover arming, `⌘⌥B`, `↩` paste followed by working arrows, and the volume itself — the
level moves, which was the thing the probe had already predicted and the build could not
show.


---

## Round 6 — the highlight owns the row

The pill's own horizontal padding was being subtracted from the row's trailing inset
(`textInset - PillSize.regular.padding` = 0) so that the last pill's *label* landed on
the panel's text edge. The side effect is that the pill's *fill* ran to the row's edge,
and the highlight was inset 2 pt inside that — so an "On" pill sat 2 pt from the band
and read as overhanging it.

The row is now symmetric: `textInset` on both sides, content inside, highlight full
bleed with no extra inset. The trade is that the pill grid sits 8 pt further from the
right edge than it used to, so it no longer shares an edge with the section header text.
That is the cost of the highlight reading as a row rather than a band behind the content,
and it is the one Ben asked for.

### Release status

The exit audit — the blocker that has been open since phase 5 — is confirmed. The
remaining unverified items are the ones that need different hardware or a longer soak,
not different code.
