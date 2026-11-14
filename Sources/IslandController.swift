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
    private let panelHost: PanelHost

    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var collapseWork: DispatchWorkItem?

    /// Last size the window was actually set to. Size changes are driven by the
    /// SwiftUI animation through `syncWindow`; this lets `updateGeometry` tell a
    /// pending size change (leave it alone) from a pure reposition (apply now).
    private var renderedSize = CGSize.zero
    private var isSyncingWindow = false

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
    private let hotKeys = HotKeys()

    /// Set while a menu is tracking or a drag is in flight, so the 50 ms
    /// collapse does not fire while the pointer is legitimately outside.
    var isInteracting = false

    init() {
        let model = IslandModel()
        self.model = model
        self.panelHost = PanelHost(model: model)
        self.host = NSHostingView(rootView: IslandRootView(model: model))
        self.panel = IslandPanel(
            contentRect: NSRect(origin: .zero, size: model.islandSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        host.translatesAutoresizingMaskIntoConstraints = true
        host.autoresizingMask = [.width, .height]
        host.frame = NSRect(origin: .zero, size: model.islandSize)

        panel.contentView = host
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
            .sink { [weak self] expanded in
                guard let self else { return }
                self.pointerCapture = nil
                if expanded {
                    self.startSpotlightWatch()
                    self.model.player.startPolling()
                    self.hotKeys.install()
                } else {
                    self.stopSpotlightWatch()
                    self.model.player.stopPolling()
                    self.hotKeys.uninstall()
                }
                self.updateGeometry()
                self.refreshMousePolicy()
            }
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

        // Handy for screenshots and for keeping it open while you poke at it.
        if let panel = ProcessInfo.processInfo.environment["ISLAND_PANEL"],
           let selected = PanelID(rawValue: panel) {
            model.selectPanel(selected)
        }
        if ProcessInfo.processInfo.environment["ISLAND_EXPANDED"] == "1" {
            model.expanded = true
            model.locksOpen = true   // stays open so it can be screenshotted
        }
        // The window follows the shape frame by frame, so a resize animation never
        // leaves a transparent gap showing the desktop underneath.
        host.rootView = IslandRootView(model: model) { [weak self] size in
            self?.syncWindow(to: size)
        }

        syncWindow(to: model.islandSize)
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

        // The size is driven frame by frame by the SwiftUI animation through
        // `syncWindow`. Only reposition here, for the two things the animation
        // cannot know about: the initial layout and a screen change.
        let frame = islandFrame(for: renderedSize, on: screen)
        if abs(frame.minX - panel.frame.minX) > 0.5 || abs(frame.minY - panel.frame.minY) > 0.5 {
            panel.setFrame(frame, display: true)
        }
    }

    /// Moves the window to match the shape. Called for every interpolated size
    /// while a resize animates, so the window is never larger than the island —
    /// which is what left a transparent gap showing the desktop below it.
    private func syncWindow(to size: CGSize) {
        guard !isSyncingWindow, let screen = targetScreen() else { return }

        // Land on the real size rather than the spring's last rounding artefact.
        let target = model.islandSize
        let resolved = abs(size.width - target.width) < 0.5 && abs(size.height - target.height) < 0.5
            ? target
            : size

        // Nothing changed: bail out. Setting the frame re-lays out the hosting view,
        // which re-runs the probe, which calls straight back here — an endless
        // redraw loop at display rate even after the animation has finished.
        guard abs(resolved.width - renderedSize.width) > 0.01
            || abs(resolved.height - renderedSize.height) > 0.01
        else { return }

        isSyncingWindow = true
        defer { isSyncingWindow = false }
        renderedSize = resolved
        panel.setFrame(islandFrame(for: resolved, on: screen), display: true)
        host.frame = NSRect(origin: .zero, size: resolved)
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

    /// Open, the panel owns every click inside it. Closed and idle, the window is
    /// only the physical cutout — no pixels, nothing behind it — so it stays
    /// interactive and can act as a drop target. Closed while playing, the chin
    /// covers live menu-bar space, so it must let clicks through.
    private func refreshMousePolicy() {
        if model.expanded {
            panel.ignoresMouseEvents = false
        } else if model.nowPlaying?.isPlaying == true {
            panel.ignoresMouseEvents = true
        } else {
            panel.ignoresMouseEvents = false
        }
    }

    // MARK: - Hover

    private func installMonitors() {
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .leftMouseDown]) { [weak self] event in
            self?.handleMouse(event)
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDown]) { [weak self] event in
            self?.handleMouse(event)
            return event
        }
    }

    private func handleMouse(_ event: NSEvent) {
        let point = NSEvent.mouseLocation
        var inside = inHotZone(point)

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
        } else if model.expanded {
            if event.type == .leftMouseDown {
                model.collapse()
            } else {
                scheduleCollapse()
            }
        }
    }

    private func scheduleCollapse() {
        collapseWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self,
                  !self.model.locksOpen,
                  !self.isInteracting,
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
            self?.updateGeometry()
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
