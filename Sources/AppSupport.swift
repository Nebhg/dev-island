import Foundation

/// Where the app keeps its files.
///
/// Four call sites used to compute this themselves — the clipboard, shelf and
/// ignore-rule stores, and the single-instance lock in `App.swift` — which is
/// four chances for one of them to be renamed out of step with the rest.
enum AppSupport {
    /// `~/Library/Application Support/Dev Island`, created if it is missing.
    ///
    /// `override` is for tests, and for anything that needs to run against a
    /// throwaway directory instead of the user's real history.
    static func directory(override: URL? = nil) -> URL {
        if let override { return override }

        // Sandbox mode. Every store and the single-instance lock resolve through
        // here, so setting this redirects the whole app — which is the only way to
        // exercise the panels against invented data without risking real clipboard
        // history, the shelf, or shell history by proxy.
        if let sandbox = ProcessInfo.processInfo.environment["ISLAND_DATA_DIR"],
           !sandbox.isEmpty {
            let base = URL(fileURLWithPath: sandbox, isDirectory: true)
            try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
            return base
        }

        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Dev Island", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }
}
