import AppKit
import Combine
import Foundation

final class IslandModel: ObservableObject {
    @Published var expanded = false {
        // Synchronous, not via a Combine sink: the window has to be at least as big
        // as the shape before SwiftUI renders the first frame of the animation, and
        // a `receive(on: RunLoop.main)` sink is only guaranteed to run later.
        didSet { onGeometryChange?() }
    }
    @Published var nowPlaying: NowPlaying?
    @Published var notchSize = CGSize(width: 185, height: 32)

    /// Which panel the island is showing. Each open selects `panelOnOpen`: this
    /// same panel when `reopensLastPanel` is on, `defaultPanel` otherwise.
    /// Persisted, so the last panel also survives a relaunch.
    @Published var activePanel = PanelID.music {
        didSet {
            onGeometryChange?()
            // Settings is a detour, never the panel to come back to.
            guard activePanel != .settings else { return }
            lastContentPanel = activePanel
            if activePanel.isList { lastListPanel = activePanel }
            // Previews build throwaway models; they must not overwrite the
            // user's real last panel.
            if !PreviewMode.active {
                UserDefaults.standard.set(activePanel.rawValue, forKey: Self.lastPanelKey)
            }
        }
    }

    /// The last panel that was not Settings; what closing on Settings goes back to.
    private var lastContentPanel = PanelID.clipboard

    /// The last panel that was a list; where the keyboard lands when the panel it was
    /// otherwise about to open has no rows to drive.
    private var lastListPanel = PanelID.clipboard

    /// Hides the per-panel controls — the history windows and the Autopaste pill —
    /// and the Frequent row, leaving each history panel as just its list. The
    /// controls live in the Settings panel either way. Persisted; off by default.
    @Published var cleanLayout: Bool {
        didSet { UserDefaults.standard.set(cleanLayout, forKey: Self.cleanLayoutKey) }
    }

    private static let cleanLayoutKey = "cleanLayout"

    /// Set when the island was opened from outside the hover path — the toggle key,
    /// the clipboard shortcut or the status menu.
    ///
    /// While it is set, "the pointer is not over the island" must not close it. Hover
    /// is what normally drives expansion, so without this the first mouse event
    /// anywhere else reads as "left the island" and collapses it about 30 ms after it
    /// opened, which made the menu items look like they did nothing at all.
    ///
    /// Lives here rather than on the controller because the collapse timer reads it,
    /// and that guard is the single authority on whether a collapse may happen — see
    /// `IslandController.scheduleCollapse`. `keyboardSelection` is the second reason
    /// not to collapse; they are separate concepts that share one guard.
    var pinnedOpen = false

    /// The panel opened on hover when `reopensLastPanel` is off. Persisted.
    @Published var defaultPanel: PanelID {
        didSet { UserDefaults.standard.set(defaultPanel.rawValue, forKey: Self.defaultPanelKey) }
    }

    /// Reopen on whichever panel was showing when the island closed, instead of
    /// always landing on `defaultPanel`. Persisted; on unless a fixed default
    /// panel is picked from the menu bar.
    @Published var reopensLastPanel: Bool {
        didSet { UserDefaults.standard.set(reopensLastPanel, forKey: Self.reopensLastPanelKey) }
    }

    /// What `expand()` is about to show.
    var panelOnOpen: PanelID { reopensLastPanel ? activePanel : defaultPanel }

    /// Where the keyboard lands when it is opened from the toggle key.
    ///
    /// `panelOnOpen` when that is a list, because opening where the user last was is
    /// the point of `reopensLastPanel`. Otherwise the last panel that had rows: an
    /// island opened into keyboard mode on Music would take the arrows and offer
    /// nothing for them to move, which reads as the keys having been stolen.
    var keyboardLandingPanel: PanelID {
        // An island that is already up arms where it is: the user is looking at a
        // panel, and moving them off it would be a change they did not ask for. A
        // closed island has not chosen yet, so it follows `panelOnOpen`.
        let target = expanded ? activePanel : panelOnOpen
        return target.isList ? target : lastListPanel
    }

    /// Set by a provider when its panel is degraded — e.g. terminal history
    /// needing `setopt INC_APPEND_HISTORY`. Rendered as a strip above content.
    @Published var panelNotice: String?

    /// A short message under the notch saying what the click did, for ~1.2 s.
    ///
    /// A sentence, not a tick: "did that paste, or did it only copy?" is the whole
    /// question, and a glyph cannot answer it. It sits *below* the island rather
    /// than in the chin because the chin has ~32 pt either side of the camera
    /// cutout — enough for artwork and bars, not for words.
    @Published private(set) var pasteToast: PasteToast? {
        didSet { onGeometryChange?() }
    }

    struct PasteToast: Equatable {
        let text: String
        /// Drives the glyph; the text carries the meaning.
        let pasted: Bool
    }

    /// Height of that message, and the gap above it.
    static let toastHeight: CGFloat = 26
    static let toastGap: CGFloat = 8

    private var toastWork: DispatchWorkItem?

    /// Auto-paste on every click. Off means copy-only, which is the same thing
    /// ⌥-click does — so the modifier keeps working either way.
    ///
    /// Persisted: this is a preference about how the app behaves, not view state.
    @Published var autoPasteEnabled: Bool {
        didSet {
            UserDefaults.standard.set(autoPasteEnabled, forKey: Self.autoPasteKey)
            panelNotice = pastePermissionNotice
        }
    }

    private static let autoPasteKey = "autoPasteEnabled"

    /// Why a click will only copy. Read from the live grant, not a cached copy, so
    /// granting Accessibility in System Settings clears it on the next panel open
    /// rather than needing a relaunch.
    var pastePermissionNotice: String? {
        guard autoPasteEnabled, !AccessibilityPaster.canPost else { return nil }
        return "Auto-paste needs Accessibility — click to open System Settings"
    }

    /// Called synchronously whenever something that changes `islandSize` changes.
    /// Set by `IslandController` once its window exists.
    var onGeometryChange: (() -> Void)?

    private static let defaultPanelKey = "defaultPanel"
    private static let lastPanelKey = "lastPanel"
    private static let reopensLastPanelKey = "reopensLastPanel"

    /// Set by the screenshot/launch flag so the island does not close while
    /// the pointer is elsewhere.
    var locksOpen = false

    /// While true, hovering will not reopen the island. Set while Spotlight is
    /// open, because the pointer is still sitting on the island.
    var suppressed = false

    /// Set while a drag is in flight or a context menu is tracking, so the 30 ms
    /// collapse does not fire while the pointer is legitimately outside the island.
    /// Lives here rather than on the controller because views need it too: a menu
    /// opened from a row moves the pointer off the island, and a drag-out leaves it
    /// entirely.
    var isInteracting = false

    let player = PlayerService()
    let clipboard = ClipboardService()
    let ignoreRules = IgnoreRules()
    let terminal: TerminalService
    let shelf = ShelfStore()

    /// Set when a drop lands, so the controller can tell a completed drop from a
    /// cancelled drag and put the previous panel back.
    var shelfDidReceiveDrop = false

    /// True while a file the island would take is over it. Drawn by the shelf.
    @Published var fileDropTargeted = false

    /// Files let go of anywhere on the island. Synchronous, so the flag is set
    /// before the controller's mouse-up check runs.
    func receiveFiles(_ urls: [URL]) {
        shelfDidReceiveDrop = true
        selectPanel(.shelf)
        _ = shelf.addFiles(urls)
    }

    // MARK: - Keyboard selection

    /// The global shortcut that opens the keyboard selection; nil when switched off.
    /// Persisted.
    @Published var clipboardShortcut: ClipboardShortcut? {
        didSet {
            UserDefaults.standard.set(clipboardShortcut?.rawValue ?? Self.shortcutOff, forKey: Self.clipboardShortcutKey)
        }
    }

    private static let clipboardShortcutKey = "clipboardShortcut"
    private static let shortcutOff = "off"

    /// A history row being driven from the keyboard. Like Windows' ⊞V: the island
    /// stays open without the pointer, and the keys move down the list.
    ///
    /// The **id**, not the index. Both lists change underneath the selection — a new
    /// copy arrives at row 0, zsh appends a command — and an index would silently
    /// move the highlight onto a different row while the user was not looking. The
    /// index is derived wherever one is actually needed.
    struct ListSelection: Equatable {
        var panel: PanelID
        var id: String
    }

    /// The row the keyboard is on, or nil when nothing is highlighted.
    ///
    /// This is **not** the mode. The island is keyboard-driven whenever it is open —
    /// its keys are registered on that basis, because a hovered island is one the
    /// pointer is on, not one parked under a resting cursor. This is display state:
    /// whether a row is drawn as selected.
    ///
    /// It is therefore created by the first arrow press rather than by opening, so a
    /// hover does not put a highlight on a row the pointer is nowhere near.
    ///
    /// A row id of `""` means the list is empty. No entry's id can be that, so every
    /// lookup fails and the row keys do nothing — the empty-list behaviour, with no
    /// separate flag for it.
    @Published private(set) var listSelection: ListSelection?

    /// Whether `id` in `panel`'s list is the selected row.
    func isSelected(_ panel: PanelID, id: String) -> Bool {
        listSelection?.panel == panel && listSelection?.id == id
    }

    /// Lands on `panel` with its first row selected.
    ///
    /// The two named shortcuts use this: `⌃⌘V` for the clipboard, and the terminal
    /// one. Hover does not, because there is no row to highlight until the user
    /// reaches for the keyboard.
    func beginKeyboardMode(on panel: PanelID) {
        guard panel.isList else { return }
        activePanel = panel
        listSelection = ListSelection(panel: panel, id: rowID(of: panel, at: 0))
    }

    /// Drops the highlight.
    ///
    /// `@Published` fires on every assignment even when the value is unchanged, and
    /// this runs on every collapse. The guard keeps a needless publish, and the view
    /// invalidation behind it, off the hover path.
    private func clearSelection() {
        guard listSelection != nil else { return }
        listSelection = nil
    }

    /// Moves the highlight, creating it on the first press.
    ///
    /// `↓` from nothing lands on the first row rather than the second, so the first
    /// key the user presses is the one that makes the selection appear. That is what
    /// lets a merely hovered island stay unhighlighted.
    func moveSelection(by step: Int) {
        let panel = listSelection?.panel ?? activePanel
        guard panel.isList else { return }
        let count = rowCount(of: panel)
        guard count > 0 else { return }
        // A vanished id — the row aged out of the window, or was removed — lands on
        // the first row whichever way the user was going.
        let base = selectedRowIndex ?? (step > 0 ? -1 : 0)
        let next = min(max(base + step, 0), count - 1)
        listSelection = ListSelection(panel: panel, id: rowID(of: panel, at: next))
    }

    /// Puts one row on the pasteboard and pastes it, as clicking it does.
    ///
    /// The single place the two lists differ. It has to be a switch and cannot be
    /// generalised further: a clipboard row must bump its frecency, and a terminal
    /// command must not be written into clipboard history — so each keeps its own
    /// paste method, and this is the six lines that choose between them.
    func paste(panel: PanelID, rowID: String, autoPaste: Bool) {
        switch panel {
        case .clipboard:
            guard let entry = clipboard.visible.first(where: { $0.id == rowID }) else { return }
            pasteClipboard(entry, autoPaste: autoPaste)
        case .terminal:
            guard let entry = terminal.visible.first(where: { $0.id == rowID }) else { return }
            pasteTerminal(entry, autoPaste: autoPaste)
        default:
            break
        }
    }

    /// Pastes the selected row.
    ///
    /// There is no copy-only variant: `↩` already writes the row to the pasteboard
    /// before pasting it, so a second key for "copy instead" only restated what the
    /// first one does. ⌥-click on a row still copies without pasting, for the mouse —
    /// that path exists because the mouse has no Return to press.
    ///
    /// Nothing to paste is a no-op, not an exit. The island's keys are registered
    /// because it is open, not because a row is selected, so there is no mode to end
    /// here — and when something *is* selected the paste closes the island anyway,
    /// which is what drops the highlight.
    func pasteSelection() {
        guard let selection = listSelection, let row = selectedRowID else { return }
        paste(panel: selection.panel, rowID: row, autoPaste: true)
    }

    /// The selected row's id, or nil when there is not one: no row selected, or an
    /// empty list, whose placeholder id matches nothing.
    private var selectedRowID: String? {
        guard let selection = listSelection, selectedRowIndex != nil else { return nil }
        return selection.id
    }

    /// Index of the selected row in its own list, derived rather than stored.
    private var selectedRowIndex: Int? {
        guard let selection = listSelection else { return nil }
        switch selection.panel {
        case .clipboard: return clipboard.visible.firstIndex { $0.id == selection.id }
        case .terminal: return terminal.visible.firstIndex { $0.id == selection.id }
        default: return nil
        }
    }

    private func rowCount(of panel: PanelID) -> Int {
        switch panel {
        case .clipboard: return clipboard.visible.count
        case .terminal: return terminal.visible.count
        default: return 0
        }
    }

    private func rowID(of panel: PanelID, at index: Int) -> String {
        switch panel {
        case .clipboard:
            let rows = clipboard.visible
            return rows.indices.contains(index) ? rows[index].id : ""
        case .terminal:
            let rows = terminal.visible
            return rows.indices.contains(index) ? rows[index].id : ""
        default:
            return ""
        }
    }

    /// Follows the highlight to whichever panel the user navigated to.
    ///
    /// With nothing selected there is nothing to retarget: switching panels by icon or
    /// by `⌥`-number is not a request to put a highlight on a row. Once something is
    /// selected, a panel change moves it to that panel's first row, or drops it when
    /// the panel has no rows to hold one.
    ///
    /// An **empty** list keeps `""` as its id. Nothing matches, so the row keys do
    /// nothing, but the highlight survives — passing through an empty list on the way
    /// to another one is an ordinary move.
    private func retargetSelection(to panel: PanelID) {
        guard listSelection != nil else { return }
        guard panel.isList else {
            listSelection = nil
            return
        }
        listSelection = ListSelection(panel: panel, id: rowID(of: panel, at: 0))
    }

    private var cancellables = Set<AnyCancellable>()

    init() {
        let stored = UserDefaults.standard.string(forKey: Self.defaultPanelKey)
        // The default moved from music to clipboard. A stored "music" is the old
        // default rather than a choice, so migrate it instead of leaving existing
        // installs on a panel the user never picked.
        let chosen = stored.flatMap(PanelID.init(rawValue:))
        let initial = (chosen == .music || chosen == .settings ? PanelID.clipboard : chosen) ?? .clipboard
        self.defaultPanel = initial
        let reopens = UserDefaults.standard.object(forKey: Self.reopensLastPanelKey) as? Bool ?? true
        self.reopensLastPanel = reopens
        // Unlike the default, a stored "music" here is a real choice: it is
        // whatever was showing last.
        let last = UserDefaults.standard.string(forKey: Self.lastPanelKey)
            .flatMap(PanelID.init(rawValue:))
            .flatMap { $0 == .settings ? nil : $0 }
        let opening = reopens ? (last ?? initial) : initial
        self.activePanel = opening
        self.lastContentPanel = opening
        self.cleanLayout = UserDefaults.standard.bool(forKey: Self.cleanLayoutKey)
        self.autoPasteEnabled = UserDefaults.standard.object(forKey: Self.autoPasteKey) as? Bool ?? true
        switch UserDefaults.standard.string(forKey: Self.clipboardShortcutKey) {
        case nil: self.clipboardShortcut = .default
        case Self.shortcutOff: self.clipboardShortcut = nil
        case let stored?: self.clipboardShortcut = ClipboardShortcut(rawValue: stored) ?? .default
        }
        self.terminal = TerminalService(rules: ignoreRules)

        player.$nowPlaying
            .receive(on: RunLoop.main)
            .sink { [weak self] track in self?.nowPlaying = track }
            .store(in: &cancellables)

        // The shelf is the only panel whose size comes from data rather than a
        // constant, so a change in item count has to do two things the plain
        // property observers cannot: invalidate this object, so SwiftUI
        // re-evaluates `islandSize` and the shape animates to the new height, and
        // ask for the window resize. Without the first, the window grew but the
        // shape did not, and the newly added row was clipped until something else
        // happened to re-render.
        shelf.$items
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                guard let self else { return }
                self.objectWillChange.send()
                self.onGeometryChange?()
            }
            .store(in: &cancellables)
    }

    // MARK: - Geometry

    /// Idle: exactly the camera cutout (no pixels, so invisible).
    /// Playing: the cutout plus a wing either side for artwork and a waveform,
    ///          which is real menu-bar screen but reads as one black band.
    /// Expanded: a black panel flush with the top edge, NotchNook style.
    var islandSize: CGSize {
        if expanded {
            switch activePanel {
            case .shelf:
                // The one panel whose height follows its contents.
                return CGSize(
                    width: activePanel.preferredSize.width,
                    height: PanelID.shelfHeight(forItems: shelf.items.count, notchHeight: notchSize.height)
                )
            case .music:
                // Grows with the notch, so a taller menu bar does not eat the
                // padding under the artwork.
                return CGSize(
                    width: MusicLayout.panelWidth,
                    height: MusicLayout.panelHeight(notchHeight: notchSize.height)
                )
            case .settings:
                return CGSize(
                    width: activePanel.preferredSize.width,
                    height: PanelID.settingsHeight(notchHeight: notchSize.height)
                )
            case .clipboard, .terminal:
                return activePanel.preferredSize
            }
        }
        // Idle, the closed notch is 2pt wider than the cutout. While music plays it
        // grows a wing either side: each a square as tall as the band, so the
        // artwork and the equaliser get the same padding on every side (see
        // `WingContent`), plus the body's inset from the window.
        //
        // macOS draws its own now-playing live activity further along the menu bar,
        // so both are visible — accepted deliberately: ours sits at the notch, where
        // the island is, and the system's is somewhere else entirely. Ours used to
        // cost 3.8% of a core while it animated; the equaliser is Core Animation
        // now, which the window server interpolates, so it costs nothing.
        let playing = nowPlaying?.isPlaying == true
        let width = playing
            ? notchSize.width + 2 * notchSize.height + 2 * IslandMetrics.closedInset
            : notchSize.width + 4
        return CGSize(width: width, height: notchSize.height)
    }

    /// What the window has to be. Normally the island; while a toast is up the
    /// window grows downwards so there is somewhere to draw it — the shape stays the
    /// island's size, and the extra band is transparent.
    var windowSize: CGSize {
        let island = islandSize
        guard pasteToast != nil else { return island }
        return CGSize(width: island.width, height: island.height + Self.toastGap + Self.toastHeight)
    }

    /// The island is always pinned to the top edge of the display.
    var islandTopGap: CGFloat { 0 }

    // MARK: - Panels

    func selectPanel(_ panel: PanelID) {
        guard panel != activePanel else { return }
        activePanel = panel
        // A panel reached from the keyboard follows the mode; one reached any other
        // way is a real choice and the mode ends. `retargetSelection` is the no-op
        // when no row is selected.
        retargetSelection(to: panel)
    }

    // MARK: - Presentation

    /// Opens the island.
    ///
    /// `panel` overrides what `panelOnOpen` would choose, which exists for the keyboard:
    /// the mode has to land on a list, and setting `activePanel` afterwards would open
    /// on the old panel for a frame and then jump. Nil keeps the hover behaviour.
    func expand(on panel: PanelID? = nil) {
        guard !expanded, !suppressed else { return }
        activePanel = panel ?? panelOnOpen
        expanded = true
    }

    func collapse() {
        // Above the guard, deliberately. A collapse that arrives with `expanded`
        // already false would otherwise leave a highlight on a window that is gone.
        clearSelection()
        guard expanded else { return }
        expanded = false
        // One place, because `collapse()` is reached from every hiding path: the
        // hover timer, the toggle key, a paste, Spotlight, a display change.
        pinnedOpen = false
        if activePanel == .settings {
            activePanel = lastContentPanel
        }
    }

    /// Moves to the next or previous **list** panel, wrapping between the two.
    ///
    /// The only cycling left. It does not walk every panel, and cannot: reaching Shelf
    /// or Music would end the mode, which is the opposite of what an arrow press is
    /// asking for. Deriving it from `PanelID.allCases` would also make the destination
    /// depend on declaration order, which is a display concern.
    ///
    /// This replaced `cyclePanel`, which walked all five panels for the `⌃⌥←/→` and
    /// `⌥Tab` chords. Both are gone: panels are reachable by number at any time, and by
    /// arrow once the mode is armed.
    func cycleListPanel(by step: Int) {
        let lists: [PanelID] = [.clipboard, .terminal]
        guard let index = lists.firstIndex(of: activePanel) else { return }
        let next = (index + step + lists.count) % lists.count
        selectPanel(lists[next])
    }

    // MARK: - Clipboard

    /// Copies an entry back and, when asked and permitted, pastes it into whatever
    /// app had focus. The panel never activates the app, so focus is already where
    /// the user left it — there is no focus to restore.
    func pasteClipboard(_ entry: ClipEntry, autoPaste: Bool) {
        guard clipboard.write(entry) else { return }
        deliverPaste(autoPaste: autoPaste && autoPasteEnabled)
    }

    /// Terminal commands paste with the trailing newline stripped: history is full
    /// of one-shot destructive commands, and a stray Return would run one.
    func pasteTerminal(_ entry: TerminalEntry, autoPaste: Bool) {
        var text = entry.command
        while text.hasSuffix("\n") || text.hasSuffix("\r") { text.removeLast() }
        guard clipboard.writeText(text) else { return }
        deliverPaste(autoPaste: autoPaste && autoPasteEnabled)
    }

    private func deliverPaste(autoPaste: Bool) {
        collapse()

        // Say what happened. `canPost` is the only signal for whether the keystroke
        // will land, and when it is false the text is still on the clipboard — so
        // claiming a paste would be a lie and "Copied" is the truthful message. The
        // Accessibility notice in `panelNotice` covers the case where the grant is
        // the problem.
        let willPaste = autoPaste && AccessibilityPaster.canPost
        showPasteToast(PasteToast(
            text: willPaste ? "Auto-pasted" : "Copied to clipboard",
            pasted: willPaste
        ))

        // Never gated on the check for the *attempt*: see `AccessibilityPaster`.
        guard autoPaste else { return }
        // Next runloop turn: the pasteboard write and the window teardown both have
        // to land before the keystroke, or the target app pastes the old contents.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
            AccessibilityPaster.postPaste()
        }
    }

    /// Shows the message for ~1.2 s. One timer, replaced rather than stacked, so
    /// repeated clicks cannot leave it on screen.
    private func showPasteToast(_ toast: PasteToast) {
        toastWork?.cancel()
        pasteToast = toast
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.toastWork = nil
            self.pasteToast = nil
        }
        toastWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2, execute: work)
    }

}

final class PlayerService: ObservableObject {
    @Published private(set) var nowPlaying: NowPlaying?

    private let remote = MediaRemote.shared
    private let spotify = SpotifyBridge.shared
    private var observers: [NSObjectProtocol] = []
    private var poll: Timer?
    private var spotifyIsSource = false
    private var lastArtworkURL = ""

    /// Latest session reported by the helper process. This is the only working
    /// way to see anything that is not Spotify — including a browser.
    private let stream = MediaStream()
    private var remoteTrack: NowPlaying?

    init() {
        remote.startObserving()

        stream.onUpdate = { [weak self] track in
            guard let self else { return }
            self.remoteTrack = track
            self.applyRemote()
            if ProcessInfo.processInfo.environment["ISLAND_MEDIA_PROBE"] == "1" {
                let line = "MEDIA \(track?.title ?? "nil") art=\(track?.artwork != nil ? "y" : "n")"
                FileHandle.standardError.write((line + "\n").data(using: .utf8)!)
            }
        }
        stream.start()

        for name in [Notification.Name.nowPlayingDidChange, .playingStateDidChange] {
            observers.append(NotificationCenter.default.addObserver(
                forName: name, object: nil, queue: .main
            ) { [weak self] _ in self?.refresh() })
        }

        // Spotify posts this on every track / state change, so titles and
        // artwork land immediately instead of waiting for the poll.
        observers.append(DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("com.spotify.client.PlaybackStateChanged"),
            object: nil,
            queue: .main
        ) { [weak self] _ in self?.refresh() })

        // No timer here: the controller starts polling when the island opens
        // and stops it when it closes, so a closed island costs nothing.
        refresh()
    }

    deinit {
        observers.forEach(NotificationCenter.default.removeObserver)
        poll?.invalidate()
        stream.stop()
    }

    /// Ends the helper process on a normal quit.
    ///
    /// Not only hygiene: a leaked `perl` child would keep streaming to a closed
    /// pipe. It usually dies on SIGPIPE at the next write, but relying on that is
    /// a coin flip, so ask.
    func shutdown() {
        stream.stop()
    }

    /// Runs the 1.5 s AppleScript refresh. Called only while the island is open.
    func startPolling() {
        guard poll == nil else { return }
        poll = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            self?.refresh()
        }
        // Don't show stale state for up to 1.5 s after opening.
        refresh()
    }

    func stopPolling() {
        poll?.invalidate()
        poll = nil
    }

    /// Spotify takes precedence whenever it is actually **playing**: its bridge
    /// knows the album and the exact position, and it is the source this app was
    /// built around. Anything else — a browser, Music, VLC — comes from the stream.
    func refresh() {
        guard spotify.isRunning else {
            applyRemote()
            return
        }
        spotify.fetch { [weak self] snapshot in
            guard let self else { return }
            if let snapshot, snapshot.isPlaying {
                self.apply(snapshot)
                return
            }
            // Spotify is open but not playing. A paused Spotify must not mask a
            // browser that is; the stream knows what is really current.
            if self.remoteTrack != nil {
                self.applyRemote()
            } else if let snapshot {
                self.apply(snapshot)
            } else {
                self.spotifyIsSource = false
                self.nowPlaying = nil
            }
        }
    }

    /// Publishes what the stream last reported, carrying artwork across updates
    /// that arrive without it — see `NowPlaying.carryingArtwork(from:)`.
    private func applyRemote() {
        spotifyIsSource = false
        nowPlaying = remoteTrack?.carryingArtwork(from: nowPlaying)
    }

    private func apply(_ snapshot: SpotifySnapshot) {
        spotifyIsSource = true
        let keepArtwork = snapshot.artworkURL == lastArtworkURL
        nowPlaying = NowPlaying(
            title: snapshot.title,
            artist: snapshot.artist,
            album: snapshot.album,
            duration: snapshot.duration,
            elapsed: snapshot.position,
            rate: snapshot.isPlaying ? 1 : 0,
            timestamp: Date(),
            artwork: keepArtwork ? nowPlaying?.artwork : nil
        )

        guard snapshot.artworkURL != lastArtworkURL else { return }
        lastArtworkURL = snapshot.artworkURL
        let url = snapshot.artworkURL
        spotify.artwork(for: url) { [weak self] image in
            guard let self, let image, self.lastArtworkURL == url,
                  var current = self.nowPlaying
            else { return }
            current.artwork = image
            self.nowPlaying = current
        }
    }

    // MARK: - Transport

    func toggle() {
        if spotifyIsSource {
            spotify.command("playpause")
        } else {
            remote.togglePlayPause()
        }
        refreshSoon()
    }

    func next() {
        if spotifyIsSource {
            spotify.command("next track")
        } else {
            remote.next()
        }
        refreshSoon()
    }

    func previous() {
        if spotifyIsSource {
            spotify.command("previous track")
        } else {
            remote.previous()
        }
        refreshSoon()
    }

    func seek(to seconds: Double) {
        if spotifyIsSource {
            spotify.seek(to: seconds)
        } else {
            remote.setElapsedTime(seconds)
        }
        if var track = nowPlaying {
            track.elapsed = seconds
            track.timestamp = Date()
            nowPlaying = track
        }
        refreshSoon()
    }

    private func refreshSoon() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            self?.refresh()
        }
    }
}
