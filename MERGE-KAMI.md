# Merging `origin/Kami`: what actually collides

> **Superseded in two places.** This was written before the merge. The panel index
> mapping must use `allCases`, not `contentPanels`, and unifying `togglePicker()`
> with `expandWithoutPointer()` needs the panel-to-restore captured *before*
> expanding. `PLAN.md` §15 has both corrections and the record of what was actually
> done. Kept as review history.

A dry run plus a hand-inspection, so the merge is a set of decisions rather than a
session of resolving conflict markers. Nothing had been merged when this was
written; `origin/Kami` was read only.

## The shape of the problem

`origin/Kami` is **one commit (`d551542`) on top of `56d7f83`** — the same parent master
was on before the shortcut change. It is not a feature branch sitting on top of current
master; it is a parallel branch from the same root, and it carries the *pre-shortcut*
versions of the files master has since rewritten.

That is the whole source of the conflict: master replaced the panel-key design and the
handler lifecycle in `HotKeys.swift`, and Kami replaced the same file with a different
feature built on the old design.

| | |
| --- | --- |
| Divergence | 11 files, +1622 / −406 |
| Dry run | `git merge-tree --write-tree master origin/Kami` |
| Conflicted files | 4 |
| Conflict regions | 13 |

The dry run is worth doing yourself before starting; it writes nothing.

## What merges cleanly, and whether the result is right

Clean merges are not automatically correct ones, so both checked:

| File | Result | Correct? |
| --- | --- | --- |
| `Sources/App.swift` | clean | **Yes** — verified from the merged tree: keeps master's `Expand Island → expand()`, and Kami's `Collapse Island` and `toggle()` are gone. Brings in the clipboard-shortcut submenu, "Last Used", clean layout, and `PanelID.contentPanels` for the default submenu |
| `Sources/IslandModel.swift` | clean | Likely — picker state, selection and `clipboardShortcut` land alongside master's `pinnedOpen`-free model; no shared properties |
| `Sources/IslandView.swift` | clean | Yes — master never touched it, so Kami's ~600 lines apply unmodified |
| `Sources/Panels.swift` | clean | Only `PanelID.settings` and the size table; see the panel-count decision below |
| `Sources/FileDropView.swift` | new file | No conflict possible |
| `Sources/HotKeys.swift` | **9 regions** | The real work |
| `Sources/IslandController.swift` | **1 region** | The `init` wiring block only |
| `PLAN.md` | 2 regions | Documentation |
| `README.md` | 1 region | Don't hand-merge — see below |

## The merge decision for `HotKeys.swift`

Master and Kami solved the same structural problem independently and **agree**: both
moved the Carbon handler to the process lifetime and separated hotkey groups by
lifetime. Master calls it `installEventHandler()` + `install()` / `installToggle()`;
Kami calls it `installHandler()` + `install()` / `installPickerKeys()` /
`setClipboardShortcut()`. Same shape, different names.

Master's naming should win, because it is the version with `installToggle()` and the
`toggleRef` stored separately — and because `HotKeys`' own comment explains why
`uninstall()` must not touch the handler.

**Keep from master:** the panel-key table (`⌥1`–`⌥4`, `⌃⌥←`/`⌃⌥→`, `⌥Tab`/`⌥⇧Tab`
aliases), `installToggle()`/`toggleRef`, and the reasoning comments.

**Take from Kami:** `onPicker` / `onPickerKey`, `PickerKey`, `installPickerKeys()` /
`uninstallPickerKeys()`, `setClipboardShortcut()`, and `ClipboardShortcut`.

**Drop from Kami:** `panelKeys` with `panelModifiers = cmdKey | optionKey`. Merging it
as written restores `⌥⌘1`–`⌥⌘5`, which is the family the shortcut change moved away
from because it did not reliably arrive — and `PLAN.md` §2 would then be documenting
behaviour the code no longer has.

**One trap:** `Slot` is a shared raw-value namespace and both branches inserted into it
at different offsets. Master: `previous = 5, next = 6, toggle = 7`. Kami: `panel5 = 5,
previous = 6 … close = 14`. A careless resolution produces duplicate raw values. Swift
rejects that at compile time, so it fails loudly — but expect to renumber the whole
enum by hand rather than trust the markers.

## Two semantic problems the text merge will not catch

These are the reason this needs a person rather than `-X theirs`.

### 1. Collapse is protected by two different mechanisms

| | Mechanism | Where |
| --- | --- | --- |
| Master `pinnedOpen` | stops a collapse being **scheduled** | `handleMouse` early return |
| Kami `pickerActive` | stops a scheduled collapse **firing** | `scheduleCollapse` timer guard |

In the merged tree both exist, each guarding only its own flag. A pinned island survives
only because `handleMouse` returns before reaching `scheduleCollapse()`; the timer
itself still has no idea `pinnedOpen` exists. Any future path that schedules a collapse
without going through `handleMouse` collapses a pinned island — exactly the bug
`pinnedOpen` was added to fix.

This is what the review meant by coordinated rules rather than one replacement state:

```swift
guard let self,
      !self.model.locksOpen,
      !self.model.isInteracting,
      !self.model.pickerActive,
      !self.pinnedOpen,              // add
      !self.inHotZone(NSEvent.mouseLocation)
else { return }
```

Keep the `handleMouse` early return as well — it also suppresses `wasInside` churn — but
the timer guard becomes the single authority.

### 2. Two open paths that should be one

Kami's `togglePicker()` already does master's `expandWithoutPointer()` work inline:
clears `suppressed` behind a `SpotlightState.isOpen` check, attaches fullscreen, calls
`orderFrontRegardless()`, refreshes the mouse policy. Same logic, written twice.

Merged, `togglePicker()` should call `expandWithoutPointer()` and then `model.openPicker()`.

`openPicker()` then needs its expansion removed — but **watch the order**, because
`model.expand()` resets `activePanel = defaultPanel`. Today Kami does:

```swift
activePanel = .clipboard      // set first
expanded = true               // bypasses expand(), so it is not reset
```

Going through `expandWithoutPointer()` reverses that, so the sequence has to be:
expand, *then* `selectPanel(.clipboard)`, *then* `pickerActive = true`. Get it backwards
and the picker opens on whatever the default panel is.

## The panel-count decision, before any hotkey work

Kami adds a fifth panel, `.settings`, which master does not have. It is in `rightPanels`,
it has its own size, and `PanelID.contentPanels` excludes it from being a default. Three
consequences:

- Master's key table has four panels. Either add `⌥5`, or accept that Settings is
  pointer-only — but decide, because `Slot.panel5` and the `onPanel` index mapping both
  depend on it.
- `onPanel` maps an index into `PanelID.allCases`. With settings present it must map
  into `contentPanels`, or the nth key lands on the wrong panel.
- The "registered only while expanded" prose in `PLAN.md` §2 is master's; Kami's says
  `⌥⌘1–5` are registered while the island is open. Taking either wholesale is wrong
  after the merge.

## Cost worth flagging: the picker's keys are unmodified

Kami registers **`↑` `↓` `↩` `⌤` `⎋` with no modifiers at all** while the picker is
open, plus `⌥↩` for copy-only. That is the Windows `⊞V` model and it is deliberate — the
comment explains the lifetime is bounded by the picker — but it is by far the widest
interception in the app: bare Return and Escape stop reaching the frontmost app while
the picker is up. Narrower than it sounds in practice, and worth an explicit yes rather
than inheriting it by merge.

Same question, smaller, for the clipboard shortcut presets: `⇧⌘V` is "Paste and Match
Style" in most apps, so making it the default detour means Dev Island takes a chord
users press constantly. `⌃⌘V` or `⌥⌘V` is the safer default even if `⇧⌘V` is the
familiar one.

## `README.md`: take master's, then add a section

Master's README is a rewrite around two recordings, so a hand-merge is all loss. Take
master's side (`git checkout --ours README.md` during the merge), then add a short
"Clipboard picker" section describing the chord and the `⊞V` behaviour. `PLAN.md` gets
the same treatment on its two regions: master's §2 Navigation stays, Kami's picker
sections are appended.

## Suggested order

1. Decide the panel-count question (4 or 5). Everything downstream depends on it.
2. Merge code first, docs last: `git merge origin/Kami`.
3. `HotKeys.swift` — rebuild the `Slot` enum, master's panel table, Kami's three groups.
4. `IslandController.swift` — one wiring block, both sets of closures.
5. Apply the two semantic fixes: `scheduleCollapse` guard, `togglePicker` →
   `expandWithoutPointer`, `openPicker` ordering.
6. Rebuild both docs from master's side.
7. Verify, in this order:

- `Collapse Island` absent from the menu, `Expand Island` still opens.
- Opened from the menu with the pointer nowhere near the notch: stays up (the
  `pinnedOpen` regression).
- Picker via its chord, pointer far away: stays up, arrows move, `↩` pastes, `⎋` closes
  and restores the previous panel.
- `⌥1`–`⌥4` land on the right panels after any renumbering.
- `⌥Tab` / `⌥⇧Tab` aliases still cycle.
- Spotlight handoff still suppresses reopen from both paths.
- Collapse then reopen: panel keys re-register (`uninstall()` did not take the handler).

## Questions for you

- Fifth panel: in or out?
- Picker's bare `↑ ↓ ↩ ⎋`: accepted as-is, or moved under a modifier?
- Clipboard-shortcut default: `⇧⌘V` (familiar, but steals Paste and Match Style) or
  `⌃⌘V`?
