# Dev Island — replace the keyboard layer, keep Kami's features

Written 15 Nov 2026. Implementation has started; see `mergeKami-implementation.md` for
what was actually built, decision by decision, and where it departs from this plan.

This supersedes the keyboard sections of `dev-island-merge-kami.md` (§3, §6.5 and the
key tables), and §5 of `MERGE-KAMI.md`. It does not supersede the merge itself: the
merge of `origin/Kami` stands, and Kami's feature work is kept whole. Only the
keyboard layer is rebuilt.

### Notes recorded at approval

Three things flagged while this was being reviewed, now written down so they are not
lost when the phases are done:

1. **§11 item 6 is a release gate, not a checklist entry.** Any exit path that leaves
   the bare keys captured in the frontmost app blocks the release. It is the one
   failure in this design that is invisible until someone else's app stops responding.
2. **The two GIFs are still an open call** (§13). Both are captioned with `⌃⌥→`, and
   `docs/panel-tour.gif` walks Clipboard → Terminal → Shelf → Music, which arrows can no
   longer do. Reword, re-record, or cut. Undecided.
3. **The branch is not squashed on landing** unless asked (§12). The rewrite deletes a
   keyboard design the merge commit added, so commit 4's message has to say so.

---

## 1. State of play

| | |
|---|---|
| Branch | `merge-kami`, tip `6723872` |
| `master` | `63c0998`; 0 behind, 8 ahead — a fast-forward, no conflicts possible |
| `origin/master` | `8b37562`; 10 behind `merge-kami` |
| `origin/Kami` | `d551542` on `56d7f83`, merged at `6f358ee` |
| Build state | `swiftc -typecheck` clean at every commit and at the tip |
| Run state | **nothing has been built, installed or launched this pass** |

Kami is not a refactor. `d551542` is a feature branch, and roughly 15% of it is
keyboard:

| file | lines changed | keyboard-related |
|---|---|---|
| `IslandView.swift` | 597 | 0 |
| `HotKeys.swift` | 174 | ~37 |
| `IslandController.swift` | 181 | ~29 |
| `IslandModel.swift` | 170 | ~31 |
| `FileDropView.swift` | 143 (new) | 0 |
| `App.swift` | 65 | ~9 |
| `Panels.swift` | 52 | 0 |

~106 keyboard lines out of ~1,600. The rest — shelf drop targets, `PanelID.settings`
and the Settings panel, last-panel reopening, drag reach across the island, the
notch-parameterised size table — is kept as merged.

`reopensLastPanel` is entirely Kami's: **zero** occurrences in `56d7f83`, fully
present in `d551542`. `HistoryPanel.swift` and the `FileDropView` operation gate are
not Kami's; they are commits `ca8af66` and `31a83bf` on this branch.

The merge commit `6f358ee` is already not a faithful merge of Kami's keyboard design:
it replaced `pickerSelection: Int` with id-based `ListSelection`, generalised the
picker to the terminal, and hand-rebuilt `HotKeys.swift` into three groups. This plan
is the next step in that series, not a departure from it.

---

## 2. The core change: the mode stops being a selection

Today the keyboard mode's lifetime *is* the selection —
`var keyboardSelectionActive: Bool { listSelection != nil }`
(`IslandModel.swift:194`). Three problems follow from that one line:

- `rowCount` is 0 for `.shelf`, `.music` and `.settings` (`IslandModel.swift:296-302`),
  and `retargetSelection` ends the mode when the first row id is empty
  (`IslandModel.swift:319-331`). So cycling onto a panel with no rows kills the mode.
- An **empty** list is indistinguishable from no mode: `beginKeyboardSelection`
  stores a `""` id, every lookup fails, and `pasteSelection` exits.
- `cyclePanel` walks `PanelID.allCases` (`IslandModel.swift:477-482`), so
  `→` from the terminal lands on Shelf and the mode dies. Pressing `→` twice from
  the clipboard would silently unregister every bare key.

Make the mode an explicit flag and all three disappear:

```swift
/// True while the island is being driven from the keyboard. Separate from
/// `listSelection`: the mode outlives any particular row, and an empty list is
/// still "in the mode", just with nothing to paste.
@Published private(set) var keyboardMode = false

/// Which row the mode is on. Nil only when the active panel is not a list.
@Published private(set) var listSelection: ListSelection?
```

`ListSelection` (`IslandModel.swift:184-192`) keeps its `{ panel, id }` shape and its
id-not-index guarantee: a new clipboard entry or an appended zsh line cannot move the
highlight. What changes is that it is no longer the mode.

**The mode exists only on list panels.** `.clipboard` and `.terminal` are lists;
`.shelf`, `.music` and `.settings` are not. This is deliberate — see §7.

---

## 3. The key set

| key | when | does |
|---|---|---|
| `⌃⌥↓` | always | open + arm → arm → close (three-state, §8) |
| `⌃⌘V` | always | open on the clipboard + arm — the same mode, not a second one |
| `⌥1`–`⌥5` | while expanded | jump to a panel; `⌥1`/`⌥2` keep the mode, `⌥3`–`⌥5` end it |
| `←` `→` | armed | cycle `.clipboard` ↔ `.terminal` |
| `↑` `↓` | armed | move the selected row |
| `↩` | armed | paste the selected row into the focused app |
| `⌤` | armed | same as `↩`, for a numeric keypad |
| `⎋` | armed | end the mode and close |

Removed outright, and not replaced:

| key | why it went |
|---|---|
| `⌃⌥←` / `⌃⌥→` | three keys to change panel; `←`/`→` replace them |
| `⌥Tab` / `⌥⇧Tab` | obsolete once arrows cycle; also the chord that was being taken from terminals |
| `⌃C` | SIGINT in a terminal, and the island steals it exactly when a terminal is focused |
| `⌘C` / `⌥↩` copy | `↩` copies and pastes anyway. `⌥`-click still copies without pasting (`HistoryPanel.swift:180-181`), so the mouse keeps the path the keyboard gives up |

What remains registered for the whole process is `⌃⌥↓` and `⌃⌘V` — both
two-modifier chords, neither of which an app relies on. Nothing a focused app needs
is captured while the island is merely hovered.

---

## 4. Registration groups

`HotKeys` keeps master's three-group structure and the single Carbon handler. The
panel group shrinks; the mode group grows and changes its trigger.

| group | lifetime | contents |
|---|---|---|
| always | the process | `⌃⌥↓`; `⌃⌘V` when the clipboard shortcut is on |
| panel | while expanded | `⌥1`–`⌥5` |
| mode | while `expanded && keyboardMode` | `←` `→` `↑` `↓` `↩` `⌤` `⎋` |

The mode group's registration condition is deliberately **two** independent terms.
`keyboardMode` alone would be one boolean standing between the user and unstoppable
arrow keys; `expanded` is cleared by `collapse()` whether or not the flag is, so a
missed flag write still unregisters.

`hotKeys.install()` / `uninstall()` stay tied to `handleExpansion`
(`IslandController.swift:841-856`). The mode group hangs off a new sink on
`$keyboardMode`, replacing the current one on `$listSelection`
(`IslandController.swift:238-247`).

Kami's names no longer describe the thing: it is a mode, not a picker, and it can
show a panel that has no rows. Rename while touching them —
`PickerKey` → `ModeKey`, `pickerKeys` → `modeKeys`, `installPickerKeys` →
`installModeKeys`, `pickerRefs` → `modeRefs`. Mechanical, but the alternative is
comments that lie.

---

## 5. Teardown — the one guard that can leave keys stolen

With `listSelection` as the flag, unregistration was structural: no row meant no
selection meant no keys. With a boolean it becomes a convention, and a missed write
leaves `← → ↑ ↓ ↩ ⌤ ⎋` captured in every app, with no visual cue, until relaunch.

So:

1. **One teardown point.** `keyboardMode = false` in `collapse()` and nowhere else.
   Everything already funnels through it: `⎋` (`IslandController.swift:404`), paste
   (`IslandModel.swift:504`), click-away, `⌘Tab`
   (`IslandController.swift:174-177`), collapse on hover-out, display change.
2. **Clear the flag above `collapse()`'s guard.** It currently opens with
   `guard expanded else { return }` (`IslandModel.swift:465-467`). If that returns
   early with `keyboardMode` still true, nothing left will clear it. Put
   `keyboardMode = false` on the first line of the body, before the guard.
3. **Never set the flag without `expand()` having succeeded.** Mirror the existing
   `guard model.expanded else { return }` in `toggleKeyboardSelection`
   (`IslandController.swift:395`) — Spotlight can refuse the open, and arming a mode
   on a window that never appeared registers keys with no UI to exit from.

`$keyboardMode` drives registration, so a stray `true` is visible in the tests in §11
as "keys still registered after collapse" rather than as a mystery.

---

## 6. Model changes (`IslandModel.swift`)

| line | now | after |
|---|---|---|
| 184-192 | `ListSelection { panel, id }` | unchanged |
| 192 | `@Published private(set) var listSelection` | stays, but is no longer the mode |
| 194 | `keyboardSelectionActive` = `listSelection != nil` | `keyboardMode: Bool`; delete `keyboardSelectionActive` |
| 210 | `beginKeyboardSelection(restoring:)` | `beginKeyboardMode(on:)` — takes the panel to land on, arms, selects its first row if it is a list |
| 219 | `endKeyboardSelection()` | delete; `collapse()` is the single exit |
| 231 | `moveSelection(by:)` | unchanged, except an empty list is a no-op rather than an exit |
| 296 | `rowCount(of:)` | unchanged |
| 319 | `retargetSelection(to:)` | a list panel sets `{ panel, rowID(at: 0) }` **including `""`**; a non-list panel clears the selection and the mode |
| 447 | `selectPanel(_:)` | unchanged; it already calls `retargetSelection` |
| 465 | `collapse()` | `keyboardMode = false` first, then the existing guard, then the rest |
| 477 | `cyclePanel(by:)` | replaced by `cycleListPanel(by:)` over `[.clipboard, .terminal]` |
| 504 | `deliverPaste` → `collapse()` | unchanged — reached by paste, so paste remains an exit |

`panelBeforeSelection` and its restore-on-exit logic are deleted with
`endKeyboardSelection`. Closing now leaves `activePanel` where it is, which is the
same thing `reopensLastPanel` wants anyway.

`pasteSelection(copyOnly:)` collapses to `pasteSelection()`: `handlePickerKey` was its
only caller (`IslandController.swift:401-402`) and there is no copy-only key left.
`paste(panel:rowID:autoPaste:)` is untouched — the mouse path calls it directly.

### Why `cycleListPanel` is a new function, not `cyclePanel`

`cyclePanel` walks `allCases`, which includes the three panels with no rows. The mode
cannot survive that walk, and `←`/`→` must start from a list panel by construction
(the mode only arms on one). So cycling is defined over the two list panels and wraps
between them.

Consequence, stated plainly: **there is no arrow path to Shelf or Music.** `⌥3` and
`⌥4` still reach them, and both end the mode.

---

## 7. Controller changes (`IslandController.swift`)

| line | now | after |
|---|---|---|
| 133-141 | `onPanelKey` `.step` forks on `keyboardSelectionActive` | `.select` only; the fork is deleted with the chord it existed for |
| 174-177 | app switch → `collapse()` if selection active | unchanged, but tests `keyboardMode` |
| 238-247 | `$listSelection` sink installs/uninstalls picker keys | `$keyboardMode` sink, `installModeKeys()` / `uninstallModeKeys()` |
| 384-397 | `toggleKeyboardSelection()` | `openKeyboardMode(on:)` + three-state toggle, below |
| 399-406 | `handlePickerKey` switch | `.cyclePanel`, `.moveRow`, `.paste`, `.close`; no `.copy` |
| 856-875 | collapse guard tests `keyboardSelectionActive` | tests `keyboardMode` |

### The three-state toggle

`⌃⌥↓` currently closes an expanded island (`IslandController.swift:305-311`). With
arming as a separate event, that would make "I want to drive this from the keyboard"
close the thing you were aiming at. So:

| state | `⌃⌥↓` does |
|---|---|
| closed | open on `panelOnOpen`, arm |
| open, not armed | arm — no window change |
| armed | collapse |

"Aiming at it" on a panel that is not a list: arm, and jump to the last list panel.
`⌃⌥↓` is a deliberate keyboard action, so landing somewhere the keyboard can act is
the right answer; landing armed on Music with no highlight would be an invisible mode.

`⌃⌘V` is the same function with `.clipboard` forced: `openKeyboardMode(on: .clipboard)`.
One mode, two entry points, no `togglePicker()` and no clipboard-only state machine.

### The collapse guard

`scheduleCollapse` (`IslandController.swift:856-875`) is the single authority and
already documents why `pinnedOpen` and the keyboard mode need one guard. The term
becomes `!self.model.keyboardMode`, and the comment needs updating: it currently says
"a selected row is driven from the keyboard", which is no longer what the flag means.

`pinnedOpen` and `keyboardMode` stay separate. A keyboard-opened island clears
`pinnedOpen` when the pointer arrives (`IslandController.swift:740-742`); the mode must
survive that, or the keys die the moment the mouse moves.

---

## 8. `HotKeys.swift` — the file, and the slot table

`Slot` is a shared raw-value namespace, so it gets renumbered once, by hand, with no
duplicate and no gap. Four slots out (`previous`, `next`, `tabForward`, `tabBackward`),
one out (`copy`), four in (`left`, `right`, `up`, `down`) — 0–13:

| slot | key | group |
|---|---|---|
| 0 | toggle | always |
| 1–5 | panel1–panel5 | panel |
| 6 | clipboard | always |
| 7 | left | mode |
| 8 | right | mode |
| 9 | up | mode |
| 10 | down | mode |
| 11 | paste | mode |
| 12 | pasteKeypad | mode |
| 13 | close | mode |

Keys (`HotKeys.swift:135-145`, `:153-157`, `:167-172`):

```swift
// panel — while expanded. ⌥-number is claimed by nothing; ⌘-number and ⌃-number
// are taken by tab switching and Spaces before Carbon is consulted.
Key(slot: .panel1, keyCode: UInt32(kVK_ANSI_1), modifiers: UInt32(optionKey))
// …panel2 through panel5, same shape, kVK_ANSI_2 … kVK_ANSI_5

// toggle — the process lifetime, so it keeps two modifiers.
Key(slot: .toggle, keyCode: UInt32(kVK_DownArrow), modifiers: UInt32(controlKey | optionKey))

// mode — bare, and only while the mode is armed. See §5.
Key(slot: .left,        keyCode: UInt32(kVK_LeftArrow),      modifiers: 0)
Key(slot: .right,       keyCode: UInt32(kVK_RightArrow),     modifiers: 0)
Key(slot: .up,          keyCode: UInt32(kVK_UpArrow),        modifiers: 0)
Key(slot: .down,        keyCode: UInt32(kVK_DownArrow),      modifiers: 0)
Key(slot: .paste,       keyCode: UInt32(kVK_Return),         modifiers: 0)
Key(slot: .pasteKeypad, keyCode: UInt32(kVK_ANSI_KeypadEnter), modifiers: 0)
Key(slot: .close,       keyCode: UInt32(kVK_Escape),         modifiers: 0)
```

Delete the `⌥Tab` justification paragraph (`HotKeys.swift:127-134`) rather than
leaving it orphaned: it argues for a chord that no longer exists. The same for the
bare-arrow paragraph at `:159-166`, which currently argues for *not* registering the
arrows this plan registers.

`dispatch` (`HotKeys.swift:289-312`) becomes:

```swift
case .panel1, .panel2, .panel3, .panel4, .panel5:
    onPanelKey?(.select(Int(slot.rawValue) - 1))
case .toggle:     onToggle?()
case .clipboard:  onClipboard?()
case .left:       onModeKey?(.cyclePanel(-1))
case .right:      onModeKey?(.cyclePanel(1))
case .up:         onModeKey?(.moveRow(-1))
case .down:       onModeKey?(.moveRow(1))
case .paste, .pasteKeypad: onModeKey?(.paste)
case .close:      onModeKey?(.close)
```

`ModeKey.cyclePanel` and `.moveRow` are named separately on purpose. Under the old
overload both were `.step(Int)`, which read identically at the call site while meaning
"change panel" and "change row".

`ClipboardShortcut` keeps all three presets and the `off` state; the default stays
`.controlCommandV`. `⇧⌘V` is Paste and Match Style in Chrome, Slack, Docs, Notion and
Safari, and this is a process-wide chord.

---

## 9. Edge cases, and what each now does

| situation | behaviour |
|---|---|
| `⌃⌥↓` on an empty clipboard | mode armed, no highlight, `↑↓` no-op, `←`/`→` still switch, `⎋` exits |
| `→` onto an empty terminal | mode survives; the empty state renders; row keys no-op |
| both lists empty | mode survives and cycles between two empty panels; `↩` exits |
| `⌥3` / `⌥4` / `⌥5` while armed | mode ends, keys unregister |
| `⌥1` / `⌥2` while armed | mode continues on that list's first row |
| click a row with the mode armed | pastes as today; `collapse()` ends the mode |
| `⌥`-click a row | copies without pasting, unchanged (`HistoryPanel.swift:180-181`) |
| pointer arrives at a keyboard-opened island | `pinnedOpen` clears; the mode does not |
| click away / `⌘Tab` | `collapse()`; keys unregister before the other app draws |
| Spotlight opens | `expand()` refuses; nothing is armed |
| display change drops the notch | existing path collapses; the mode goes with it |

---

## 10. What is not changing

Kami's feature work, all already merged and typecheck-clean, is untouched by the above:

- `FileDropView.swift` and the shelf drop targets, including the operation contract and
  `acceptsDragInFlight` gate from `31a83bf`.
- `PanelID.settings` and the Settings panel.
- `reopensLastPanel` / `lastPanel` persistence.
- Drag reach across the whole island.
- Status-menu items.
- `HistoryPanel.swift` (this branch's extraction, `ca8af66`).
- The clipboard history, terminal history, shelf, music and settings panels themselves.

---

## 11. Verification

Every step typechecks with:

```
swiftc -typecheck -parse-as-library -swift-version 5 \
  -target arm64-apple-macos26.0 \
  -framework AppKit -framework SwiftUI Sources/*.swift
```

Then, after a build and an explicit go-ahead to install:

1. `⌃⌥↓` on a closed island → opens on the last panel, first row highlighted.
2. `↑`/`↓` move the highlight; holding `↓` **does** auto-repeat *(unverified — Carbon
   may deliver repeats, may not; this is the difference between "scrolls" and
   "press it forty times")*.
3. `←`/`→` cycle clipboard ↔ terminal, including onto an empty terminal.
4. `↩` pastes into the app that had focus.
5. `⎋` closes; the media poll stops with it (`player.stopPolling` on collapse).

The one that matters, and the reason §5 exists:

6. After each exit above, and after clicking away, `⌘Tab`, and the toggle key, confirm
   that `←`/`→`/`↑`/`↓`/`↩`/`⌤`/`⎋` reach the frontmost app again. Any exit that leaves
   them captured is a release blocker, not a polish item.

Not testable without a notched display, and therefore listed as unverified throughout:
nothing in this pass has run on a device.

---

## 12. Commit plan

Each step typechecks on its own; the branch stays bisectable.

| # | commit | contents |
|---|---|---|
| 1 | `Make the keyboard mode a mode, not a selection` | `keyboardMode`, `beginKeyboardMode(on:)`, `retargetSelection` rewrite, `collapse()` teardown, delete `endKeyboardSelection` |
| 2 | `Register the mode's keys against the mode` | `$keyboardMode` sink, `installModeKeys`, the `expanded && keyboardMode` condition |
| 3 | `Cycle the two list panels with the arrows` | `cycleListPanel`, `ModeKey.cyclePanel` / `.moveRow`, delete the `onPanelKey` fork |
| 4 | `Drop the cycle chords and the Tab aliases` | `Slot` renumber 0–13, `←→↑↓` in, `⌃⌥←/→` and `⌥Tab` out, comments rewritten |
| 5 | `Arm the island from the toggle key` | three-state `⌃⌥↓`, `⌃⌘V` as the same mode |
| 6 | `Document the keyboard layer that exists` | README, PLAN.md, and the `6f358ee` note |

Not squashed on landing unless asked. The merge commit will contain a keyboard design
that commit 4 deletes; the commit message for #4 should say so, so the history reads
as a decision rather than an accident.

---

## 13. Open items

- **Auto-repeat on held arrows.** Unknown. Verified in step 2 of §11 or not at all.
- **`↩` paste delay.** `deliverPaste` waits 80 ms before posting the keystroke
  (`IslandModel.swift:521`). Fine for a click; unmeasured for a held arrow plus Return.
- **Documentation and the recordings.** Both GIFs are captioned with `⌃⌥→` and
  `docs/panel-tour.gif` walks Clipboard → Terminal → Shelf → Music, which arrows can no
  longer do. Reword the captions, or re-record, or cut the second GIF. Needs a call.
- **`player.startPolling()` on every expand.** `IslandController.swift:842` starts a
  1.5 s media refresh whenever the island opens, on any panel, which contradicts the
  "a provider's timers exist only while its panel is on screen" rule in `PLAN.md` §2.
  Pre-existing, separate from this work, ~15 lines to gate on `activePanel == .music`.
- **Unpushed.** `merge-kami` is 8 commits ahead of `master` and neither is pushed.
