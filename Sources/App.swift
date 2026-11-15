import AppKit
import SwiftUI

enum PreviewMode {
    /// ImageRenderer cannot rasterise NSViewRepresentable, so previews draw a
    /// plain fill instead of the real glass surface.
    static var active = false
}

@main
struct IslandApp {
    /// Held for the process lifetime; closing it would release the lock.
    private static var instanceLock: Int32 = -1

    static func main() {
        guard acquireInstanceLock() else { exit(0) }

        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }

    /// Exclusive `flock` so only one island can ever run.
    ///
    /// This used to ask `NSRunningApplication`, which is the wrong tool: it
    /// depends on LaunchServices having registered the process, so two launches
    /// close together can both see zero others and both proceed — two panels
    /// fighting over the notch. A kernel file lock is atomic, so the race cannot
    /// come back. Fails open if the lock file cannot be created, because refusing
    /// to start is worse than a duplicate.
    private static func acquireInstanceLock() -> Bool {
        let base = AppSupport.directory()

        let fd = open(base.appendingPathComponent("instance.lock").path, O_CREAT | O_RDWR, 0o644)
        guard fd >= 0 else { return true }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            close(fd)
            return false
        }
        instanceLock = fd
        return true
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var controller: IslandController?
    private var statusItem: NSStatusItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        if let path = ProcessInfo.processInfo.environment["ISLAND_RENDER"] {
            renderPreview(to: path)
            NSApp.terminate(nil)
            return
        }

        guard NSScreen.screens.contains(where: { $0.notchRect != nil }) else {
            reportNoNotchAndQuit()
            return
        }

        controller = IslandController()
        controller?.show()
        buildStatusItem()

    }

    func applicationWillTerminate(_ notification: Notification) {
        controller?.shutdown()
    }

    /// The island is anchored to a physical cutout. Without one there is nothing
    /// to attach to, and the app would otherwise launch into a menu bar item that
    /// silently does nothing. This also covers clamshell use with an external
    /// display, where the notched panel is asleep and every notch lookup returns
    /// nil.
    private func reportNoNotchAndQuit() {
        let alert = NSAlert()
        alert.messageText = "Dev Island needs a notched display"
        alert.informativeText = """
            No screen with a camera cutout was found. Dev Island anchors itself \
            to the notch, so it has nothing to attach to here — for example with \
            the lid closed and an external display attached.
            """
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Quit")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
        NSApp.terminate(nil)
    }

    /// Headless layout preview, used while iterating on the design.
    @MainActor private func renderPreview(to path: String) {
        PreviewMode.active = true
        let model = IslandModel()
        let state = ProcessInfo.processInfo.environment["ISLAND_RENDER_STATE"] ?? "expanded"
        if let panel = ProcessInfo.processInfo.environment["ISLAND_RENDER_PANEL"],
           let selected = PanelID(rawValue: panel) {
            model.activePanel = selected
        }
        model.expanded = state != "wings"

        // A preview has no PanelHost, so nothing starts the active provider and
        // the terminal panel renders as "No history yet". Prime it, or the
        // preview cannot show what the panel actually looks like.
        if model.activePanel == .terminal {
            model.terminal.startWatching()
        }
        if state == "wings" || state == "playing" {
            model.nowPlaying = NowPlaying(
                title: "Preview Track (a long title that has to scroll)",
                artist: "Preview Artist",
                album: "",
                duration: 301,
                elapsed: 74,
                rate: 1,
                timestamp: Date(),
                artwork: nil
            )
        }
        let size = model.islandSize
        let dark = NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        let canvas = IslandRootView(model: model)
            .environment(\.colorScheme, dark ? .dark : .light)
            .frame(width: size.width, height: size.height)
            .background(Color(red: 0.09, green: 0.09, blue: 0.11))
        let renderer = ImageRenderer(content: canvas)
        renderer.scale = 2
        guard let image = renderer.nsImage,
              let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:])
        else {
            NSLog("DevIsland: preview render failed")
            return
        }
        try? png.write(to: URL(fileURLWithPath: path))
    }

    private func buildStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = NSImage(systemSymbolName: "capsule.portrait", accessibilityDescription: "Dev Island")

        let menu = NSMenu()
        menu.delegate = self
        menu.addItem(makeItem("Expand Island", #selector(toggle)))
        menu.addItem(makeItem("Collapse Island", #selector(collapse)))
        menu.addItem(.separator())

        let defaultItem = NSMenuItem(title: "Default Panel", action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        for panel in PanelID.allCases {
            let entry = NSMenuItem(
                title: panel.title,
                action: #selector(setDefaultPanel(_:)),
                keyEquivalent: ""
            )
            entry.target = self
            entry.representedObject = panel.rawValue
            submenu.addItem(entry)
        }
        defaultItem.submenu = submenu
        menu.addItem(defaultItem)

        menu.addItem(.separator())
        menu.addItem(makeItem("Edit Ignore Rules…", #selector(editIgnoreRules)))
        menu.addItem(.separator())
        menu.addItem(makeItem("Quit", #selector(quit)))
        item.menu = menu
        statusItem = item
    }

    private func makeItem(_ title: String, _ action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        return item
    }

    @objc private func toggle() { controller?.toggleExpanded() }
    @objc private func collapse() { controller?.collapse() }
    @objc private func quit() { NSApp.terminate(nil) }
    @objc private func editIgnoreRules() { controller?.editIgnoreRules() }

    @objc private func setDefaultPanel(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let panel = PanelID(rawValue: raw)
        else { return }
        controller?.defaultPanel = panel
    }
}

extension AppDelegate: NSMenuDelegate {
    /// Checkmarks are refreshed on open rather than kept in sync.
    func menuWillOpen(_ menu: NSMenu) {
        let current = controller?.defaultPanel
        for item in menu.items where item.action == #selector(setDefaultPanel(_:)) {
            item.state = (item.representedObject as? String) == current?.rawValue ? .on : .off
        }
        for item in menu.items.first(where: { $0.title == "Default Panel" })?.submenu?.items ?? [] {
            item.state = (item.representedObject as? String) == current?.rawValue ? .on : .off
        }
    }
}
