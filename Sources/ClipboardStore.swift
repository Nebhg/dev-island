import CryptoKit
import Foundation

// MARK: - Entry

enum ClipKind: String, Codable {
    case text
    case command
    case url
    case path
    case code

    /// Shown at the leading edge of every chip and row, so the list is scannable
    /// without reading the text.
    var symbol: String {
        switch self {
        case .text: "text.alignleft"
        case .command: "terminal"
        case .url: "link"
        case .path: "folder"
        case .code: "curlybraces"
        }
    }
}

/// One clipboard entry. `hash` is the identity: re-copying the same text bumps
/// `uses` rather than creating a second row.
struct ClipEntry: Codable, Identifiable, Equatable {
    var id: String { hash }
    let hash: String
    var text: String
    var kind: ClipKind
    var firstSeen: Date
    var lastUsed: Date

    /// When this text was last **copied onto the clipboard**.
    ///
    /// Deliberately separate from `lastUsed`, which also moves when an entry is
    /// pasted from the island. Showing that made a path copied yesterday read
    /// "1m" simply because it had been clicked once, which looks like the clock is
    /// broken. Optional so stores written before this field still decode.
    var lastCopied: Date?

    var uses: Int

    /// What the row's age chip shows. Falls back to `firstSeen` for entries
    /// written before `lastCopied` existed.
    var copiedAt: Date { lastCopied ?? firstSeen }

    /// Single-line preview with whitespace runs collapsed. Multi-line pastes
    /// otherwise render as ragged two-line rows that make the list look broken.
    var preview: String {
        text
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\t", with: " ")
            .split(separator: " ", omittingEmptySubsequences: true)
            .joined(separator: " ")
    }
}

// MARK: - Ranking

/// Shared by the clipboard and (later) the terminal panel, so the ranking exists
/// once. Half-life of 14 days: an entry used once a fortnight keeps its weight.
enum Frecency {
    static func score(_ entry: ClipEntry, now: Date = Date()) -> Double {
        let days = max(0, now.timeIntervalSince(entry.lastUsed) / 86_400)
        return Double(entry.uses) * pow(0.5, days / 14)
    }

    static func ranked(_ entries: [ClipEntry], limit: Int, now: Date = Date()) -> [ClipEntry] {
        entries
            .sorted {
                let a = score($0, now: now)
                let b = score($1, now: now)
                // Ties go to the more recently used entry, otherwise equal-scoring
                // rows reorder arbitrarily between renders.
                return a == b ? $0.lastUsed > $1.lastUsed : a > b
            }
            .prefix(limit)
            .map { $0 }
    }
}

// MARK: - Persistence

/// JSON store in Application Support, mode 0600, capped, debounced writes.
///
/// The cap and the debounce both exist because this file is rewritten on every
/// copy: without the debounce a burst of copies rewrites it dozens of times, and
/// without the cap it grows without bound.
final class ClipboardStore {
    static let cap = 300

    private(set) var entries: [ClipEntry] = []
    private let url: URL
    private var saveWork: DispatchWorkItem?

    init(directory: URL? = nil) {
        url = AppSupport.directory(override: directory).appendingPathComponent("clipboard.json")
        load()
    }

    // MARK: Reading

    /// Inserts or bumps an entry, returning it. Returns nil for text that should
    /// not be stored at all.
    @discardableResult
    func record(_ raw: String, now: Date = Date()) -> ClipEntry? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.count < 100_000 else { return nil }

        let hash = Self.hash(of: text)
        if let index = entries.firstIndex(where: { $0.hash == hash }) {
            var entry = entries.remove(at: index)
            entry.uses += 1
            entry.lastUsed = now
            entry.lastCopied = now
            entry.text = text
            entries.insert(entry, at: 0)
            scheduleSave()
            return entry
        }

        let entry = ClipEntry(
            hash: hash,
            text: text,
            kind: Self.kind(of: text),
            firstSeen: now,
            lastUsed: now,
            lastCopied: now,
            uses: 1
        )
        entries.insert(entry, at: 0)
        if entries.count > Self.cap {
            // Oldest-by-last-used goes first, not oldest-by-first-seen: a pinned
            // favourite that keeps being reused should outlive a one-off.
            entries.sort { $0.lastUsed > $1.lastUsed }
            entries.removeLast(entries.count - Self.cap)
        }
        scheduleSave()
        return entry
    }

    /// Marks an entry as used again without changing its text.
    ///
    /// Updates `lastUsed` (which drives frecency and eviction) but **not**
    /// `lastCopied`, and leaves the row where it is. Pasting something is not
    /// copying it: rewriting the timestamp made a day-old entry claim it was a
    /// minute old, and moving it to the top made the list shuffle under the
    /// pointer just after a click.
    func touch(hash: String, now: Date = Date()) {
        guard let index = entries.firstIndex(where: { $0.hash == hash }) else { return }
        entries[index].uses += 1
        entries[index].lastUsed = now
        scheduleSave()
    }

    func remove(hash: String) {
        entries.removeAll { $0.hash == hash }
        scheduleSave()
    }

    func clear() {
        entries.removeAll()
        scheduleSave()
    }

    // MARK: Classification

    static func hash(of text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    static func kind(of text: String) -> ClipKind {
        if text.contains("\n") { return .code }
        if let url = URL(string: text), url.scheme != nil, url.host != nil { return .url }
        if text.hasPrefix("/") || text.hasPrefix("~/") || text.hasPrefix("./") { return .path }
        let commands = [
            "git ", "cd ", "ls ", "npm ", "npx ", "yarn ", "pnpm ", "brew ", "docker ",
            "kubectl ", "python", "swift", "make", "cargo ", "go ", "sudo ", "curl ",
            "ssh ", "scp ", "rsync ", "chmod ", "mkdir ", "rm ", "mv ", "cp "
        ]
        if commands.contains(where: { text.hasPrefix($0) }) { return .command }
        return .text
    }

    /// Deliberately conservative: a false positive costs one clipboard entry, a
    /// false negative writes a credential to disk in plain text.
    static func looksSecret(_ text: String) -> Bool {
        let patterns = [
            "(?i)(password|passwd|secret|token|api[_-]?key|bearer|private[_-]?key)\\s*[:=]\\s*\\S{6,}",
            "^[A-Za-z0-9+/=_-]{40,}$"
        ]
        return patterns.contains { text.range(of: $0, options: .regularExpression) != nil }
    }

    // MARK: Disk

    private func load() {
        guard let data = try? Data(contentsOf: url) else { return }
        guard let decoded = try? JSONDecoder().decode([ClipEntry].self, from: data) else { return }
        // Sort by copy time rather than trusting the file order: entries written
        // before `lastCopied` existed carry an order based on last *use*, which
        // would leave the age column jumping around.
        entries = Array(decoded.sorted { $0.copiedAt > $1.copiedAt }.prefix(Self.cap))
    }

    private func scheduleSave() {
        saveWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.save() }
        saveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: work)
    }

    private func save() {
        // `0600`: clipboard history is the most sensitive thing this app holds.
        AtomicJSON.write(entries, to: url)
    }
}
