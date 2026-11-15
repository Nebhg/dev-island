import AppKit
import SwiftUI

enum PreviewMode {
    /// Set while rendering an `ISLAND_RENDER` preview, so the throwaway model
    /// it builds does not write the user's preferences.
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

        // Ask for Accessibility at launch rather than on the first paste, so the
        // grant can be sorted before it is needed.
        AccessibilityPaster.promptIfNeeded()

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
        let lastUsed = NSMenuItem(title: "Last Used", action: #selector(useLastPanel), keyEquivalent: "")
        lastUsed.target = self
        submenu.addItem(lastUsed)
        submenu.addItem(.separator())
        for panel in PanelID.contentPanels {
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

        let shortcutItem = NSMenuItem(title: Self.shortcutMenuTitle, action: nil, keyEquivalent: "")
        let shortcutMenu = NSMenu()
        for shortcut in ClipboardShortcut.allCases {
            let entry = NSMenuItem(title: shortcut.title, action: #selector(setClipboardShortcut(_:)), keyEquivalent: "")
            entry.target = self
            entry.representedObject = shortcut.rawValue
            shortcutMenu.addItem(entry)
        }
        shortcutMenu.addItem(.separator())
        let off = NSMenuItem(title: "Off", action: #selector(setClipboardShortcut(_:)), keyEquivalent: "")
        off.target = self
        shortcutMenu.addItem(off)
        shortcutItem.submenu = shortcutMenu
        menu.addItem(shortcutItem)

        menu.addItem(makeItem(Self.cleanLayoutTitle, #selector(toggleCleanLayout)))

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
        controller?.reopensLastPanel = false
    }

    @objc private func useLastPanel() {
        controller?.reopensLastPanel = true
    }

    private static let shortcutMenuTitle = "Clipboard Shortcut"
    private static let cleanLayoutTitle = "Clean Layout"

    @objc private func toggleCleanLayout() {
        controller?.cleanLayout.toggle()
    }

    /// `representedObject` is the shortcut's raw value; "Off" has none.
    @objc private func setClipboardShortcut(_ sender: NSMenuItem) {
        controller?.clipboardShortcut = (sender.representedObject as? String).flatMap(ClipboardShortcut.init(rawValue:))
    }
}

extension AppDelegate: NSMenuDelegate {
    /// Checkmarks are refreshed on open rather than kept in sync.
    func menuWillOpen(_ menu: NSMenu) {
        let reopens = controller?.reopensLastPanel ?? true
        let current = controller?.defaultPanel
        for item in menu.items.first(where: { $0.title == "Default Panel" })?.submenu?.items ?? [] {
            if item.action == #selector(useLastPanel) {
                item.state = reopens ? .on : .off
            } else if item.action == #selector(setDefaultPanel(_:)) {
                let isDefault = (item.representedObject as? String) == current?.rawValue
                item.state = !reopens && isDefault ? .on : .off
            }
        }

        menu.items.first(where: { $0.title == Self.cleanLayoutTitle })?.state =
            controller?.cleanLayout == true ? .on : .off

        // A shortcut another app already holds cannot be registered; say so on
        // the checked entry rather than leaving it looking active.
        let shortcut = controller?.clipboardShortcut
        let available = controller?.clipboardShortcutAvailable ?? true
        for item in menu.items.first(where: { $0.title == Self.shortcutMenuTitle })?.submenu?.items ?? [] {
            guard item.action == #selector(setClipboardShortcut(_:)) else { continue }
            let raw = item.representedObject as? String
            item.state = raw == shortcut?.rawValue ? .on : .off
            if let raw, let option = ClipboardShortcut(rawValue: raw) {
                item.title = raw == shortcut?.rawValue && !available
                    ? "\(option.title) — in use by another app"
                    : option.title
            }
        }
    }
}
