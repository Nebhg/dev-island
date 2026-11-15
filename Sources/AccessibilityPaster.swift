import ApplicationServices
import CoreGraphics
import Foundation

/// Posts a synthetic ⌘V so a clicked entry lands in whatever app had focus.
///
/// Permission is reported, not enforced: `postPaste` always tries, and the two
/// preflight APIs are only consulted to decide whether to warn.
enum AccessibilityPaster {
    /// Virtual keycode for `V` (`kVK_ANSI_V`), not a character, so it is immune
    /// to the user's layout.
    private static let vKey: CGKeyCode = 0x09

    /// Either API counts. On macOS 26 `CGPreflightPostEventAccess()` has been
    /// observed returning false while posting works — the app was pasting fine and
    /// still showed "Grant Accessibility". `AXIsProcessTrusted()` answers the
    /// neighbouring question and is true in that state, so treating either as
    /// permission stops the warning from lying.
    static var canPost: Bool {
        CGPreflightPostEventAccess() || AXIsProcessTrusted()
    }

    /// Returns false when the event could not be posted, so the caller can fall
    /// back to copy-only rather than pretending it pasted.
    @discardableResult
    static func postPaste() -> Bool {
        // Deliberately not gated on `canPost`: the preflight contradicts reality,
        // and refusing to try turned a working paste into a silent copy-only.
        // Attempt it; if permission really is absent nothing happens, which is the
        // same outcome with one fewer lie.
        guard let source = CGEventSource(stateID: .hidSystemState) else { return false }

        let down = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: true)
        let up = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: false)
        down?.flags = .maskCommand
        up?.flags = .maskCommand

        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
        return true
    }
}
