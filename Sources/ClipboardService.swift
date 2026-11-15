import AppKit
import Combine
import Foundation

/// Clipboard history: capture, dedupe, and paste back.
///
/// **Deliberate exception to the "nothing runs unless the panel is visible" rule.**
/// Capture has to run while the island is closed or there is no history to show.
/// The cost is one `changeCount` integer compare every 0.4 s; the string is only
/// read when the count actually moved. Every other provider starts and stops with
/// its panel.
final class ClipboardService: ObservableObject {
    @Published private(set) var entries: [ClipEntry] = [] {
        didSet { frequent = Frecency.ranked(entries, limit: Self.frequentLimit) }
    }
    @Published private(set) var canAutoPaste = AccessibilityPaster.canPost

    /// Top entries for the chip strip, kept in step with `entries` instead of
    /// re-ranked inside `body`. The panel rebuilt this list on every render — and
    /// it renders on every player poll, so up to 300 entries were sorted twice a
    /// second to produce three chips.
    ///
    /// The ranking has a 14-day half-life, so holding it for the length of a
    /// session is not meaningful staleness.
    private(set) var frequent: [ClipEntry] = []

    private static let frequentLimit = 3

    private let store = ClipboardStore()
    private var timer: Timer?
    private var lastChangeCount = NSPasteboard.general.changeCount

    /// Apps whose clipboard contents are never stored.
    private static let blockedBundleIDs: Set<String> = [
        "com.1password.1password",
        "com.agilebits.onepassword7",
        "com.bitwarden.desktop",
        "com.dashlane.dashlanephonefinal",
        "me.proton.pass.electron",
        "com.apple.keychainaccess"
    ]

    init() {
        entries = store.entries
        startWatching()
    }

    deinit {
        timer?.invalidate()
    }

    // MARK: - Capture

    func startWatching() {
        guard timer == nil else { return }
        lastChangeCount = NSPasteboard.general.changeCount
        // Common mode so the poll keeps ticking while a menu or drag is tracking.
        let timer = Timer(timeInterval: 0.4, repeats: true) { [weak self] _ in
            self?.capture()
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func capture() {
        let pasteboard = NSPasteboard.general
        let count = pasteboard.changeCount
        guard count != lastChangeCount else { return }
        lastChangeCount = count

        // No "ignore next change" flag here on purpose. `write` already syncs
        // `lastChangeCount` to the count it caused, so our own write is skipped by
        // the equality check above. A flag on top of that could never be consumed —
        // the equality check returns first — and would silently eat the user's next
        // real copy.

        let types = pasteboard.types ?? []
        if types.contains(Self.transientType) || types.contains(Self.concealedType) {
            return
        }

        if let bundle = NSWorkspace.shared.frontmostApplication?.bundleIdentifier,
           Self.blockedBundleIDs.contains(bundle) {
            return
        }

        guard let text = pasteboard.string(forType: .string) else { return }
        guard !ClipboardStore.looksSecret(text) else { return }

        store.record(text)
        entries = store.entries
    }

    private static let transientType = NSPasteboard.PasteboardType("org.nspasteboard.TransientType")
    private static let concealedType = NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")

    // MARK: - Writing back

    /// Puts an entry on the pasteboard and marks it as used. Returns whether the
    /// pasteboard was written.
    @discardableResult
    func write(_ entry: ClipEntry) -> Bool {
        guard writeText(entry.text) else { return false }
        store.touch(hash: entry.hash)
        entries = store.entries
        return true
    }

    /// Writes arbitrary text without touching the history. Used by the terminal
    /// panel, whose commands are not clipboard entries.
    @discardableResult
    func writeText(_ text: String) -> Bool {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        guard pasteboard.setString(text, forType: .string) else { return false }

        // Claim the change so the watcher does not treat our own write as a copy.
        // Syncing the count is enough — see the note in `capture`.
        lastChangeCount = pasteboard.changeCount
        return true
    }

    func refreshPermission() {
        canAutoPaste = AccessibilityPaster.canPost
    }

    func remove(_ entry: ClipEntry) {
        store.remove(hash: entry.hash)
        entries = store.entries
    }

    func clear() {
        store.clear()
        entries = []
    }
}
