import AppKit
import SwiftUI

enum PreviewMode {
    /// ImageRenderer cannot rasterise NSViewRepresentable, so previews draw a
    /// plain fill instead of the real glass surface.
    static var active = false
}

@main
struct IslandApp {
    static func main() {
        // Only ever one island.
        if NSRunningApplication.runningApplications(withBundleIdentifier: "com.haras.dynamicisland").count > 1 {
            exit(0)
        }
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
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
        controller = IslandController()
        controller?.show()
        buildStatusItem()
    }

    /// Headless layout preview, used while iterating on the design.
    @MainActor private func renderPreview(to path: String) {
        PreviewMode.active = true
        let model = IslandModel()
        let state = ProcessInfo.processInfo.environment["ISLAND_RENDER_STATE"] ?? "expanded"
        model.expanded = state != "wings"
        if state == "wings" || state == "playing" {
            model.nowPlaying = NowPlaying(
                title: "Must Be The Ganja (feat. Dr. Dre)",
                artist: "Eminem",
                album: "",
                duration: 301,
                elapsed: 74,
                rate: 1,
                timestamp: Date(),
                artwork: nil
            )
        }
        _ = model.islandSize
        let dark = NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        let canvas = IslandRootView(model: model)
            .environment(\.colorScheme, dark ? .dark : .light)
            .frame(width: 620, height: 260)
            .background(Color(red: 0.09, green: 0.09, blue: 0.11))
        let renderer = ImageRenderer(content: canvas)
        renderer.scale = 2
        guard let image = renderer.nsImage,
              let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:])
        else {
            NSLog("DynamicIsland: preview render failed")
            return
        }
        try? png.write(to: URL(fileURLWithPath: path))
    }

    private func buildStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = NSImage(systemSymbolName: "capsule.portrait", accessibilityDescription: "Dynamic Island")

        let menu = NSMenu()
        menu.addItem(makeItem("Expand Island", #selector(toggle)))
        menu.addItem(makeItem("Collapse Island", #selector(collapse)))
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
}
