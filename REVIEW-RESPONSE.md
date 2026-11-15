# Response to review of `7489249`, `8b37562`

Point-by-point on the eight items, plus two you missed. One item is answered
differently than you asked, because measuring it showed the premise was wrong.

Branch: `master`, `4fea189` on top of what you reviewed. Nothing else is pushed.

## Summary

| # | Item | Status |
| --- | --- | --- |
| 1 | `PLAN.md` "expanded only" contradiction | Fixed |
| 2 | `README.md` "four panel keys" | Fixed |
| 3 | Dead `IslandModel.toggleExpanded()` | Deleted |
| 4 | Dirty tree / uncommitted GIF | Committed |
| 5 | `⌥Tab` cost undocumented | Kept, cost documented |
| 6 | Silent failure of a taken `⌃⌥↓` | **Premise does not hold — see below** |
| 7 | `pinnedOpen` early return unexplained | Commented |
| 8 | 3.3 MB of GIFs, no LFS | Accepted as-is, deliberately |
| + | Dead loop in `menuWillOpen` | Deleted |
| + | `expandWithoutPointer` mouse policy | `refreshMousePolicy()` added |

`4fea189` — *Review fixes: correct the "only while expanded" claim, drop dead code*
— covers 1–5, 7, 8 and both extras. It type-checks and builds on its own; I checked
it in isolation, without the `⌃⌥↓` work, so the commit stands alone.

## 1 and 2 — you were right, and it was the same mistake twice

The "registered only while expanded" sentence was true before the open key moved to
the process lifetime, and then quietly stopped being true. Worse than wrong: it reads
authoritative, sits in the paragraph that explains the shortcut design, and is the
sentence a future reader would trust instead of the code.

`PLAN.md` now says the panel and cycle keys come and go with the island, and names
`⌃⌥↓` as the exception with its reason. `README.md` says "the panel and cycle keys".
Your count in item 2 was right and mine was not: `install()` registers six chords
(four numbers, two arrows) plus the two `⌥Tab` aliases.

## 3 — deleted

`IslandModel.toggleExpanded()` had one caller, which I rewrote to route through
`expandWithoutPointer()`. Your sharper point is the reason it had to go rather than
linger: the model version skips `pinnedOpen`, so whoever reached for the
obvious-looking one would reintroduce the collapse-after-30 ms bug with no signal that
they had picked the wrong method.

## 4 — committed

The re-trimmed `docs/autopaste.gif` is in `HEAD`. It is 4.00 s rather than 4.73 s; the
removed tail was the pointer travelling up to the menu bar to end the recording. The
toast lands at ~2.5 s, so the clip still shows the confirmation it is named for.

## 5 — kept, with the trade written down

I kept `⌥Tab` / `⌥⇧Tab` rather than dropping them, but your point stands: it was the
only chord in the file whose cost was unstated. `HotKeys.swift` now says what it costs
— Tab-with-Option taken from every app while the island is open, and an Accessibility
shortcut for some people — and why it stays anyway: the exposure is bounded by how
long the island is up, and Tab is what the hand reaches for when cycling. The entry
also records that the arrows already cycle, so dropping this one would cost only the
habit.

## 6 — the premise is wrong on macOS 26, so there is no warning to build

You wrote: *"If another app holds it, the user's first experience of the new feature
is 'the key does nothing'."* That part is right. What does not hold is that the
condition can be detected at registration time.

Measured on macOS 26, status from `RegisterEventHotKey` in every case:

| Chord | Result | Note |
| --- | --- | --- |
| `⌃⌥↓` | `noErr` | while a second copy of this app already held it registered |
| `⌃⌥↓` twice in one process | `noErr` | same signature and id |
| `⌘Space` | `noErr` | Spotlight |
| `⌃↑` | `noErr` | Mission Control |
| `⌘⇥` | `noErr` | app switcher |

So registration always succeeds, including for chords the system itself owns. What the
status code is therefore **not** is evidence of availability — which is enough on its
own to kill the warning, since it could never fire: an alert, a toast or a menu line
would all have been permanent dead code.

What the measurement does **not** establish is what happens at delivery, or which
process receives the event when two have claimed the same chord. My probe was a
command-line tool with no `NSApplication`, and it received no hotkey at all — including
a control chord nothing had claimed — so it measured nothing about delivery. *"A taken
chord fails at delivery"* and *"a `CGEventTap` would fix it"* are inferences, not
findings, and are corrected in the outcome note at the end of this document.

I built your item 6 as a menu line, then took it back out. The failure it was meant to
report has not been observed here either: the one occasion this key appeared dead, the
cause was `⌥↓` pressed without `⌃`. So the item is not "a real bug that cannot be
detected" but "a failure mode nobody has reproduced, reported by a return value that
does not vary".

Also worth correcting: `origin/Kami` is not a solution to this. Line 186 of its
`HotKeys.swift` is the same `NSLog` and the same silence. What it adds is a
menu-selectable preset (`⇧⌘V` / `⌥⌘V` / `⌃⌘V` / Off) — a workaround for a dead key,
not a report of one. Its panel keys are `⌥⌘1`–`⌥⌘5`, which is the family this round
moved away from for exactly the reason it stopped working.

**What would actually help** is making the open key rebindable, so a user whose chord
is eaten can move it. I prototyped it — a status-menu `Open Key` submenu with `⌃⌥↓`,
`⌃⌥↑`, `⌃⌥J`, `⌃⌥K`, persisted — and parked it rather than shipped it, because the
half you asked for (warn, then let them retry) cannot work and shipping the other half
alone would have meant quietly dropping what was reviewed. It is in a stash, not a
branch, and not in `master`.

The measurement is now recorded in `PLAN.md` §2 with the note that no warning should
be added later, so this does not get rebuilt by someone reading only the code.

## 7 — commented

One block, no restructuring: the `pinnedOpen` early return deliberately skips the
Spotlight re-arm, and now says so.

## 8 — accepted, not changed

3.3 MB of GIFs is not a problem worth solving on a personal repo, and `.gitattributes`
marking `*.gif` binary would not change how GitHub serves them. Noted and moving on.

## Two you did not list

- **`App.swift` dead loop.** `menuWillOpen` looped over top-level items matching
  `setDefaultPanel(_:)`, but those items only ever exist inside the submenu; the second
  loop did the work. Deleted.
- **`expandWithoutPointer()` statement order.** When the panel was invisible but not
  `suppressed`, it called `orderFrontRegardless()` without a following
  `refreshMousePolicy()`, leaving the click-through policy from the hidden state. The
  only path there today sets `suppressed` first, so it worked by luck. One line added.

## Open

- The open key is not rebindable in `master`. If you think that belongs in the app, say
  so and it can go in on its own — but without the warning attached to it.
- A passive `CGEventTap` is a *hypothesis* for making the key arrive even when another
  process has claimed it: untested here, since the probe could not measure delivery at
  all. Accessibility is already granted for auto-paste, so it is feasible. It would
  change how the key is captured rather than what is said about it, and deserves its
  own review rather than riding along with this one.

## Outcome

Recorded after review, so the archived version is not mistaken for the settled one.

- The reviewer retracted the recommendation to add a "shortcut in use" warning, and
  the claim that Kami's menu label solved it, on the grounds that both rest on the
  registration result. No warning UI is planned for `⌃⌥↓`.
- Two overclaims in the first draft are corrected above: *"fails at delivery"* and
  *"a `CGEventTap` would make the key work"* were stated as measurements. They are
  inferences, and the delivery probe could not have supported them — it received no
  hotkey at all, including one nothing had claimed.
- The reviewer also withdrew the suggestion that `pinnedOpen` and Kami's `pickerActive`
  should not both exist. They overlap on pointer-driven collapse but `pickerActive`
  additionally owns selection and the lifetime of the picker's global navigation keys.
  The merge needs one computed "do not collapse on pointer exit" condition fed by both
  flags, with each flag keeping its own set and clear sites.
- The remaining merge risk is `HotKeys.swift`: Kami's `⌥⌘1`–`⌥⌘5` panel keys would undo
  the shortcut change, and Kami adds a fifth panel (`.settings`). See `MERGE-KAMI.md`.
