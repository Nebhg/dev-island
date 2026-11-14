import AppKit
import Combine
import Foundation

/// One thing parked on the shelf.
///
/// A **reference**, never a copy: removing a row must not touch the real file.
/// `payload` is the path for `.file`, the text itself for `.text`, and the URL
/// string for `.link`.
struct ShelfItem: Identifiable, Codable, Equatable {
    enum Kind: String, Codable {
        case file
        case text
        case link
    }

    let id: UUID
    var kind: Kind
    var payload: String
    /// Plain (not security-scoped) bookmark. Dev Island is unsandboxed, so a bare
    /// path would keep working forever; the bookmark earns its place by surviving
    /// a rename or a move, which a path does not.
    var bookmark: Data?
    var added: Date

    init(
        id: UUID = UUID(),
        kind: Kind,
        payload: String,
        bookmark: Data? = nil,
        added: Date = Date()
    ) {
        self.id = id
        self.kind = kind
        self.payload = payload
        self.bookmark = bookmark
        self.added = added
    }

    var name: String {
        switch kind {
        case .file:
            return (payload as NSString).lastPathComponent
        case .text:
            let firstLine = payload.split(separator: "\n").first.map(String.init) ?? payload
            return firstLine.isEmpty ? "Text" : firstLine
        case .link:
            return URL(string: payload)?.host ?? payload
        }
    }

    /// Resolved location, preferring the bookmark so a moved file still opens.
    var url: URL? {
        guard kind == .file else { return nil }
        if let bookmark {
            var stale = false
            if let resolved = try? URL(
                resolvingBookmarkData: bookmark,
                options: [],
                relativeTo: nil,
                bookmarkDataIsStale: &stale
            ) {
                return resolved
            }
        }
        return URL(fileURLWithPath: payload)
    }

    /// A dead reference is shown as dead rather than silently removed: a row that
    /// vanishes on its own looks like data loss.
    var isMissing: Bool {
        guard kind == .file, let url else { return false }
        return !FileManager.default.fileExists(atPath: url.path)
    }

    /// Identity for dedupe. Files compare by resolved path so dropping the same
    /// file twice does not create two rows.
    var identity: String {
        switch kind {
        case .file: return url?.path ?? payload
        case .text, .link: return payload
        }
    }
}

/// The shelf: a staging area in transit, not a file manager.
///
/// Writes are immediate rather than debounced. Unlike the clipboard, nothing here
/// changes in bursts — every mutation is a user action — so there is no write
/// amplification to avoid, and a dropped file must survive an immediate crash.
final class ShelfStore: ObservableObject {
    static let cap = 30

    @Published private(set) var items: [ShelfItem] = []

    private let url: URL

    init(directory: URL? = nil) {
        let base = directory ?? FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Dev Island", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        url = base.appendingPathComponent("shelf.json")
        load()
    }

    // MARK: - Adding

    /// Adds file references, returning how many were new.
    @discardableResult
    func addFiles(_ urls: [URL]) -> Int {
        let fresh = urls.filter(\.isFileURL).map { fileURL in
            ShelfItem(
                kind: .file,
                payload: fileURL.path,
                bookmark: Self.bookmark(for: fileURL)
            )
        }
        return insert(fresh)
    }

    @discardableResult
    func addText(_ text: String) -> Int {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count < 100_000 else { return 0 }
        return insert([ShelfItem(kind: .text, payload: trimmed)])
    }

    @discardableResult
    func addLink(_ link: URL) -> Int {
        insert([ShelfItem(kind: .link, payload: link.absoluteString)])
    }

    /// Newest first, deduped against what is already there and within the cap.
    private func insert(_ new: [ShelfItem]) -> Int {
        guard !new.isEmpty else { return 0 }

        var seen = Set(items.map(\.identity))
        var accepted: [ShelfItem] = []
        for item in new where !seen.contains(item.identity) {
            seen.insert(item.identity)
            accepted.append(item)
        }
        guard !accepted.isEmpty else { return 0 }

        items.insert(contentsOf: accepted.reversed(), at: 0)
        if items.count > Self.cap {
            items.removeLast(items.count - Self.cap)
        }
        save()
        return accepted.count
    }

    // MARK: - Mutating

    func remove(_ item: ShelfItem) {
        items.removeAll { $0.id == item.id }
        save()
    }

    func clear() {
        items.removeAll()
        save()
    }

    // MARK: - Actions

    func reveal(_ item: ShelfItem) {
        guard let url = item.url else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    func open(_ item: ShelfItem) {
        switch item.kind {
        case .file:
            guard let url = item.url else { return }
            NSWorkspace.shared.open(url)
        case .link:
            if let url = URL(string: item.payload) { NSWorkspace.shared.open(url) }
        case .text:
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(item.payload, forType: .string)
        }
    }

    func copyPath(_ item: ShelfItem) {
        guard item.kind == .file else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(item.url?.path ?? item.payload, forType: .string)
    }

    // MARK: - Disk

    private static func bookmark(for url: URL) -> Data? {
        // Plain bookmark, no security scope: there is no sandbox to escape, and a
        // scoped bookmark on an unsandboxed app just fails to resolve.
        try? url.bookmarkData(
            options: [],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
    }

    private func load() {
        guard let data = try? Data(contentsOf: url) else { return }
        guard let decoded = try? JSONDecoder().decode([ShelfItem].self, from: data) else { return }
        items = Array(decoded.prefix(Self.cap))
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(items) else { return }
        let temp = url.appendingPathExtension("tmp")
        do {
            try data.write(to: temp, options: .atomic)
            // Write, then chmod: creating with default permissions and fixing them
            // afterwards leaves a window where the file is world-readable.
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600], ofItemAtPath: temp.path
            )
            _ = try FileManager.default.replaceItemAt(url, withItemAt: temp)
        } catch {
            try? FileManager.default.removeItem(at: temp)
        }
    }
}
