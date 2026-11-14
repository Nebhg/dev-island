import AppKit
import Combine

// MARK: - Identity

/// One panel of the island. Each owns an icon and a lifecycle.
///
/// Order is the on-screen order: the first two sit left of the notch, the last two
/// right of it, so `allCases` also drives cycling and the default-panel submenu.
enum PanelID: String, CaseIterable, Identifiable {
    case clipboard
    case terminal
    case shelf
    case music

    var id: String { rawValue }

    var title: String {
        switch self {
        case .music: "Music"
        case .clipboard: "Clipboard"
        case .terminal: "Terminal"
        case .shelf: "Shelf"
        }
    }

    var symbol: String {
        switch self {
        case .music: "music.note"
        case .clipboard: "doc.on.clipboard"
        case .terminal: "terminal"
        case .shelf: "tray.full"
        }
    }

    /// Icons flank the physical cutout, using the menu-bar space either side of it
    /// that the island otherwise leaves empty.
    static let leftPanels: [PanelID] = [.clipboard, .terminal]
    static let rightPanels: [PanelID] = [.shelf, .music]

    /// Every panel is the same size. Switching therefore cannot resize the window,
    /// which removes the animation that used to show the desktop through the island
    /// mid-switch (risk 7) instead of trying to make that animation faster.
    static let panelSize = CGSize(width: 440, height: 310)

    var preferredSize: CGSize { Self.panelSize }

    /// Every panel except music carries the compact now-playing strip, so music
    /// stays reachable without giving up the full width of a list.
    var showsPlayerStrip: Bool { self != .music }
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
        model.clipboard.refreshPermission()
        // Say why a click only copied, rather than leaving the user to guess.
        model.panelNotice = model.clipboard.canAutoPaste
            ? nil
            : "Grant Accessibility to paste directly."
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
        model.panelNotice = model.terminal.notice
        // The notice can appear after the first parse (file watcher, re-parse).
        noticeSubscription = model.terminal.$notice
            .receive(on: RunLoop.main)
            .sink { [weak self] notice in self?.model.panelNotice = notice }
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
