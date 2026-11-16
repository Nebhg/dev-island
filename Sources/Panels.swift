import AppKit
import Combine

// MARK: - Identity

/// One panel of the island. Each owns an icon and a lifecycle.
///
/// Order is the on-screen order: the first two sit left of the notch, the rest
/// right of it, so `allCases` also drives cycling and the ⌥⌘1–5 shortcuts.
enum PanelID: String, CaseIterable, Identifiable {
    case clipboard
    case terminal
    case shelf
    case music
    case settings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .music: "Music"
        case .clipboard: "Clipboard"
        case .terminal: "Terminal"
        case .shelf: "Shelf"
        case .settings: "Settings"
        }
    }

    var symbol: String {
        switch self {
        case .music: "music.note"
        case .clipboard: "doc.on.clipboard"
        case .terminal: "terminal"
        case .shelf: "tray.full"
        case .settings: "gearshape"
        }
    }

    /// The panels that hold something. Settings is a detour: it is never a default
    /// panel and never the one hover reopens on.
    static let contentPanels: [PanelID] = allCases.filter { $0 != .settings }

    /// Icons flank the physical cutout, using the menu-bar space either side of it
    /// that the island otherwise leaves empty.
    static let leftPanels: [PanelID] = [.clipboard, .terminal]
    static let rightPanels: [PanelID] = [.shelf, .music, .settings]

    /// Sizes are per panel rather than one constant: the two list panels want
    /// width for long rows, the other two want less of both. Clipboard and
    /// terminal share a size, so switching between them moves nothing at all.
    ///
    /// A size change is handled by growing the window to `max(old, new)` before
    /// the shape animates, so the window is never smaller than the shape — see
    /// `IslandController.scheduleSettle(to:on:)`.
    ///
    /// The shelf, music and settings panels are exceptions: their heights come from
    /// `shelfHeight(forItems:notchHeight:)`, `MusicLayout.panelHeight(notchHeight:)`
    /// and `settingsHeight(notchHeight:)` (see `IslandModel.islandSize`). The
    /// shelf's value here is its cap; the others' are their heights on a 32 pt notch.
    var preferredSize: CGSize {
        switch self {
        case .clipboard, .terminal: CGSize(width: 520, height: 320)
        case .shelf: CGSize(width: 440, height: PanelID.maxShelfHeight)
        case .music: CGSize(width: MusicLayout.panelWidth, height: MusicLayout.panelHeight(notchHeight: 32))
        case .settings: CGSize(width: 520, height: PanelID.settingsHeight(notchHeight: 32))
        }
    }

    /// Settings rows: a label with a one-line hint under it, and a control.
    static let settingsRowHeight: CGFloat = 34
    static let settingsRowCount = 7

    /// The switcher band, the panel padding above and below, and the rows with a
    /// 1 pt gap between them — the same gap the history lists use.
    static func settingsHeight(notchHeight: CGFloat) -> CGFloat {
        let rows = CGFloat(settingsRowCount)
        return notchHeight + 2 * IslandMetrics.panelPadding + rows * settingsRowHeight + (rows - 1)
    }

    /// Tallest the shelf gets before its list scrolls instead.
    static let maxShelfHeight: CGFloat = 260

    /// The shelf sizes to its contents. A fixed height reserved room for six rows
    /// even with one file dropped, leaving a mostly empty card hanging under the
    /// notch for no reason.
    ///
    /// The constants are the shell's, not guesses: the panel padding above and
    /// below, `14 + 6` the header row and the gap under it, and each row is
    /// `30 pt` with a `1 pt` gap between rows.
    static func shelfHeight(forItems count: Int, notchHeight: CGFloat) -> CGFloat {
        let chrome = notchHeight + 2 * IslandMetrics.panelPadding + 14 + 6
        guard count > 0 else {
            // The empty state is two lines of text under an icon, so it needs more
            // than one row does. Kept as its own case rather than floored at the
            // row height, which would clip it.
            return chrome + 58
        }
        let rows = CGFloat(count) * 31 - 1
        return min(chrome + rows, maxShelfHeight)
    }
}

// MARK: - Provider lifecycle

/// A feature that only runs while its own panel is on screen.
///
/// The rule this exists to enforce: nothing polls unless the user is looking at
/// it. `start` is called when the island is open *and* this panel is active;
/// `stop` when either stops being true.
protocol PanelProvider: AnyObject {
    var id: PanelID { get }
    func start()
    func stop()
}

/// Starts and stops providers as the active panel changes.
///
/// Providers are started one at a time, so a feature cannot leave a timer
/// running after the user switches away from it.
final class PanelHost {
    private let model: IslandModel
    private var providers: [PanelID: PanelProvider] = [:]
    private var running: PanelID?
    private var cancellables = Set<AnyCancellable>()

    init(model: IslandModel) {
        self.model = model

        providers[.clipboard] = ClipboardProvider(model: model)
        providers[.terminal] = TerminalProvider(model: model)
        providers[.shelf] = ShelfProvider(model: model)
        providers[.settings] = SettingsProvider(model: model)

        Publishers.CombineLatest(model.$expanded, model.$activePanel)
            .receive(on: RunLoop.main)
            .sink { [weak self] expanded, panel in
                self?.update(expanded: expanded, panel: panel)
            }
            .store(in: &cancellables)
    }

    private func update(expanded: Bool, panel: PanelID) {
        let wanted: PanelID? = expanded ? panel : nil
        guard wanted != running else { return }

        if let running, let provider = providers[running] {
            provider.stop()
        }
        running = wanted
        if let wanted, let provider = providers[wanted] {
            provider.start()
        }
    }
}

// MARK: - Placeholder providers

/// Phase 2. The watcher itself runs from launch (capture has to work while the
/// island is closed, or there is no history); this provider only refreshes the
/// state that is specific to the panel being visible.
final class ClipboardProvider: PanelProvider {
    let id = PanelID.clipboard
    private let model: IslandModel

    init(model: IslandModel) {
        self.model = model
    }

    func start() {
        model.panelNotice = model.pastePermissionNotice
    }

    func stop() {}
}

/// Phase 3. Watches `~/.zsh_history` while the panel is visible. The watcher is
/// started and stopped here rather than at launch, because history is a file zsh
/// already maintains — there is nothing to capture in the background.
final class TerminalProvider: PanelProvider {
    let id = PanelID.terminal
    private let model: IslandModel
    private var noticeSubscription: AnyCancellable?

    init(model: IslandModel) {
        self.model = model
    }

    func start() {
        model.terminal.startWatching()
        // A missing grant outranks stale history: it changes what every click does.
        model.panelNotice = model.pastePermissionNotice ?? model.terminal.notice
        // The notice can appear after the first parse (file watcher, re-parse).
        noticeSubscription = model.terminal.$notice
            .receive(on: RunLoop.main)
            .sink { [weak self] notice in
                guard let self else { return }
                self.model.panelNotice = self.model.pastePermissionNotice ?? notice
            }
    }

    func stop() {
        noticeSubscription = nil
        model.terminal.stopWatching()
        model.panelNotice = nil
    }
}

/// Phase 4. Drag in/out, reference bookmarks, right-click actions.
final class ShelfProvider: PanelProvider {
    let id = PanelID.shelf
    private let model: IslandModel

    init(model: IslandModel) {
        self.model = model
    }

    func start() { model.panelNotice = nil }
    func stop() {}
}

/// Settings has no notice strip: its height is its rows, and a missing
/// Accessibility grant is said in the Autopaste row's own hint instead.
final class SettingsProvider: PanelProvider {
    let id = PanelID.settings
    private let model: IslandModel

    init(model: IslandModel) {
        self.model = model
    }

    func start() { model.panelNotice = nil }
    func stop() {}
}
