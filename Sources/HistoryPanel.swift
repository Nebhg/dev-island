import SwiftUI

/// What `HistoryPanel` needs from a history list.
///
/// The clipboard and the terminal are the same list twice. They differ in three
/// places — the trailing slot on a row, the empty-state copy, and which service does
/// the bookkeeping — and this is the shape of everything else. `PanelChrome` had
/// already extracted the header, the empty state, the chip and the row; this finishes
/// the extraction at the list.
protocol HistoryList: ObservableObject {
    associatedtype Entry: Identifiable where Entry.ID == String

    /// The panel this list is drawn in. It is the token the model uses to address
    /// a row — selection and pasting both go through it, so the panel never needs
    /// to know which concrete service it has.
    var panel: PanelID { get }

    var visible: [Entry] { get }
    var frequent: [Entry] { get }
    /// Whether the history holds anything at all, ignoring the window. A filtered
    /// list still needs its header, or the filter that hid it cannot be changed.
    var hasEntries: Bool { get }
    var window: HistoryWindow { get set }

    /// A leading item in the header row, before the controls. The terminal shows the
    /// filtered count so the number agrees with the rows below it.
    var headerCount: String? { get }

    func rowText(_ entry: Entry) -> String
    func rowSymbol(_ entry: Entry) -> String
    func rowMonospaced(_ entry: Entry) -> Bool
    func rowHelp(_ entry: Entry) -> String

    /// The row's right-click menu, as actions rather than a view.
    ///
    /// Data, not `AnyView`: a context menu's items are flattened by SwiftUI's menu
    /// result builder, and a type-erased view is not part of that flattening — it
    /// risks rendering as one item that does nothing. It takes the model because the
    /// terminal's Copy writes through `ClipboardService`, which is the one place a
    /// command may reach the pasteboard without the watcher storing it as a copy.
    func rowMenu(_ entry: Entry, model: IslandModel) -> HistoryRowMenu

    /// The empty list: either nothing is there, or the window excludes all of it.
    /// Each service owns its own words, because "nothing copied yet" and "no history
    /// yet" are different things.
    func emptyState(cleanLayout: Bool) -> EmptyState
}

/// One of the two "nothing here" states, in the words the panel should use.
struct EmptyState {
    let symbol: String
    let title: String
    let subtitle: String
}

/// What a row's right-click menu offers. `nil` for the items a list cannot honour:
/// the terminal's history belongs to zsh, so there is nothing there to remove.
struct HistoryRowMenu {
    let copy: () -> Void
    var remove: (() -> Void)?
    var clear: (() -> Void)?
}

/// The clipboard and the terminal, drawn once.
struct HistoryPanel<Source: HistoryList, Trailing: View>: View {
    @ObservedObject var model: IslandModel
    @ObservedObject var source: Source
    /// The row's trailing slot. The clipboard puts a live-updating age there, the
    /// terminal a use count; everything else about a row is identical.
    @ViewBuilder var trailing: (Source.Entry) -> Trailing

    var body: some View {
        VStack(spacing: 6) {
            // Clean layout leaves just the list; the controls are in Settings.
            if !model.cleanLayout {
                if source.hasEntries {
                    header
                }
                if !source.frequent.isEmpty {
                    chipRow
                }
            }

            if source.visible.isEmpty {
                emptyState
            } else {
                list
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }

    private var header: some View {
        PanelSectionHeader(title: "FREQUENT") {
            if let count = source.headerCount {
                Text(count)
                    .font(.system(size: 10))
                    .foregroundStyle(.white.opacity(0.22))
                    .padding(.trailing, 10)
            }
            PasteToggle(enabled: model.autoPasteEnabled) { model.autoPasteEnabled.toggle() }
                .padding(.trailing, 8)
            HistoryWindowPicker(window: source.window) { source.window = $0 }
        }
    }

    /// Most-used entries, one click away. Equal widths and one line each: uneven
    /// chip sizes were what made the old strip look messy.
    private var chipRow: some View {
        HStack(spacing: 6) {
            ForEach(source.frequent) { entry in
                FrequentChip(
                    symbol: source.rowSymbol(entry),
                    text: source.rowText(entry),
                    monospaced: source.rowMonospaced(entry),
                    help: "Paste “\(source.rowText(entry).prefix(80))”"
                ) { paste(entry) }
            }
        }
        .frame(height: 24)
    }

    private var list: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                rows
            }
            // Follows the selection, scrolling only as far as it takes to show it.
            // Keyed on the row id, so a row that has left the list since the
            // selection was made simply does not scroll.
            .onChange(of: model.listSelection) { _, selection in
                guard let selection, selection.panel == source.panel else { return }
                proxy.scrollTo(selection.id)
            }
        }
    }

    private var rows: some View {
        LazyVStack(spacing: 1) {
            ForEach(source.visible) { entry in
                HistoryRow(
                    symbol: source.rowSymbol(entry),
                    text: source.rowText(entry),
                    monospaced: source.rowMonospaced(entry),
                    help: source.rowHelp(entry),
                    selected: model.isSelected(source.panel, id: entry.id),
                    action: { paste(entry) }
                ) {
                    trailing(entry)
                }
                .contextMenu {
                    let menu = source.rowMenu(entry, model: model)
                    Button("Copy", action: menu.copy)
                    if let remove = menu.remove {
                        Button("Remove", role: .destructive, action: remove)
                    }
                    if let clear = menu.clear {
                        Divider()
                        Button("Clear History", role: .destructive, action: clear)
                    }
                }
                .id(entry.id)
            }
        }
        .padding(.bottom, 2)
    }

    private var emptyState: some View {
        let state = source.emptyState(cleanLayout: model.cleanLayout)
        return PanelEmptyState(
            symbol: state.symbol,
            title: state.title,
            subtitle: state.subtitle
        )
    }

    /// ⌥-click copies without pasting, for when the target app is not the one that
    /// had focus.
    private func paste(_ entry: Source.Entry) {
        let copyOnly = NSEvent.modifierFlags.contains(.option)
        model.paste(panel: source.panel, rowID: entry.id, autoPaste: !copyOnly)
    }
}

// MARK: - The clipboard, as a list

extension ClipboardService: HistoryList {
    var panel: PanelID { .clipboard }
    var hasEntries: Bool { !entries.isEmpty }
    var headerCount: String? { nil }

    func rowText(_ entry: ClipEntry) -> String { entry.preview }
    func rowSymbol(_ entry: ClipEntry) -> String { entry.kind.symbol }
    func rowMonospaced(_ entry: ClipEntry) -> Bool { entry.isMonospaced }

    func rowHelp(_ entry: ClipEntry) -> String {
        "Click to paste · ⌥-click to copy only"
    }

    func rowMenu(_ entry: ClipEntry, model: IslandModel) -> HistoryRowMenu {
        HistoryRowMenu(
            copy: { [self] in write(entry) },
            remove: { [self] in remove(entry) },
            clear: { [self] in clear() }
        )
    }

    func emptyState(cleanLayout: Bool) -> EmptyState {
        let filtered = !entries.isEmpty
        return EmptyState(
            symbol: filtered ? "line.3.horizontal.decrease" : "doc.on.clipboard",
            title: filtered
                ? "Nothing in the last \(window.span)"
                : "Nothing copied yet",
            subtitle: filtered
                ? (cleanLayout ? "Choose All in Settings to see older items" : "Pick All to see older items")
                : "Copy something and it shows up here"
        )
    }
}

// MARK: - The terminal, as the same list

extension TerminalService: HistoryList {
    var panel: PanelID { .terminal }
    var hasEntries: Bool { !entries.isEmpty }

    /// The filtered count, so the number agrees with the rows below it and clicking
    /// a window gives immediate feedback.
    var headerCount: String? {
        "\(visible.count) command\(visible.count == 1 ? "" : "s")"
    }

    func rowText(_ entry: TerminalEntry) -> String { entry.display }
    func rowSymbol(_ entry: TerminalEntry) -> String { "terminal" }
    func rowMonospaced(_ entry: TerminalEntry) -> Bool { true }

    func rowHelp(_ entry: TerminalEntry) -> String {
        entry.isSecret
            ? "Contains a credential — click to paste, ⌥-click to copy only"
            : "Click to paste · ⌥-click to copy only"
    }

    /// Copy only: this history belongs to zsh, so there is nothing here to remove or
    /// clear without editing the user's shell files.
    func rowMenu(_ entry: TerminalEntry, model: IslandModel) -> HistoryRowMenu {
        HistoryRowMenu(copy: { model.clipboard.writeText(entry.command) })
    }

    func emptyState(cleanLayout: Bool) -> EmptyState {
        let filtered = !entries.isEmpty
        return EmptyState(
            symbol: filtered ? "line.3.horizontal.decrease" : "terminal",
            title: filtered ? "Nothing in the last \(window.span)" : "No history yet",
            subtitle: filtered
                ? (cleanLayout ? "Choose All in Settings to see older commands" : "Pick All to see older commands")
                : "Run something in a new terminal"
        )
    }
}
