import Combine
import Foundation

/// Terminal history: watch `~/.zsh_history`, parse it, filter trivia, rank.
///
/// Unlike the clipboard this needs no background capture — it reads a file zsh
/// already maintains — so the watcher starts and stops with the panel, which is
/// the normal provider lifecycle.
final class TerminalService: ObservableObject {
    /// Most recently used first: this is a history view, so file position leads
    /// and the use count is the secondary signal.
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
    private var source: DispatchSourceFileSystemObject?
    private var watchedFD: Int32 = -1

    /// `ISLAND_HISTORY` points the panel at a fixture instead of the real file,
    /// so the window filters can be exercised without touching shell history.
    private static var historyPath: String {
        ProcessInfo.processInfo.environment["ISLAND_HISTORY"]
            ?? NSString(string: "~/.zsh_history").expandingTildeInPath
    }

    private static var zshrcPath: String {
        NSString(string: "~/.zshrc").expandingTildeInPath
    }

    init(rules: IgnoreRules) {
        self.rules = rules
        if let stored = UserDefaults.standard.string(forKey: Self.windowKey),
           let restored = HistoryWindow(rawValue: stored) {
            window = restored
        }
    }

    deinit {
        source?.cancel()
    }

    // MARK: - Watching

    func startWatching() {
        refresh()
        guard source == nil else { return }

        let fd = open(Self.historyPath, O_EVTONLY)
        guard fd >= 0 else { return }
        watchedFD = fd

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .extend, .delete, .rename, .attrib],
            queue: .main
        )
        source.setEventHandler { [weak self] in
            guard let self, let source = self.source else { return }
            let flags = source.data
            if flags.contains(.delete) || flags.contains(.rename) {
                // zsh replaces the file on some operations; re-arm on the path.
                self.stopWatching()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { self.startWatching() }
            } else {
                self.refresh()
            }
        }
        source.setCancelHandler { close(fd) }
        source.resume()
        self.source = source
    }

    func stopWatching() {
        source?.cancel()
        source = nil
        watchedFD = -1
    }

    // MARK: - Parsing

    func refresh() {
        guard let data = FileManager.default.contents(atPath: Self.historyPath) else {
            entries = []
            notice = "No ~/.zsh_history yet — run a command in a new shell."
            return
        }
        // zsh history is normally UTF-8 but can contain raw bytes from odd input.
        let text = String(data: data, encoding: .utf8)
            ?? String(decoding: data, as: UTF8.self)

        entries = TerminalHistory.parse(text)
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
}
