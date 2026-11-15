import AppKit
import Combine
import SwiftUI

final class IslandPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

final class IslandController {
    private let panel: IslandPanel
    private let model: IslandModel
    private let host: NSHostingView<IslandRootView>
    /// The window's content view, with `host` inside it: the drop target for the
    /// whole island.
    private let dropView: FileDropView
    private let panelHost: PanelHost

    /// Whether the clipboard shortcut is actually registered — false when another
    /// app already holds that combination. Shown in the menu.
    var clipboardShortcutAvailable: Bool { model.clipboardShortcutAvailable }

    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var collapseWork: DispatchWorkItem?

    /// Size the window is currently set to.
    ///
    /// Deliberately allowed to be larger than the island. During a transition it
    /// holds the larger of the old and new sizes so the shape can animate inside it
    /// without ever being clipped, then settles back once the animation finishes.
    private var windowSize = CGSize.zero
    private var settleWork: DispatchWorkItem?

    /// The area the island occupied before it shrank. Shrinking lifts the bottom
    /// edge above the pointer, which would otherwise read as "left the island" and
    /// collapse it the moment the mouse moves.
    private var pointerCapture: CGRect?
    private var screenObserver: NSObjectProtocol?
    private var spotlightTimer: Timer?
    private var workspaceObserver: NSObjectProtocol?
    private var spaceObserver: NSObjectProtocol?
    private var cancellables = Set<AnyCancellable>()
    private var wasInside = false
    /// Drag pasteboard change count sampled on mouse-down. Kept only for the
    /// `ISLAND_DRAG_PROBE` log: the count turned out **not** to distinguish a
    /// content drag from a window drag, so nothing gates on it. See §5.
    private var dragCountAtMouseDown = -1

    /// Set when a drag carrying content is seen, so the stale pasteboard is only
    /// cleared after a real drag rather than on every mouse move.
    private var dragPasteboardDirty = false

    /// Panel that was showing before a drag auto-opened the shelf, so a cancelled
    /// drag can put it back. Only meaningful while `dragOpenedShelf` is true.
    private var panelBeforeDrag: PanelID?
    private var dragOpenedShelf = false

    /// The last press landed on the open island — possibly a shelf row about to be
    /// dragged out.
    private var dragBeganOnIsland = false

    /// A file was released over the open shelf and has not been accounted for yet:
    /// either `FileDropView` takes the drop, or the safety net in
    /// `restorePanelIfDragWasCancelled` reads it from the drag pasteboard.
    private var awaitingReleasedFiles = false
    private let hotKeys = HotKeys()

    /// `ISLAND_DRAG_PROBE=1` logs every dragged event with both gate signals, so
    /// risk 10 can be answered on a machine where this app holds the Accessibility
    /// grant — a standalone binary launched from a terminal does not inherit it.
    private static let dragProbe =
        ProcessInfo.processInfo.environment["ISLAND_DRAG_PROBE"] == "1"

    init() {
        let model = IslandModel()

        // Screenshot and debug overrides. Applied before the hosting view exists,
        // because `IslandRootView` seeds its `@State` shape size from the model:
        // creating the host first and replacing its root view later would keep the
        // first (closed) size, since SwiftUI preserves state across a root-view
        // swap of the same type.
        if let panel = ProcessInfo.processInfo.environment["ISLAND_PANEL"],
           let selected = PanelID(rawValue: panel) {
            model.selectPanel(selected)
        }
        if ProcessInfo.processInfo.environment["ISLAND_EXPANDED"] == "1" {
            model.expanded = true
            model.locksOpen = true   // stays open so it can be screenshotted
        }

        self.model = model
        self.panelHost = PanelHost(model: model)
        self.host = NSHostingView(rootView: IslandRootView(model: model))
        self.dropView = FileDropView(frame: NSRect(origin: .zero, size: model.islandSize))
        self.panel = IslandPanel(
            contentRect: NSRect(origin: .zero, size: model.islandSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        host.translatesAutoresizingMaskIntoConstraints = true
        host.autoresizingMask = [.width, .height]
        host.frame = dropView.bounds
        dropView.addSubview(host)

        panel.contentView = dropView
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.isMovable = false
        panel.isMovableByWindowBackground = false
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none
        panel.level = .mainMenu + 3
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.ignoresMouseEvents = true
        panel.worksWhenModal = true
        // Take key status only when a control actually needs keyboard input. Every
        // control here is a button, so in practice the panel never becomes key —
        // which is what keeps a synthetic ⌘V going to the app the user was in.
        panel.becomesKeyOnlyIfNeeded = true

        // Panel shortcuts only live while the island is open.
        hotKeys.onPanel = { [weak self] index in
            guard let self, index < PanelID.allCases.count else { return }
            self.model.selectPanel(PanelID.allCases[index])
        }
        hotKeys.onCycle = { [weak self] step in
            self?.model.cyclePanel(by: step)
        }
        hotKeys.onPicker = { [weak self] in self?.togglePicker() }
        hotKeys.onPickerKey = { [weak self] key in self?.handlePickerKey(key) }

        dropView.canAccept = { [weak model] in model?.expanded == true }
        dropView.onTargetChange = { [weak model] targeted in
            guard let model, model.fileDropTargeted != targeted else { return }
            model.fileDropTargeted = targeted
        }
        dropView.onDrop = { [weak model] urls in model?.receiveFiles(urls) }

        updateGeometry()
        installMonitors()
        observeScreens()

        // Siri AI becoming active is the instant signal that Spotlight opened.
        workspaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let self else { return }
            // Focus moving to another app ends the picker: its arrow and Return
            // keys are global while it is open, and must not follow the user
            // somewhere they did not expect them taken.
            if self.model.pickerActive {
                self.model.collapse()
            }
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            guard app?.bundleIdentifier == "com.apple.campo" else { return }
            self.hideForSpotlight()
        }

        // Entering or leaving fullscreen swaps Spaces; re-attach so the island
        // follows instead of being left behind.
        spaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self, self.panel.isVisible else { return }
            FullscreenSupport.attach(self.panel)
            self.panel.orderFrontRegardless()
        }

        // Nothing runs while the island is closed: no Spotlight watch, no player
        // poll, no panel provider. The chin still updates from notifications.
        model.$expanded
            .receive(on: RunLoop.main)
            .sink { [weak self] expanded in self?.handleExpansion(expanded) }
            .store(in: &cancellables)

        // The chin appearing or disappearing changes the closed window's size as
        // well as what it covers, so the frame and the click-through policy both
        // have to follow it.
        model.$nowPlaying
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.updateGeometry()
                self?.refreshMousePolicy()
            }
            .store(in: &cancellables)

        // The confirmation chin breathes out and back, and it covers live menu bar
        // while it is up, so the click-through policy has to follow it too.
        model.$pasteToast
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.refreshMousePolicy() }
            .store(in: &cancellables)

        // Switching panel changes the island's size, so the window has to be
        // resized in the same turn as the model changes. Otherwise the hot zone
        // and the frame disagree for a frame and the island collapses itself.
        model.$activePanel
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                guard let self else { return }
                // Remember where the island was before it shrinks, so switching to
                // a shorter panel does not strand the pointer outside the new bounds.
                let mouse = NSEvent.mouseLocation
                if self.panel.frame.contains(mouse) {
                    self.pointerCapture = self.panel.frame
                }
                self.updateGeometry()
            }
            .store(in: &cancellables)

        // The picker's keys are global while registered, so they follow its state
        // directly — no hop to the next run loop turn that could leave them live
        // after the picker has gone.
        model.$pickerActive
            .removeDuplicates()
            .sink { [weak self] active in
                if active {
                    self?.hotKeys.installPickerKeys()
                } else {
                    self?.hotKeys.uninstallPickerKeys()
                }
            }
            .store(in: &cancellables)

        // Emits the stored value on subscribe, which is what registers the shortcut
        // at launch.
        model.$clipboardShortcut
            .sink { [weak self] shortcut in
                guard let self else { return }
                let available = self.hotKeys.setClipboardShortcut(shortcut)
                if self.model.clipboardShortcutAvailable != available {
                    self.model.clipboardShortcutAvailable = available
                }
            }
            .store(in: &cancellables)

        // `@Published` does not replay, so an island opened by a launch flag never
        // produced the `$expanded` event and therefore never started polling. That
        // is exactly what a screenshot session wants to look like, and it made the
        // debug path behave differently from real use — which cost an afternoon of
        // chasing "the music panel is not updating".
        if model.expanded { handleExpansion(true) }

        // The shelf's height follows how many files are in it. `IslandModel` owns
        // that subscription and calls back through `onGeometryChange`, so this is
        // the only place the resize is triggered from.

        // The window must be grown before SwiftUI renders the first frame of the
        // shape animation, so this runs synchronously from the model's setters
        // rather than from a Combine sink. Assigned here, not earlier, because it
        // touches the window and panel, which do not exist yet at the top of init.
        model.onGeometryChange = { [weak self] in
            guard let self else { return }
            self.updateGeometry()
            self.refreshMousePolicy()
        }

        updateGeometry()
        refreshMousePolicy()
    }

    deinit {
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
        if let workspaceObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(workspaceObserver)
        }
        if let spaceObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(spaceObserver)
        }
        spotlightTimer?.invalidate()
        settleWork?.cancel()
    }

    func show() {
        FullscreenSupport.attach(panel)
        panel.orderFrontRegardless()
        refreshMousePolicy()
    }

    func toggleExpanded() {
        model.toggleExpanded()
    }

    /// Exposed for the status item's "Default Panel" submenu.
    var defaultPanel: PanelID {
        get { model.defaultPanel }
        set { model.defaultPanel = newValue }
    }

    /// The submenu's "Last Used" entry.
    var reopensLastPanel: Bool {
        get { model.reopensLastPanel }
        set { model.reopensLastPanel = newValue }
    }

    /// Exposed for the status item's "Clipboard Shortcut" submenu.
    var clipboardShortcut: ClipboardShortcut? {
        get { model.clipboardShortcut }
        set { model.clipboardShortcut = newValue }
    }

    /// Exposed for the status item's "Clean Layout" item.
    var cleanLayout: Bool {
        get { model.cleanLayout }
        set { model.cleanLayout = newValue }
    }

    // MARK: - Clipboard picker

    /// The clipboard shortcut: opens the island on the clipboard, or closes it if
    /// the picker is already up.
    private func togglePicker() {
        if model.pickerActive, model.expanded {
            model.collapse()
            return
        }
        // Hover re-arms the island on the next mouse move once Spotlight has gone;
        // a keypress is as good a sign that it has.
        if model.suppressed {
            guard !SpotlightState.isOpen else { return }
            model.suppressed = false
        }
        if !panel.isVisible {
            FullscreenSupport.attach(panel)
            panel.orderFrontRegardless()
        }
        model.openPicker()
        refreshMousePolicy()
    }

    private func handlePickerKey(_ key: HotKeys.PickerKey) {
        switch key {
        case .up: model.movePickerSelection(by: -1)
        case .down: model.movePickerSelection(by: 1)
        case .paste: model.pastePickerSelection(copyOnly: false)
        case .copy: model.pastePickerSelection(copyOnly: true)
        case .close: model.collapse()
        }
    }

    /// Ends the media helper process. Called on normal termination; see
    /// `PlayerService.shutdown()` for why that is worth doing at all.
    func shutdown() {
        model.player.shutdown()
    }

    /// Exposed for the status item's "Edit Ignore Rules" item.
    func editIgnoreRules() {
        model.ignoreRules.ensureFileExists()
        NSWorkspace.shared.open(model.ignoreRules.url)
    }

    private func startSpotlightWatch() {
        guard spotlightTimer == nil else { return }
        spotlightTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            guard let self, SpotlightState.isOpen else { return }
            self.hideForSpotlight()
        }
    }

    private func stopSpotlightWatch() {
        spotlightTimer?.invalidate()
        spotlightTimer = nil
    }

    private func hideForSpotlight() {
        model.collapse()
        model.suppressed = true
        panel.ignoresMouseEvents = true
        panel.orderOut(nil)
    }

    func collapse() {
        model.collapse()
    }

    // MARK: - Geometry

    private func targetScreen() -> NSScreen? {
        NSScreen.screens.first(where: { $0.notchRect != nil }) ?? NSScreen.main
    }

    private func updateGeometry() {
        guard let screen = targetScreen() else { return }
        if let notch = screen.notchRect, model.notchSize != notch.size {
            model.notchSize = notch.size
        }

        // Grow to the larger of the two sizes *before* the shape starts moving.
        // A window that is never smaller than the shape cannot show the desktop
        // through the island — that is risk 7, and this is why it is structural
        // rather than a faster animation. A window that is larger than the shape
        // only ever has transparent margin around an already-drawn shape.
        let target = model.windowSize
        let needed = CGSize(
            width: max(windowSize.width, target.width),
            height: max(windowSize.height, target.height)
        )
        applyWindowSize(needed, on: screen)

        guard needed != target else {
            settleWork?.cancel()
            settleWork = nil
            return
        }
        scheduleSettle(to: target)
    }

    /// Shrinks the window back to the island once the shape has finished animating.
    ///
    /// This is the only reason the window is ever larger than the island, and it is
    /// what keeps the island from inheriting BoringNotch's permanent dead zone: a
    /// window sized to the largest panel would swallow clicks in the menu bar
    /// beside every smaller one. The delay is a little past the spring's response so
    /// it cannot fire mid-flight and clip the last few frames; the area it removes
    /// is transparent either way.
    private func scheduleSettle(to target: CGSize) {
        settleWork?.cancel()

        // While the window is larger than a collapsing island it covers live
        // menu-bar space, so let clicks through until it has settled.
        if model.expanded {
            refreshMousePolicy()
        } else {
            panel.ignoresMouseEvents = true
        }

        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.settleWork = nil
            // Resolved here, not captured: a display change during the settle
            // would otherwise apply the old screen's geometry.
            guard let screen = self.targetScreen() else { return }
            self.applyWindowSize(target, on: screen)
            self.refreshMousePolicy()
        }
        settleWork = work
        let delay = model.expanded ? 0.6 : 0.45
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func applyWindowSize(_ size: CGSize, on screen: NSScreen) {
        if size != windowSize {
            windowSize = size
            // The host follows through its autoresizing mask.
            dropView.frame = NSRect(origin: .zero, size: size)
        }

        let frame = islandFrame(for: size, on: screen)
        if abs(frame.minX - panel.frame.minX) > 0.5
            || abs(frame.minY - panel.frame.minY) > 0.5
            || abs(frame.width - panel.frame.width) > 0.5
            || abs(frame.height - panel.frame.height) > 0.5 {
            panel.setFrame(frame, display: true)
        }
    }

    private func islandFrame(for size: CGSize, on screen: NSScreen) -> CGRect {
        CGRect(
            x: screen.frame.midX - size.width / 2,
            y: screen.frame.maxY - model.islandTopGap - size.height,
            width: size.width,
            height: size.height
        )
    }

    /// Current visible island, in screen coordinates. Normally equals the window
    /// frame, but is smaller while a deferred shrink is still animating.
    private var islandRect: CGRect {
        let size = model.islandSize
        return CGRect(
            x: panel.frame.midX - size.width / 2,
            y: panel.frame.maxY - model.islandTopGap - size.height,
            width: size.width,
            height: size.height
        )
    }

    /// The cutout itself stays hoverable while the card floats below it, so the
    /// pointer does not fall out of the island on the way down.
    private func inHotZone(_ point: CGPoint) -> Bool {
        islandRect.insetBy(dx: -8, dy: -4).contains(point)
    }

    /// How far a dragged file reaches. Hover needs the pointer on the notch; a
    /// file on its way to the shelf opens it from this far out, and keeps it open
    /// while it is anywhere near — so the drop target is already there when the
    /// file arrives, instead of appearing only once it is inside the cutout.
    private static let dragReach: CGFloat = 100

    /// The shelf's footprint plus `dragReach` around it, hanging from the top
    /// edge — or the island's, if it is already open and larger.
    private var dragZone: CGRect {
        guard let screen = targetScreen() else { return .zero }
        let width = max(PanelID.shelf.preferredSize.width, islandRect.width) + 2 * Self.dragReach
        let height = max(model.notchSize.height, islandRect.height) + Self.dragReach
        return CGRect(
            x: screen.frame.midX - width / 2,
            y: screen.frame.maxY - height,
            width: width,
            height: height
        )
    }

    /// Open, the panel owns every click inside it. Closed and idle, the window is
    /// only the physical cutout — no pixels, nothing behind it — so it stays
    /// interactive and can act as a drop target. Closed while playing, the chin
    /// covers live menu-bar space, so it must let clicks through.
    private func refreshMousePolicy() {
        if model.expanded {
            panel.ignoresMouseEvents = false
        } else if model.pasteToast != nil || model.nowPlaying?.isPlaying == true {
            // The playing chin overlaps live menu bar, so it must let clicks
            // through while still acting as a drop target through the drag detector.
            panel.ignoresMouseEvents = true
        } else {
            panel.ignoresMouseEvents = false
        }
    }

    // MARK: - Hover

    private func installMonitors() {
        // `.leftMouseDragged` is what makes the island reachable while a file is
        // being dragged at it: while a button is held the system posts dragged
        // events, not mouse-moved ones, so hover alone never fires during a drag.
        // `.leftMouseUp` ends the drag and releases the collapse guard.
        let mask: NSEvent.EventTypeMask = [
            .mouseMoved, .leftMouseDown, .leftMouseDragged, .leftMouseUp
        ]
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] event in
            self?.handleMouse(event)
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
            self?.handleMouse(event)
            return event
        }

        // Start from a known-empty drag pasteboard, so a drag that began before
        // this process launched cannot be read as content.
        if NSPasteboard(name: .drag).types?.isEmpty == false {
            NSPasteboard(name: .drag).clearContents()
        }
    }

    /// True when the drag pasteboard is carrying a file the shelf can take.
    ///
    /// Files only, matching what the shelf accepts: dragging text or a link at the
    /// notch should do nothing, because copying is one keystroke and the clipboard
    /// already holds it.
    ///
    /// Deliberately does **not** compare `changeCount`. Measured on this machine
    /// with `ISLAND_DRAG_PROBE`: one file drag produced 167 dragged frames inside
    /// the hot zone over 3.8 s with `public.file-url` present and the count
    /// unchanged the whole time, while another bumped the count mid-drag with
    /// `types=[]` for a frame. The count reports when Finder *rewrites* the
    /// pasteboard — a lazy type resolution — not when a drag begins, so gating on
    /// it silently rejects real file drags.
    private var isCarryingContent: Bool {
        NSPasteboard(name: .drag).types?.contains(.fileURL) ?? false
    }

    private func handleMouse(_ event: NSEvent) {
        // Drag bookkeeping first, because a window drag must not reach the hover
        // logic below at all.
        switch event.type {
        case .leftMouseDown:
            // Snapshot before the drag begins: the payload is written to the drag
            // pasteboard after this point, so a changed count means content.
            dragCountAtMouseDown = NSPasteboard(name: .drag).changeCount
            // A press on the open island may become a shelf row being dragged out,
            // which must not be caught on the way back in.
            dragBeganOnIsland = model.expanded && islandRect.contains(NSEvent.mouseLocation)

        case .leftMouseUp:
            dragCountAtMouseDown = -1
            model.isInteracting = false
            // A file let go of over the open shelf. The drop normally reaches
            // `FileDropView`; `restorePanelIfDragWasCancelled` checks whether it did.
            awaitingReleasedFiles = dragOpenedShelf
                && !dragBeganOnIsland
                && model.expanded
                && islandRect.contains(NSEvent.mouseLocation)
            if Self.dragProbe, dragOpenedShelf {
                NSLog("[probe] released overIsland=\(awaitingReleasedFiles) beganOnIsland=\(dragBeganOnIsland) expanded=\(model.expanded)")
            }
            restorePanelIfDragWasCancelled()

        case .leftMouseDragged:
            if Self.dragProbe {
                let drag = NSPasteboard(name: .drag)
                let types = (drag.types ?? []).map(\.rawValue).prefix(3).joined(separator: ", ")
                NSLog("[probe] dragged content=\(isCarryingContent) count=\(drag.changeCount) base=\(dragCountAtMouseDown) inside=\(inHotZone(NSEvent.mouseLocation)) types=[\(types)]")
            }
            guard isCarryingContent else { return }
            dragPasteboardDirty = true

        case .mouseMoved:
            // A move with no button held means no drag is in flight, so any drag
            // pasteboard contents are now stale. Clear them, or every window drag
            // that follows a file drag looks like a content drag — measured: 886
            // events across five drags all reported `public.file-url`, window drags
            // included.
            //
            // Only queried after a drag was actually seen. Touching the pasteboard
            // on every mouse move would be an IPC round trip at pointer rate.
            // Not while a released file is still to be read from it.
            if dragPasteboardDirty, !awaitingReleasedFiles {
                NSPasteboard(name: .drag).clearContents()
                dragPasteboardDirty = false
            }
            model.isInteracting = false

        default:
            break
        }

        let point = NSEvent.mouseLocation
        var inside = inHotZone(point)

        // A dragged event only gets this far carrying a file — the switch above
        // returned for the rest — and a file counts from further out.
        if event.type == .leftMouseDragged, dragZone.contains(point) {
            inside = true
        }

        // A recent shrink may have lifted the island's bottom edge above the
        // pointer. Keep counting the old area as inside until the pointer leaves
        // it, so switching to a shorter panel does not collapse the island out
        // from under the mouse.
        if let capture = pointerCapture {
            if capture.contains(point) {
                inside = true
            } else {
                pointerCapture = nil
            }
        }

        // Hold the island open while a content drag is over it. The pointer
        // crosses the hot-zone boundary constantly during a drag, and the 30 ms
        // collapse would otherwise close the drop target out from under the file.
        if event.type == .leftMouseDragged, inside {
            model.isInteracting = true

            if !dragOpenedShelf {
                dragOpenedShelf = true
                // Remember what the user would have been looking at. If the island
                // is closed, that is `panelOnOpen`, because `expand()` is about to
                // select it.
                panelBeforeDrag = model.expanded ? model.activePanel : model.panelOnOpen
                model.shelfDidReceiveDrop = false
                if Self.dragProbe {
                    NSLog("[probe] file drag reached the island zone; expanded=\(model.expanded) beganOnIsland=\(dragBeganOnIsland)")
                }
            }
        }

        let entering = inside && !wasInside
        wasInside = inside

        // After a Spotlight handoff, wait until Spotlight is actually gone
        // before arming the island again — checked on movement, not on a timer.
        if model.suppressed {
            guard !SpotlightState.isOpen else { return }
            model.suppressed = false
            refreshMousePolicy()
        }

        // Only worth asking when the pointer first reaches the notch.
        if entering, !model.expanded, SpotlightState.isOpen {
            return
        }

        if inside {
            collapseWork?.cancel()

            if !panel.isVisible {
                FullscreenSupport.attach(panel)
                panel.orderFrontRegardless()
                refreshMousePolicy()
            }
            model.expand()

            // Must come after expand(): expand() sets activePanel to panelOnOpen,
            // which silently undid selecting the shelf during a drag — so the shelf
            // was never on screen to receive the drop.
            if dragOpenedShelf {
                model.selectPanel(.shelf)
            }
        } else if model.expanded {
            if event.type == .leftMouseDown {
                model.collapse()
            } else {
                scheduleCollapse()
            }
        }
    }

    /// A drag that ends without a drop should not leave the shelf showing, because
    /// the user never asked for it. The delay lets the drop handler run first: item
    /// loading is asynchronous, so the flag is not set the instant the button comes
    /// up.
    ///
    /// It is also the safety net for a file released over the open shelf whose drop
    /// never reached `FileDropView`. The hover monitor sees every drag, and the
    /// drag pasteboard still holds the files after the button comes up, so they are
    /// read from there — the shelf only records a reference, so there is no file
    /// operation the drop would have had to perform. Read here, after the source
    /// has finished, rather than on mouse-up while it may still be busy with the
    /// drop; `awaitingReleasedFiles` keeps the stale-pasteboard clear off it until
    /// then.
    private func restorePanelIfDragWasCancelled() {
        guard dragOpenedShelf else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            guard let self else { return }
            if self.awaitingReleasedFiles {
                self.awaitingReleasedFiles = false
                if self.model.shelfDidReceiveDrop {
                    if Self.dragProbe { NSLog("[probe] drop arrived through FileDropView; safety net not needed") }
                } else {
                    let urls = FileDropView.fileURLs(on: NSPasteboard(name: .drag))
                    if Self.dragProbe { NSLog("[probe] no drop arrived; safety net read \(urls.count) file(s) from the drag pasteboard") }
                    if !urls.isEmpty {
                        self.model.receiveFiles(urls)
                    }
                }
            }
            let dropped = self.model.shelfDidReceiveDrop
            let previous = self.panelBeforeDrag
            self.dragOpenedShelf = false
            self.panelBeforeDrag = nil
            guard !dropped, let previous, previous != .shelf else { return }
            self.model.selectPanel(previous)
        }
    }

    /// Everything that has to follow the open/closed state.
    ///
    /// One function rather than a closure body, because two callers need it: the
    /// `$expanded` sink and the launch flags, which set `expanded` before the sink
    /// exists.
    private func handleExpansion(_ expanded: Bool) {
        pointerCapture = nil
        if expanded {
            startSpotlightWatch()
            model.player.startPolling()
            hotKeys.install()
        } else {
            stopSpotlightWatch()
            model.player.stopPolling()
            hotKeys.uninstall()
        }
        updateGeometry()
        refreshMousePolicy()
    }

    private func scheduleCollapse() {
        collapseWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            // The picker is driven from the keyboard; the pointer being elsewhere is
            // the normal case, not a reason to close.
            guard let self,
                  !self.model.locksOpen,
                  !self.model.isInteracting,
                  !self.model.pickerActive,
                  !self.inHotZone(NSEvent.mouseLocation)
            else { return }
            self.model.collapse()
        }
        collapseWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.03, execute: work)
    }

    private func observeScreens() {
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            // Any pending settle was computed against the old screens.
            self.settleWork?.cancel()
            self.settleWork = nil

            // A display change can take the notch away — lid closed, or an
            // external display becoming main. Collapse rather than only hiding:
            // leaving `expanded` true kept the Spotlight watch and the player poll
            // running against an invisible window, which is the one rule this app
            // does not break, and made the island reappear open when the notch came
            // back.
            guard NSScreen.screens.contains(where: { $0.notchRect != nil }) else {
                self.model.collapse()
                self.panel.orderOut(nil)
                return
            }
            if !self.panel.isVisible {
                FullscreenSupport.attach(self.panel)
                self.panel.orderFrontRegardless()
            }
            self.updateGeometry()
        }
    }
}

extension NSScreen {
    /// Physical camera cutout, derived from the menu-bar areas either side of it.
    var notchRect: CGRect? {
        guard safeAreaInsets.top > 0,
              let left = auxiliaryTopLeftArea,
              let right = auxiliaryTopRightArea
        else { return nil }
        let width = frame.width - left.width - right.width
        guard width > 40 else { return nil }
        return CGRect(
            x: frame.minX + left.width,
            y: frame.maxY - safeAreaInsets.top,
            width: width,
            height: safeAreaInsets.top
        )
    }
}
