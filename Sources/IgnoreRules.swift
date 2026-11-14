import AppKit
import Foundation

/// Commands that are never worth showing in the terminal history panel.
///
/// This is a **trivia deny-list, not a frequency filter.** Frequency decides what
/// to highlight; this decides what is never worth retrieving. `python -m
/// backend.main` is both the most frequent command in the measured history and the
/// most useful entry, so "common" must never be a reason to hide something.
///
/// Patterns are anchored to the bare form on purpose: `^cd` would also hide
/// `cd ~/Projects/DevIsland`, which is exactly what the panel exists to surface.
///
/// Manual by design. Auto-learning from what has been pasted would hide things
/// precisely until the first time they are needed.
final class IgnoreRules {
    static let defaults: [String] = [
        #"^cd\s*$"#,
        #"^cd\s+\.{1,2}\s*$"#,
        #"^ls\s*$"#,
        #"^pwd\s*$"#,
        #"^clear\s*$"#,
        #"^exit\s*$"#,
        #"^\.\s*$"#
    ]

    let url: URL
    private(set) var patterns: [String] = []
    private var regexes: [NSRegularExpression] = []

    init(directory: URL? = nil) {
        let base = directory ?? FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Dev Island", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        url = base.appendingPathComponent("ignore-rules.txt")
        load()
    }

    /// True when the command should not be listed. Blank lines are always ignored.
    func ignores(_ command: String) -> Bool {
        let line = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !line.isEmpty else { return true }
        let range = NSRange(line.startIndex..., in: line)
        return regexes.contains { $0.firstMatch(in: line, range: range) != nil }
    }

    /// Writes the defaults the first time the file is opened, so the user edits a
    /// working list instead of an empty file.
    func ensureFileExists() {
        guard !FileManager.default.fileExists(atPath: url.path) else { return }
        let header = """
        # Commands never shown in the terminal panel, one regex per line.
        # Trivia only: never add something just because it is common.

        """
        try? (header + Self.defaults.joined(separator: "\n") + "\n")
            .write(to: url, atomically: true, encoding: .utf8)
    }

    private func load() {
        ensureFileExists()
        guard let body = try? String(contentsOf: url, encoding: .utf8) else {
            apply(Self.defaults)
            return
        }
        let lines = body
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
        // An empty file means "hide nothing extra", not "restore the defaults" —
        // otherwise deleting every line would silently bring the list back.
        apply(lines)
    }

    private func apply(_ patterns: [String]) {
        self.patterns = patterns
        regexes = patterns.compactMap { try? NSRegularExpression(pattern: $0) }
    }
}
