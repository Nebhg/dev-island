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

    private let panelSize = CGSize(width: 620, height: 260)

    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var collapseWork: DispatchWorkItem?
    private var screenObserver: NSObjectProtocol?
    private var spotlightTimer: Timer?
    private var workspaceObserver: NSObjectProtocol?
    private var cancellables = Set<AnyCancellable>()
    private var wasInside = false

    init() {
        let model = IslandModel()
        self.model = model
        self.host = NSHostingView(rootView: IslandRootView(model: model))
        self.panel = IslandPanel(
            contentRect: NSRect(origin: .zero, size: panelSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        host.translatesAutoresizingMaskIntoConstraints = true
        host.autoresizingMask = [.width, .height]
        host.frame = NSRect(origin: .zero, size: panelSize)

        panel.contentView = host
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.isMovable = false
        panel.isMovableByWindowBackground = false
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.ignoresMouseEvents = true
        panel.worksWhenModal = true

        model.onHandOff = { [weak self] in
            self?.hideForSpotlight()
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

        // The poll only exists while the island is actually on screen. Closed,
        // there is nothing to get out of the way of, so no timer runs at all.
        model.$expanded
            .receive(on: RunLoop.main)
            .sink { [weak self] expanded in
                if expanded {
                    self?.startSpotlightWatch()
                } else {
                    self?.stopSpotlightWatch()
                }
            }
            .store(in: &cancellables)

        // Handy for screenshots and for keeping it open while you poke at it.
        if ProcessInfo.processInfo.environment["ISLAND_EXPANDED"] == "1" {
            model.expanded = true
            model.locksOpen = true   // stays open so it can be screenshotted
        }
    }

    deinit {
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
        if let workspaceObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(workspaceObserver)
        }
        spotlightTimer?.invalidate()
    }

    func show() {
        panel.orderFrontRegardless()
    }

    func toggleExpanded() {
        model.toggleExpanded()
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
        if let notch = screen.notchRect {
            model.notchSize = notch.size
        }
        let frame = CGRect(
            x: screen.frame.midX - panelSize.width / 2,
            y: screen.frame.maxY - panelSize.height,
            width: panelSize.width,
            height: panelSize.height
        )
        panel.setFrame(frame, display: true)
    }

    /// Current visible island, in screen coordinates.
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
        let inside = inHotZone(point)
        let entering = inside && !wasInside
        wasInside = inside

        // After a Spotlight handoff, wait until Spotlight is actually gone
        // before arming the island again — checked on movement, not on a timer.
        if model.suppressed {
            guard !SpotlightState.isOpen else { return }
            model.suppressed = false
        }

        // Only worth asking when the pointer first reaches the notch.
        if entering, !model.expanded, SpotlightState.isOpen {
            return
        }

        if panel.ignoresMouseEvents == inside {
            panel.ignoresMouseEvents = !inside
        }

        if inside {
            collapseWork?.cancel()

            if !panel.isVisible {
                panel.orderFrontRegardless()
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
            guard let self, !self.model.locksOpen, !self.inHotZone(NSEvent.mouseLocation) else { return }
            self.model.collapse()
        }
        collapseWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05, execute: work)
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
