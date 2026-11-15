import CoreGraphics
import Foundation

/// Posts a synthetic ⌘V so a clicked entry lands in whatever app had focus.
///
/// **Permission is not modelled here at all.** Both preflight APIs were measured
/// reporting `false` for an app launched from Spotlight — `post=false ax=false` —
/// while posting worked. Gating on them silently killed auto-paste for anyone who
/// launched the app the normal way, and warning about them showed "Grant
/// Accessibility" over an app that was pasting fine. So: always post, and say
/// nothing about permission. If a grant is ever genuinely missing the keystroke
/// simply does nothing, which is what it did before, minus the false alarm.
enum AccessibilityPaster {
    /// Virtual keycode for `V` (`kVK_ANSI_V`), not a character, so it is immune
    /// to the user's layout.
    private static let vKey: CGKeyCode = 0x09

    /// Returns false when the event could not be posted, so the caller can fall
    /// back to copy-only rather than pretending it pasted.
    @discardableResult
    static func postPaste() -> Bool {
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
