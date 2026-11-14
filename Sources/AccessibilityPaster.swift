import CoreGraphics
import Foundation

/// Posts a synthetic ⌘V so a clicked entry lands in whatever app had focus.
///
/// The gate is `CGPreflightPostEventAccess()`, not `AXIsProcessTrusted()`: the
/// former answers "can this process post an event", which is the only question
/// that matters here. It checks without prompting.
enum AccessibilityPaster {
    /// Virtual keycode for `V` (`kVK_ANSI_V`), not a character, so it is immune
    /// to the user's layout.
    private static let vKey: CGKeyCode = 0x09

    static var canPost: Bool { CGPreflightPostEventAccess() }

    /// Returns false when the event could not be posted, so the caller can fall
    /// back to copy-only rather than pretending it pasted.
    @discardableResult
    static func postPaste() -> Bool {
        guard canPost else { return false }
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
