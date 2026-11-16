import Foundation

/// One logical command from a shell history file.
///
/// Recency comes from the command's own `EXTENDED_HISTORY` stamp when there is one,
/// and from file position when there is not. The ranking that follows has no time
/// decay for the same reason: a decay curve would be invented, not measured.
struct TerminalEntry: Identifiable, Equatable {
    var id: String { command }
    let command: String
    var uses: Int
    var lastPosition: Int

    /// When this command was last run, taken from zsh's `EXTENDED_HISTORY`
    /// prefix. `nil` for anything recorded before that option was enabled — those
    /// rows only appear under the "All" window.
    var lastRun: Date?

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

/// One command as it appeared in one file, before the files are merged.
struct TerminalCommand: Equatable {
    let command: String
    let timestamp: Date?
}

enum TerminalHistory {
    /// Parses one file into commands, in file order.
    ///
    /// ~50 KB / ~1,300 lines is well under a millisecond, and a full re-parse
    /// avoids the double-counting and offset-reset bugs that incremental tailing
    /// brings.
    static func parse(_ text: String) -> [TerminalCommand] {
        var commands: [TerminalCommand] = []
        var pending = ""
        var pendingStamp: Date?

        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            var line = String(rawLine)

            // `EXTENDED_HISTORY` writes ": <epoch>:<elapsed>;<command>". The prefix
            // is on the first line of a continued command only, so the stamp is
            // carried in `pendingStamp` until the command is complete.
            if line.hasPrefix(": "), let semicolon = line.firstIndex(of: ";") {
                let header = line[line.index(line.startIndex, offsetBy: 2)..<semicolon]
                if let epoch = header.split(separator: ":").first,
                   let seconds = TimeInterval(epoch) {
                    pendingStamp = Date(timeIntervalSince1970: seconds)
                }
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
            let stamp = pendingStamp
            pending = ""
            pendingStamp = nil
            guard !command.isEmpty else { continue }
            commands.append(TerminalCommand(command: command, timestamp: stamp))
        }
        return commands
    }

    /// Merges several files into one set of entries.
    ///
    /// The same command can appear in more than one file: Terminal.app seeds a
    /// restored session from its archive and then writes its own copy, and a
    /// session that was killed mid-append leaves its file behind. Identical text at
    /// the identical second is the same event, so later files drop it — but repeats
    /// *within* one file are real and are counted.
    ///
    /// Ordering is by stamp, not by file. Once files are concatenated their
    /// positions say nothing about each other, and sorting by file would rank a
    /// live session's command above a newer one just because its file sorts later.
    /// Entries with no stamp are the oldest kind — everything zsh wrote before
    /// `EXTENDED_HISTORY` was turned on — so they sink to the front, keeping file
    /// order among themselves.
    static func merge(_ streams: [[TerminalCommand]]) -> [TerminalEntry] {
        var seen: Set<String> = []
        var ordered: [TerminalCommand] = []

        for stream in streams {
            var mine: Set<String> = []
            for command in stream {
                let key = Self.key(command)
                guard !seen.contains(key) else { continue }
                mine.insert(key)
                ordered.append(command)
            }
            seen.formUnion(mine)
        }

        let sorted = ordered.enumerated()
            .sorted { lhs, rhs in
                let left = lhs.element.timestamp ?? .distantPast
                let right = rhs.element.timestamp ?? .distantPast
                return left == right ? lhs.offset < rhs.offset : left < right
            }
            .map(\.element)

        var entries: [TerminalEntry] = []
        var indexByCommand: [String: Int] = [:]
        for (position, command) in sorted.enumerated() {
            if let existing = indexByCommand[command.command] {
                entries[existing].uses += 1
                entries[existing].lastPosition = position
                // Later in the merge means later in time, so the newest stamp wins.
                if let stamp = command.timestamp { entries[existing].lastRun = stamp }
            } else {
                indexByCommand[command.command] = entries.count
                entries.append(TerminalEntry(
                    command: command.command,
                    uses: 1,
                    lastPosition: position,
                    lastRun: command.timestamp
                ))
            }
        }
        return entries
    }

    private static func key(_ command: TerminalCommand) -> String {
        // `\u{1}` cannot appear in a command line, so it cannot make two different
        // commands collide.
        "\(command.timestamp?.timeIntervalSince1970 ?? -1)\u{1}\(command.command)"
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
