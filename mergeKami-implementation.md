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
| 3 | `Cycle the two list panels with the arrows` | not started |
| 4 | `Drop the cycle chords and the Tab aliases` | not started |
| 5 | `Arm the island from the toggle key` | not started |
| 6 | `Document the keyboard layer that exists` | not started |

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
