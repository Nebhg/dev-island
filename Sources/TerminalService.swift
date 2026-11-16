import Combine
import Foundation

/// Terminal history: watch the shells' history files, parse them, filter trivia,
/// rank.
///
/// Unlike the clipboard this needs no background capture — it reads files zsh
/// already maintains — so the watcher starts and stops with the panel, which is
/// the normal provider lifecycle.
final class TerminalService: ObservableObject {
    /// Most recently used first: this is a history view, so recency leads and the
    /// use count is the secondary signal.
    ///
    /// Sorted here rather than in the view. `body` cannot sort it, because the
    /// panel re-renders on every model change — including the 1.5 s player poll —
    /// so ~330 entries were being re-sorted several times a second.
    @Published private(set) var entries: [TerminalEntry] = [] {
        didSet { rebuild() }
    }
    @Published private(set) var notice: String?

    /// How far back the panel shows. A filter only — see `HistoryWindow`.
    @Published var window: HistoryWindow = .all {
        didSet {
            UserDefaults.standard.set(window.rawValue, forKey: Self.windowKey)
            rebuild()
        }
    }

    /// Entries inside `window`, newest first. The list renders this rather than
    /// `entries`.
    private(set) var visible: [TerminalEntry] = []

    /// Top entries for the chip strip, ranked within `window` for the same reason
    /// as the sort above.
    private(set) var frequent: [TerminalEntry] = []

    private static let frequentLimit = 3
    private static let windowKey = "terminalWindow"

    private func rebuild() {
        let now = Date()
        visible = entries.filter { window.includes($0.lastRun, now: now) }
        frequent = TerminalHistory.ranked(visible, limit: Self.frequentLimit)
    }

    private let rules: IgnoreRules
    private var watches: [DispatchSourceFileSystemObject] = []
    /// Whether the panel has asked for watching. Kept separately from `watches`
    /// because a re-arm briefly empties it, and a re-arm that lands after the
    /// panel closed must not put the descriptors back.
    private var isWatching = false

    /// `ISLAND_HISTORY` points the panel at a fixture instead of the real files,
    /// so the window filters can be exercised without touching shell history.
    private static var historyPath: String {
        ProcessInfo.processInfo.environment["ISLAND_HISTORY"]
            ?? NSString(string: "~/.zsh_history").expandingTildeInPath
    }

    /// Where macOS's Terminal integration keeps its per-session history.
    private static var sessionsPath: String {
        NSString(string: "~/.zsh_sessions").expandingTildeInPath
    }

    init(rules: IgnoreRules) {
        self.rules = rules
        if let stored = UserDefaults.standard.string(forKey: Self.windowKey),
           let restored = HistoryWindow(rawValue: stored) {
            window = restored
        }
    }

    deinit {
        cancelWatches()
    }

    // MARK: - Sources

    /// Every file the shells are writing to, oldest first.
    ///
    /// `~/.zsh_history` is usually not the whole story. macOS's
    /// `/etc/zshrc_Apple_Terminal` redirects `HISTFILE` to
    /// `~/.zsh_sessions/<session>.historynew` for any session that was restored,
    /// and a restored session is the normal case on a laptop that sleeps. The
    /// shared file is only appended to when that session *exits*, so a terminal
    /// left open all week freezes it — which is exactly what "history is stuck at
    /// one point" looks like. Each live session appends to its own file on every
    /// command, so that is where the recent ones are.
    static func historySources() -> [URL] {
        if let fixture = ProcessInfo.processInfo.environment["ISLAND_HISTORY"] {
            return [URL(fileURLWithPath: fixture)]
        }

        var urls: [URL] = []
        let shared = URL(fileURLWithPath: historyPath)
        if FileManager.default.fileExists(atPath: shared.path) {
            urls.append(shared)
        }

        // Only the live files. A `.history` file is the copy a session leaves
        // behind when it exits, and by then that content has already been appended
        // to the shared file, so reading those would count the same command twice.
        let sessions = (try? FileManager.default.contentsOfDirectory(
            at: URL(fileURLWithPath: sessionsPath),
            includingPropertiesForKeys: [.contentModificationDateKey]
        )) ?? []
        urls += sessions
            .filter { $0.pathExtension == "historynew" }
            .sorted { modified($0) < modified($1) }
        return urls
    }

    private static func modified(_ url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
            .contentModificationDate ?? .distantPast
    }

    // MARK: - Watching

    func startWatching() {
        refresh()
        guard !isWatching else { return }
        isWatching = true
        arm()
    }

    /// Opens one descriptor per path, including the sessions directory so a file
    /// appearing or disappearing is noticed without polling.
    private func arm() {
        guard watches.isEmpty else { return }
        for path in Self.watchPaths() {
            guard let watch = makeWatch(path) else { continue }
            watches.append(watch)
        }
    }

    private static func watchPaths() -> [String] {
        // A fixture is a single file and nothing else: there is no session
        // directory to watch, and watching the real one would defeat the point.
        guard ProcessInfo.processInfo.environment["ISLAND_HISTORY"] == nil else {
            return [historyPath]
        }
        return historySources().map(\.path) + [sessionsPath]
    }

    private func makeWatch(_ path: String) -> DispatchSourceFileSystemObject? {
        let fd = open(path, O_EVTONLY)
        guard fd >= 0 else { return nil }

        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory)
        let directory = exists && isDirectory.boolValue

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .extend, .delete, .rename, .attrib],
            queue: .main
        )
        source.setEventHandler { [weak self, weak source] in
            guard let self, let source, !source.isCancelled else { return }
            if directory || source.data.contains(.delete) || source.data.contains(.rename) {
                // The set of files to watch is itself the change: a session
                // started or exited, or a path was replaced under us. Rebuild
                // rather than guess which descriptor is now stale.
                self.rearm()
            } else {
                self.refresh()
            }
        }
        source.setCancelHandler { close(fd) }
        source.resume()
        return source
    }

    /// Cancels every descriptor, then watches again from a fresh list. The pause
    /// lets the cancelled descriptors close before the same paths are reopened.
    private func rearm() {
        cancelWatches()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            guard let self, self.isWatching else { return }
            self.arm()
        }
    }

    func stopWatching() {
        isWatching = false
        cancelWatches()
    }

    private func cancelWatches() {
        for watch in watches { watch.cancel() }
        watches.removeAll()
    }

    // MARK: - Parsing

    func refresh() {
        let sources = Self.historySources()
        guard !sources.isEmpty else {
            entries = []
            notice = "No ~/.zsh_history yet — run a command in a new shell."
            return
        }

        let streams = sources.compactMap { url -> [TerminalCommand]? in
            guard let data = FileManager.default.contents(atPath: url.path) else { return nil }
            // zsh history is normally UTF-8 but can contain raw bytes from odd input.
            let text = String(data: data, encoding: .utf8)
                ?? String(decoding: data, as: UTF8.self)
            return TerminalHistory.parse(text)
        }

        entries = TerminalHistory.merge(streams)
            .filter { !rules.ignores($0.command) }
            .sorted { $0.lastPosition > $1.lastPosition }
        notice = Self.flushNotice()
    }

    /// Without one of these options zsh only writes history when a shell exits, so
    /// the panel would silently show stale commands and look broken.
    private static func flushNotice() -> String? {
        let message = "Add `setopt INC_APPEND_HISTORY` to ~/.zshrc so history updates live."
        guard let text = try? String(contentsOfFile: zshrcPath, encoding: .utf8) else {
            return message
        }
        if text.contains("INC_APPEND_HISTORY") || text.contains("SHARE_HISTORY") {
            return nil
        }
        return message
    }

    private static var zshrcPath: String {
        NSString(string: "~/.zshrc").expandingTildeInPath
    }
}
