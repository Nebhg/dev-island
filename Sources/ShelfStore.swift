import AppKit
import Combine
import Foundation

/// One file parked on the shelf.
///
/// A **reference**, never a copy: removing a row must not touch the real file.
struct ShelfItem: Identifiable, Codable, Equatable {
    let id: UUID
    /// Absolute path at the time it was dropped. `bookmark` is preferred when
    /// resolving, because it survives a move or a rename.
    var path: String
    /// Plain (not security-scoped) bookmark. Dev Island is unsandboxed, so a bare
    /// path would keep working forever; the bookmark earns its place by surviving
    /// a move, which a path does not.
    var bookmark: Data?
    var added: Date

    /// `path` was stored as `payload` in the build that also held text and links.
    /// Reading the old key keeps an existing shelf from being thrown away on
    /// upgrade; a leftover text entry then fails the absolute-path check in
    /// `ShelfStore.load` and is pruned.
    private enum CodingKeys: String, CodingKey {
        case id, bookmark, added
        case path = "payload"
    }

    init(id: UUID = UUID(), path: String, bookmark: Data? = nil, added: Date = Date()) {
        self.id = id
        self.path = path
        self.bookmark = bookmark
        self.added = added
    }

    var name: String { (path as NSString).lastPathComponent }

    /// Resolved location, preferring the bookmark so a moved file still opens.
    var url: URL {
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
        return URL(fileURLWithPath: path)
    }

    /// A dead reference, which can only happen mid-session: files whose path is
    /// gone are pruned on load. A file deleted while the panel is open stays
    /// visible rather than vanishing under the pointer.
    var isMissing: Bool {
        !FileManager.default.fileExists(atPath: url.path)
    }

    /// Identity for dedupe, so dropping the same file twice does not make two rows.
    var identity: String { url.path }
}

/// The shelf: a staging area in transit, not a file manager.
///
/// Files only. Text and links belong to the clipboard — copying them is one
/// keystroke and it captures them automatically — so a shelf row would only be a
/// second place to look for the same string. A file is the one thing the clipboard
/// cannot hand back as a usable reference.
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
            ShelfItem(path: fileURL.path, bookmark: Self.bookmark(for: fileURL))
        }
        return insert(fresh)
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
        NSWorkspace.shared.activateFileViewerSelecting([item.url])
    }

    func open(_ item: ShelfItem) {
        NSWorkspace.shared.open(item.url)
    }

    func copyPath(_ item: ShelfItem) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(item.url.path, forType: .string)
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

        // Prune anything that is not a live file reference. A shelf full of dead
        // rows is worse than a shorter shelf, and the bookmark cannot help once the
        // target is deleted. Only at load: a file removed while the panel is open
        // should not make its row disappear under the pointer mid-interaction.
        //
        // The absolute-path check also drops leftovers from the build that accepted
        // text and links, whose "path" was the text itself.
        let live = decoded.filter { item in
            guard item.path.hasPrefix("/") else { return false }
            return FileManager.default.fileExists(atPath: item.url.path)
        }

        items = Array(live.prefix(Self.cap))
        if live.count != decoded.count {
            save()
        }
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
