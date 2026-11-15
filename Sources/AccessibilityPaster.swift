import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

/// Posts a synthetic ⌘V so a clicked entry lands in whatever app had focus.
///
/// **Posting a synthetic ⌘V needs the Accessibility grant, and only the app's own
/// grant counts.**
///
/// Measured, after a long detour: launched *from a terminal*, both preflights
/// report `true`; launched from Spotlight or Finder, both report `false`. A
/// terminal-launched process is attributed to the terminal, which already has the
/// grant, while a LaunchServices launch is its own responsibility. So auto-paste
/// appeared to work in every test that ran the binary directly, and died the moment
/// the app was opened the way a person opens it.
///
/// There is no pasting without the grant, so the job here is to check it, ask for
/// it once, and point at the pane that holds it.
enum AccessibilityPaster {
    /// Virtual keycode for `V` (`kVK_ANSI_V`), not a character, so it is immune
    /// to the user's layout.
    private static let vKey: CGKeyCode = 0x09

    /// Either API counts. They answer the same question and have been seen to
    /// disagree, so a `true` from either is taken as good enough.
    static var canPost: Bool {
        AXIsProcessTrusted() || CGPreflightPostEventAccess()
    }

    /// Asks macOS to add this app to the Accessibility list.
    ///
    /// The system dialog appears only the first time an app asks, and only if it is
    /// not already listed. Once per launch is enough; asking on every panel open
    /// would be worse than the problem.
    private static var didPrompt = false
    static func promptIfNeeded() {
        guard !didPrompt, !canPost else { return }
        didPrompt = true
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    /// Opens the pane that holds the grant. The deep link is undocumented, so it
    /// degrades to System Settings itself if the anchor is ignored.
    static func openSettings() {
        let pane = "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
        if let url = URL(string: pane) {
            NSWorkspace.shared.open(url)
        }
    }

    /// Returns false when the event could not be posted, so the caller can fall
    /// back to copy-only rather than pretending it pasted.
    @discardableResult
    static func postPaste() -> Bool {
        // No `guard canPost` here: a missing grant drops the event anyway, so
        // attempting costs nothing and refusing gains nothing. The notice is what
        // tells the user.
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
