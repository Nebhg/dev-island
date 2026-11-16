import Foundation

/// What the keyboard does on one panel.
///
/// One conformance per panel, registered with the model at launch. The model never
/// asks a panel by name: `←`/`→` walk `PanelID.contentPanels` and each panel answers
/// for itself, so adding a panel is a conformance rather than a fourth `switch` that
/// has to stay in agreement with the other three. Before this there were four places
/// encoding the same fact — `rowCount`, `rowID`, `selectedRowIndex`, and a hardcoded
/// `[.clipboard, .terminal]` for cycling — and nothing made them agree.
///
/// `←`/`→` are **not** here. Changing panel means the same thing everywhere, so it
/// stays in the model; only the vertical axis is the panel's own business.
protocol PanelKeyboard: AnyObject {
    /// Row ids the keyboard can select, in display order.
    ///
    /// `nil` for a panel with no list at all — Music, which has keys of its own. `[]`
    /// for a list that happens to be empty, which is a different thing: there is still
    /// a list, so the panel takes part in navigation and the highlight simply matches
    /// nothing. A panel opts out of being a list by returning `nil`, never by having
    /// no rows today.
    var rowIDs: [String]? { get }

    /// `↑` / `↓`, called only for the panel that is showing.
    func moveVertical(_ delta: Int)

    /// `↩`, and the click path — both go through here, which is why `autoPaste` is a
    /// parameter rather than something the keyboard decides.
    func activate(_ rowID: String, autoPaste: Bool)
}

// MARK: - Clipboard

/// Clipboard history. The only panel where activating has a side effect on the data:
/// pasting bumps the entry's frecency.
final class ClipboardKeyboard: PanelKeyboard {
    private let model: IslandModel

    init(model: IslandModel) {
        self.model = model
    }

    var rowIDs: [String]? { model.clipboard.visible.map(\.id) }

    func moveVertical(_ delta: Int) {
        model.moveSelection(in: .clipboard, by: delta)
    }

    func activate(_ rowID: String, autoPaste: Bool) {
        guard let entry = model.clipboard.visible.first(where: { $0.id == rowID }) else { return }
        model.pasteClipboard(entry, autoPaste: autoPaste)
    }
}

// MARK: - Terminal

/// `~/.zsh_history`. Activating must **not** write the command into clipboard history,
/// which is the one behavioural difference from the clipboard panel and the reason
/// these are two conformances and not one generic one.
final class TerminalKeyboard: PanelKeyboard {
    private let model: IslandModel

    init(model: IslandModel) {
        self.model = model
    }

    var rowIDs: [String]? { model.terminal.visible.map(\.id) }

    func moveVertical(_ delta: Int) {
        model.moveSelection(in: .terminal, by: delta)
    }

    func activate(_ rowID: String, autoPaste: Bool) {
        guard let entry = model.terminal.visible.first(where: { $0.id == rowID }) else { return }
        model.pasteTerminal(entry, autoPaste: autoPaste)
    }
}

// MARK: - Shelf

/// The file shelf. A row's id is the item's UUID as a string, and `↩` opens the file
/// rather than pasting it — `autoPaste` has nothing to say here.
final class ShelfKeyboard: PanelKeyboard {
    private let model: IslandModel

    init(model: IslandModel) {
        self.model = model
    }

    var rowIDs: [String]? { model.shelf.items.map(\.id.uuidString) }

    func moveVertical(_ delta: Int) {
        model.moveSelection(in: .shelf, by: delta)
    }

    func activate(_ rowID: String, autoPaste: Bool) {
        guard let item = model.shelf.items.first(where: { $0.id.uuidString == rowID }) else { return }
        model.shelf.open(item)
    }
}

// MARK: - Music

/// Now-playing. No rows: `↑`/`↓` are the panel's own keys and change the system
/// volume, and `↩` is play/pause. It is a navigation target with no selection, which
/// is what `rowIDs == nil` means.
final class MusicKeyboard: PanelKeyboard {
    private let model: IslandModel

    init(model: IslandModel) {
        self.model = model
    }

    var rowIDs: [String]? { nil }

    func moveVertical(_ delta: Int) {
        guard let level = SystemVolume.adjust(by: Float(delta)) else {
            model.showVolumeNotice("No volume control")
            return
        }
        model.showVolumeNotice("Volume \(level)%")
    }

    func activate(_ rowID: String, autoPaste: Bool) {
        model.player.toggle()
    }
}


// MARK: - Settings

/// The settings panel. Every row is a control, so `↩` advances it — a switch flips, a
/// picker moves to its next value — which makes the whole panel usable without the
/// pointer and without a second verb.
final class SettingsKeyboard: PanelKeyboard {
    private let model: IslandModel

    init(model: IslandModel) {
        self.model = model
    }

    var rowIDs: [String]? { SettingsRow.allCases.map(\.rawValue) }

    func moveVertical(_ delta: Int) {
        model.moveSelection(in: .settings, by: delta)
    }

    func activate(_ rowID: String, autoPaste: Bool) {
        guard let row = SettingsRow(rawValue: rowID) else { return }
        row.advance(model: model)
    }
}
