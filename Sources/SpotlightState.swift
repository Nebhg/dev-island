import AppKit
import CoreGraphics

/// Spotlight / Siri search is a window owned by Siri AI (`com.apple.campo`).
/// We cannot move it, so the island simply refuses to open while it is up.
enum SpotlightState {
    static var isOpen: Bool {
        let apps = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.campo")
        guard !apps.isEmpty else { return false }

        if NSWorkspace.shared.frontmostApplication?.bundleIdentifier == "com.apple.campo" {
            return true
        }

        let pids = Set(apps.map { $0.processIdentifier })
        let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID)
            as? [[String: Any]] ?? []

        return windows.contains { window in
            guard let pid = window[kCGWindowOwnerPID as String] as? pid_t, pids.contains(pid) else {
                return false
            }
            let layer = window[kCGWindowLayer as String] as? Int ?? 0
            let alpha = window[kCGWindowAlpha as String] as? Double ?? 0
            let bounds = window[kCGWindowBounds as String] as? [String: Any]
            let height = bounds?["Height"] as? Double ?? 0
            return layer >= 0 && alpha > 0.01 && height > 40
        }
    }
}
