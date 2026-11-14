import Foundation

/// One logical command from `~/.zsh_history`.
///
/// The file carries no timestamps (`EXTENDED_HISTORY` is off), so recency has to
/// come from file position: a later line means more recent. That is also why the
/// ranking has no time decay — a decay curve would be invented, not measured.
struct TerminalEntry: Identifiable, Equatable {
    var id: String { command }
    let command: String
    var uses: Int
    var lastPosition: Int

    var isSecret: Bool { ClipboardStore.looksSecret(command) }

    /// Masked when the command looks like it carries a credential: this panel
    /// often sits on screen during a screen share. The clipboard still receives
    /// the real text, because pasting it is the point of clicking.
    var display: String {
        guard isSecret else { return command }
        if let separator = command.firstIndex(where: { $0 == "=" || $0 == ":" }) {
            return command[...command.index(after: separator)] + "••••"
        }
        return "••••"
    }
}

enum TerminalHistory {
    /// Parses the whole file.
    ///
    /// ~50 KB / ~1,300 lines is well under a millisecond, and a full re-parse
    /// avoids the double-counting and offset-reset bugs that incremental tailing
    /// brings.
    static func parse(_ text: String) -> [TerminalEntry] {
        var entries: [TerminalEntry] = []
        var indexByCommand: [String: Int] = [:]
        var pending = ""
        var position = 0

        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            var line = String(rawLine)

            // `EXTENDED_HISTORY` writes ": <start>:<elapsed>;<command>". Handled
            // even though it is off, so turning it on later does not break parsing.
            if line.hasPrefix(": "), let semicolon = line.firstIndex(of: ";") {
                line = String(line[line.index(after: semicolon)...])
            }

            // Join with a space, not a newline: the row is a single line, and a
            // pasted command with newlines would execute line by line. Only the
            // continuation's leading indentation is dropped — internal spacing is
            // left alone, since it can be significant inside quotes.
            pending += pending.isEmpty ? line : " " + line.trimmingCharacters(in: .whitespaces)

            // A trailing backslash continues the command on the next line.
            if line.hasSuffix("\\") {
                pending.removeLast()
                // The backslash is usually preceded by a space; drop it so the
                // join does not leave a double space.
                pending = pending.trimmingCharacters(in: .whitespaces)
                continue
            }

            let command = pending.trimmingCharacters(in: .whitespacesAndNewlines)
            pending = ""
            guard !command.isEmpty else { continue }

            position += 1
            if let existing = indexByCommand[command] {
                entries[existing].uses += 1
                entries[existing].lastPosition = position
            } else {
                indexByCommand[command] = entries.count
                entries.append(TerminalEntry(command: command, uses: 1, lastPosition: position))
            }
        }
        return entries
    }

    /// Use count first, then recency. Ties go to the more recent command.
    static func ranked(_ entries: [TerminalEntry], limit: Int) -> [TerminalEntry] {
        entries
            .sorted {
                $0.uses == $1.uses
                    ? $0.lastPosition > $1.lastPosition
                    : $0.uses > $1.uses
            }
            .prefix(limit)
            .map { $0 }
    }
}
