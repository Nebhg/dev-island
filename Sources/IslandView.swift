import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct IslandRootView: View {
    @ObservedObject var model: IslandModel

    /// The shape's size. This is the only value that animates.
    ///
    /// The content is laid out at the *target* size and never interpolated, so a
    /// panel switch reflows its text once instead of on every animation frame.
    /// That reflow-per-frame was what made switching look like the new panel was
    /// assembling itself as it faded in.
    @State private var shapeSize: CGSize

    init(model: IslandModel) {
        _model = ObservedObject(wrappedValue: model)
        _shapeSize = State(initialValue: model.islandSize)
    }

    /// Shape animation. Both are critically damped: the window is pre-grown to the
    /// larger of the two sizes and never resizes during the animation, so an
    /// overshoot would push the shape past the window and clip it.
    static let expandAnimation = Animation.spring(response: 0.36, dampingFraction: 1)
    static let collapseAnimation = Animation.spring(response: 0.24, dampingFraction: 1)

    /// Where the content is laid out, and where the shape is heading.
    private var target: CGSize { model.islandSize }

    // The insets are BoringNotch's top radii, kept as plain insets now that the top
    // corners are square, so the body of every panel is still the size its content
    // was laid out for.
    private var sideInset: CGFloat {
        model.expanded ? IslandMetrics.openInset : IslandMetrics.closedInset
    }
    private var bottomRadius: CGFloat {
        model.expanded ? IslandMetrics.openBottomRadius : IslandMetrics.closedBottomRadius
    }

    private var shape: NotchShape {
        NotchShape(sideInset: sideInset, bottomRadius: bottomRadius)
    }

    var body: some View {
        VStack(spacing: 0) {
            content
                // Laid out once, at the size the island is heading for.
                .frame(width: target.width, height: target.height, alignment: .top)
                // Then placed inside the animating shape. Only this frame moves.
                .frame(width: shapeSize.width, height: shapeSize.height, alignment: .top)
                .background(alignment: .top) {
                    ZStack(alignment: .top) {
                        shape.fill(.black)
                        // The surface belongs to the shell rather than the panel, so
                        // it fills the shape as it animates instead of sitting inside
                        // a larger card mid-switch.
                        PanelSurface()
                            .padding(.top, model.notchSize.height)
                    }
                }
                .clipShape(shape)
                // Straightens the top edge against the bezel, exactly like BoringNotch.
                .overlay(alignment: .top) {
                    Rectangle()
                        .fill(.black)
                        .frame(height: 1)
                        .padding(.horizontal, sideInset)
                        .allowsHitTesting(false)
                }
                .contentShape(shape)
                .animation(.easeInOut(duration: 0.18), value: model.expanded)

            // The acknowledgement sits under the island, not inside the shape: a
            // sentence needs more width than the chin's two 32 pt wings beside the
            // camera cutout. The window grows downwards to make room.
            if let toast = model.pasteToast {
                PasteToastView(toast: toast)
                    .padding(.top, IslandModel.toastGap)
                    .transition(.opacity)
            }

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onChange(of: target) { _, new in

            withAnimation(model.expanded ? Self.expandAnimation : Self.collapseAnimation) {
                shapeSize = new
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        if model.expanded {
            ExpandedPanel(model: model)
                .transition(.opacity)
        } else {
            WingContent(model: model)
        }
    }
}


/// The island's spacing and corner system, in one place so the shape, the window
/// size and every panel agree.
///
/// One padding on every side of every panel, and corners that are concentric with
/// the body's: anything sitting `panelPadding` in from a corner gets
/// `openBottomRadius - panelPadding`, so the gap around it stays even as it turns
/// the corner.
enum IslandMetrics {
    /// How far the body sits in from the window's sides.
    static let closedInset: CGFloat = 6
    static let openInset: CGFloat = 19

    static let closedBottomRadius: CGFloat = 14
    static let openBottomRadius: CGFloat = 24

    /// From the body's edge to its content, on the sides and bottom, and from the
    /// hairline under the switcher to the content at the top.
    static let panelPadding: CGFloat = 12

    /// Large surfaces that sit in a corner: artwork, the shelf's drop outline.
    static let innerRadius: CGFloat = openBottomRadius - panelPadding

    /// Rows and chips. Their backgrounds sit on the padding line; their text sits
    /// this far further in, so every panel's text shares one left and right edge.
    static let textInset: CGFloat = 8
    static let rowRadius: CGFloat = 8

    /// A section header's right padding. Less than `textInset` because headers
    /// usually end in a pill with its own 6 pt of padding, so the pill's label
    /// ends on the rows' text edge.
    static let headerTrailingInset: CGFloat = textInset - 6

    /// The closed island's artwork while music plays.
    static let wingArtwork: CGFloat = 20
}

/// Hangs straight down from the top edge: square top corners against the bezel,
/// rounded bottom corners.
///
/// The sides sit `sideInset` in from the window's edges. That margin used to hold
/// flares curving out into the menu bar; they were dropped for a plainer
/// silhouette, and the margin kept so the body did not change size.
struct NotchShape: Shape {
    var sideInset: CGFloat
    var bottomRadius: CGFloat

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(sideInset, bottomRadius) }
        set {
            sideInset = newValue.first
            bottomRadius = newValue.second
        }
    }

    func path(in rect: CGRect) -> Path {
        let limit = min(rect.width, rect.height) / 2
        let inset = min(sideInset, limit)
        let br = min(bottomRadius, limit)
        let left = rect.minX + inset
        let right = rect.maxX - inset

        var path = Path()
        path.move(to: CGPoint(x: left, y: rect.minY))
        path.addLine(to: CGPoint(x: left, y: rect.maxY - br))
        path.addQuadCurve(
            to: CGPoint(x: left + br, y: rect.maxY),
            control: CGPoint(x: left, y: rect.maxY)
        )
        path.addLine(to: CGPoint(x: right - br, y: rect.maxY))
        path.addQuadCurve(
            to: CGPoint(x: right, y: rect.maxY - br),
            control: CGPoint(x: right, y: rect.maxY)
        )
        path.addLine(to: CGPoint(x: right, y: rect.minY))
        path.closeSubpath()
        return path
    }
}

// MARK: - Closed

// MARK: - Open: panel shell

/// Hosts the active panel: the switcher in the notch band, optional now-playing
/// strip, optional notice, and the panel body.
struct ExpandedPanel: View {
    @ObservedObject var model: IslandModel

    var body: some View {
        VStack(spacing: 0) {
            PanelBar(model: model)

            VStack(spacing: 0) {
                if let notice = model.panelNotice {
                    // Only the Accessibility notice is actionable; the providers
                    // put it ahead of any panel-specific one, so this is the right
                    // test rather than a string comparison.
                    NoticeStrip(
                        text: notice,
                        action: model.pastePermissionNotice != nil
                            ? AccessibilityPaster.openSettings
                            : nil
                    )
                    Color.clear.frame(height: 6)
                }

                content
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            // The same padding on all four sides: below the hairline, above the
            // bottom edge, and in from each side of the body. NotchShape sits in by
            // openInset, so the side padding is measured from there.
            .padding(.top, IslandMetrics.panelPadding)
            .padding(.bottom, IslandMetrics.panelPadding)
            .padding(.horizontal, IslandMetrics.openInset + IslandMetrics.panelPadding)
        }
    }

    @ViewBuilder
    private var content: some View {
        switch model.activePanel {
        case .music: MusicPanel(model: model)
        case .clipboard: ClipboardPanel(model: model, clipboard: model.clipboard)
        case .terminal: TerminalPanel(model: model, terminal: model.terminal)
        case .shelf: ShelfPanel(model: model, shelf: model.shelf)
        case .settings: SettingsPanel(model: model, clipboard: model.clipboard, terminal: model.terminal)
        }
    }
}

/// Panel switcher, sitting in the menu-bar band either side of the cutout.
///
/// The notch is a physical cutout, so the 32 pt band beside it is free screen space
/// that the old bottom nav row wasted. Icons live there instead, and the panel body
/// starts immediately below — which is worth ~22 pt of content height on every
/// panel, and puts the switcher where the eye already is.
struct PanelBar: View {
    @ObservedObject var model: IslandModel

    /// Half the space beside the cutout. Read from the *active* panel, not the
    /// window, so the icons are placed against the size the content is laid out
    /// at even while the window is still the larger of the two during a switch.
    private var sideWidth: CGFloat {
        max((model.activePanel.preferredSize.width - model.notchSize.width) / 2, 0)
    }

    var body: some View {
        HStack(spacing: 0) {
            // Anchored to the cutout rather than centred in the side band: the
            // panels differ in width, and centring would slide all four icons
            // sideways every time you switch to a wider or narrower one.
            group(PanelID.leftPanels)
                .frame(width: sideWidth, alignment: .trailing)
            Color.clear.frame(width: model.notchSize.width)
            group(PanelID.rightPanels)
                .frame(width: sideWidth, alignment: .leading)
        }
        .frame(height: model.notchSize.height)
    }

    private func group(_ panels: [PanelID]) -> some View {
        HStack(spacing: 14) {
            ForEach(panels) { panel in
                Button { model.selectPanel(panel) } label: {
                    // The menu bar's own symbol size. Measured, not guessed: the
                    // system's now-playing item is `play.circle` at 14 × 14 pt with
                    // a 1.5 pt ring, which is what SF Symbols draws at 14 pt medium.
                    Image(systemName: panel.symbol)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(
                            .white.opacity(model.activePanel == panel ? 0.95 : 0.3)
                        )
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(panel.title)
            }
        }
    }
}

/// The panel body under the notch band: pure black, like the band and the cutout,
/// with one hairline separating the panel switcher from the content.
///
/// This used to carry a faint white gradient (5.5% → 1.2%) to read as glass; it was
/// dropped so the whole island is the same true black. Deliberately not
/// `.ultraThinMaterial`: a material samples the desktop and would make the island's
/// edge visible against the bezel.
struct PanelSurface: View {
    var body: some View {
        Color.black
            .overlay(alignment: .top) {
                Rectangle()
                    .fill(.white.opacity(0.09))
                    .frame(height: 0.5)
            }
    }
}


/// What a click on a row does, and the switch for it.
///
/// A bare bolt said nothing: it could be "fast", "async" or "power". This states
/// the outcome instead — the word is the label and the state, so there is nothing
/// to decode. One setting, shown on both history panels, because a switch only
/// reachable from the clipboard is invisible while you are looking at the terminal.
struct PasteToggle: View {
    let enabled: Bool
    let toggle: () -> Void

    var body: some View {
        Button(action: toggle) {
            HStack(spacing: 4) {
                Text("Autopaste")
                    .foregroundStyle(.white.opacity(0.4))
                Text(enabled ? "On" : "Off")
                    .foregroundStyle(.white.opacity(enabled ? 0.9 : 0.45))
            }
            .font(.system(size: 9, weight: .semibold))
            .padding(.horizontal, 6)
            .frame(height: 14)
            .background(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(.white.opacity(enabled ? 0.12 : 0.05))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("On: a click pastes into the front app. Off: a click only copies. "
              + "⌥-click always copies.")
    }
}

/// The 24h / 7d / 30d / All control in a history panel's header.
struct HistoryWindowPicker: View {
    let window: HistoryWindow
    let select: (HistoryWindow) -> Void

    var body: some View {
        PillPicker(
            options: HistoryWindow.allCases,
            selection: window,
            label: { $0.label },
            help: { $0.title },
            select: select
        )
    }
}

/// How big a `PillPicker` is drawn.
enum PillSize {
    /// Inside a 14 pt panel header.
    case small
    /// In a Settings row.
    case regular

    var font: CGFloat { self == .small ? 9 : 11 }
    var height: CGFloat { self == .small ? 14 : 20 }
    var radius: CGFloat { self == .small ? 4 : 6 }
    /// Each pill's own horizontal padding; callers subtract it so the last
    /// pill's label, not its fill, ends on the panels' text edge.
    var padding: CGFloat { self == .small ? 6 : 8 }
}

/// A row of pills with one selected: the history windows in a panel header, and
/// every control in Settings.
///
/// Small buttons rather than a `Picker`, because a segmented control inside a
/// 14 pt header row is taller than the row and drags the layout around. The
/// selected one gets a faint fill; the rest stay at 0.3 so a row still reads as
/// a label first and a control second.
struct PillPicker<Option: Hashable>: View {
    let options: [Option]
    let selection: Option
    var size: PillSize = .small
    let label: (Option) -> String
    var help: ((Option) -> String)?
    let select: (Option) -> Void

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options, id: \.self) { option in
                Button { select(option) } label: {
                    Text(label(option))
                        .font(.system(size: size.font, weight: .semibold))
                        .foregroundStyle(.white.opacity(selection == option ? 0.9 : 0.3))
                        .padding(.horizontal, size.padding)
                        .frame(height: size.height)
                        .background(
                            RoundedRectangle(cornerRadius: size.radius, style: .continuous)
                                .fill(.white.opacity(selection == option ? 0.12 : 0))
                        )
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(help?(option) ?? label(option))
            }
        }
    }
}

/// Shown when a provider reports its panel is degraded rather than broken.
struct NoticeStrip: View {
    let text: String
    /// When set, the strip becomes a button — used by the Accessibility notice,
    /// which is the only one the user can act on.
    var action: (() -> Void)?

    var body: some View {
        if let action {
            Button(action: action) { content(actionable: true) }
                .buttonStyle(.plain)
                .help(text)
        } else {
            content(actionable: false)
        }
    }

    private func content(actionable: Bool) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 9, weight: .bold))
            Text(text)
                .font(.system(size: 10))
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 0)
            if actionable {
                Image(systemName: "chevron.right")
                    .font(.system(size: 8, weight: .bold))
                    .opacity(0.7)
            }
        }
        .foregroundStyle(.orange.opacity(0.85))
        .frame(height: 14)
        // On the panels' text edge, not the padding line: it has no background.
        .padding(.horizontal, IslandMetrics.textInset)
        .contentShape(Rectangle())
    }
}



// MARK: - Open: shelf

/// A staging area in transit. Drop a file here, drag it out somewhere else later.
///
/// Everything is a reference, so removing a row never touches the real file, and
/// the drag operation is copy-only for the same reason.
struct ShelfPanel: View {
    @ObservedObject var model: IslandModel
    @ObservedObject var shelf: ShelfStore

    /// The drop itself is handled by `FileDropView`, which covers the whole island
    /// rather than only this panel — see there for why it is AppKit.
    private var isTargeted: Bool { model.fileDropTargeted }

    var body: some View {
        VStack(spacing: 6) {
            header
            if shelf.items.isEmpty {
                emptyState
            } else {
                list
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .overlay(
            // A drop zone with no feedback reads as broken.
            RoundedRectangle(cornerRadius: IslandMetrics.innerRadius, style: .continuous)
                .strokeBorder(.white.opacity(isTargeted ? 0.35 : 0), lineWidth: 1)
                .animation(.easeOut(duration: 0.12), value: isTargeted)
        )
    }

    private var header: some View {
        PanelSectionHeader(title: "SHELF") {
            Text(shelf.items.isEmpty
                 ? "drop files here"
                 : "\(shelf.items.count) item\(shelf.items.count == 1 ? "" : "s")")
                .font(.system(size: 10))
                .foregroundStyle(.white.opacity(0.22))
                // The header leaves room for a pill's own padding; plain text
                // makes it up so it still ends on the rows' text edge.
                .padding(.trailing, IslandMetrics.textInset - IslandMetrics.headerTrailingInset)
        }
    }

    private var list: some View {
        ScrollView(.vertical, showsIndicators: false) {
            LazyVStack(spacing: 1) {
                ForEach(shelf.items) { item in
                    ShelfRow(item: item, model: model, shelf: shelf)
                }
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 6) {
            Image(systemName: isTargeted ? "tray.and.arrow.down.fill" : "tray")
                .font(.system(size: 18))
                .foregroundStyle(.white.opacity(isTargeted ? 0.7 : 0.25))
            Text(isTargeted ? "Drop to park" : "Nothing on the shelf")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white.opacity(0.55))
            Text("Drag a file at the notch")
                .font(.system(size: 10))
                .foregroundStyle(.white.opacity(0.3))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct ShelfRow: View {
    let item: ShelfItem
    let model: IslandModel
    let shelf: ShelfStore

    @State private var hovering = false

    var body: some View {
        HStack(spacing: 8) {
            icon
                .frame(width: 16, height: 16)

            VStack(alignment: .leading, spacing: 0) {
                Text(item.name)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(item.isMissing ? 0.4 : 0.9))
                    .lineLimit(1)
                    .truncationMode(.middle)

                if let detail {
                    Text(detail)
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(item.isMissing ? 0.45 : 0.3))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if hovering {
                // Drawn, not clickable: the row's input view owns the mouse and
                // hit-tests this rect, so the glyph is only the affordance.
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.45))
                    .frame(width: 14, height: 14)
            }
        }
        .padding(.horizontal, IslandMetrics.textInset)
        .frame(height: 30)
        .background(
            RoundedRectangle(cornerRadius: IslandMetrics.rowRadius, style: .continuous)
                .fill(.white.opacity(hovering ? 0.06 : 0))
        )
        .overlay {
            GeometryReader { geometry in
                ShelfRowInput(
                    item: item,
                    model: model,
                    shelf: shelf,
                    hovering: $hovering,
                    removeRect: CGRect(
                        x: max(0, geometry.size.width - 26),
                        y: 0,
                        width: 26,
                        height: geometry.size.height
                    )
                )
            }
        }
    }

    private var icon: some View {
        Image(nsImage: NSWorkspace.shared.icon(forFile: item.url.path))
            .resizable()
            .aspectRatio(contentMode: .fit)
            .opacity(item.isMissing ? 0.4 : 1)
    }

    /// Folder and size: the two things that tell you whether this is the file you
    /// meant, when the name alone is ambiguous.
    private var detail: String? {
        if item.isMissing { return "Missing — the file was moved or deleted" }
        let folder = item.url.deletingLastPathComponent().lastPathComponent
        let size = (try? item.url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize
        guard let size else { return folder }
        let formatted = ByteCountFormatter.string(
            fromByteCount: Int64(size), countStyle: .file
        )
        return "\(folder) · \(formatted)"
    }
}

// MARK: - Shelf row input

/// Transparent input layer for a shelf row.
///
/// SwiftUI cannot express this row: `.onDrag` and `.onTapGesture` compete for the
/// same gesture, so whether a press becomes a click or a drag is unpredictable.
/// This view owns the mouse instead and decides with a movement threshold. It
/// draws nothing — the row itself stays SwiftUI — so the visuals stay declarative.
struct ShelfRowInput: NSViewRepresentable {
    let item: ShelfItem
    let model: IslandModel
    let shelf: ShelfStore
    @Binding var hovering: Bool
    let removeRect: CGRect

    func makeNSView(context: Context) -> RowInputView {
        let view = RowInputView()
        configure(view)
        return view
    }

    func updateNSView(_ view: RowInputView, context: Context) {
        configure(view)
    }

    private func configure(_ view: RowInputView) {
        view.item = item
        view.model = model
        view.shelf = shelf
        view.removeRect = removeRect
        view.onHoverChange = { hovering = $0 }
    }
}

final class RowInputView: NSView, NSDraggingSource {
    var item: ShelfItem?
    var model: IslandModel?
    var shelf: ShelfStore?
    var removeRect: CGRect = .zero
    var onHoverChange: ((Bool) -> Void)?

    /// The press that might become a drag. Acting on mouse-down would fire the
    /// click before we know which gesture this is — boring.notch's handler does
    /// that, so pressing a row and dragging also reveals it in Finder.
    private var mouseDownEvent: NSEvent?
    private var dragStarted = false
    private var hoverArea: NSTrackingArea?

    /// Below this the press is still a click. Same threshold boring.notch uses.
    private static let dragThreshold: CGFloat = 3

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea { removeTrackingArea(hoverArea) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        hoverArea = area
    }

    override func mouseEntered(with event: NSEvent) { onHoverChange?(true) }
    override func mouseExited(with event: NSEvent) { onHoverChange?(false) }

    override func mouseDown(with event: NSEvent) {
        mouseDownEvent = event
        dragStarted = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard !dragStarted, let down = mouseDownEvent else { return }
        let dx = event.locationInWindow.x - down.locationInWindow.x
        let dy = event.locationInWindow.y - down.locationInWindow.y
        guard hypot(dx, dy) > Self.dragThreshold else { return }

        dragStarted = true
        // The pointer leaves the island during a drag-out, which would otherwise
        // collapse the window and take the drag source with it.
        model?.isInteracting = true
        beginDraggingSession(with: [draggingItem()], event: event, source: self)
    }

    override func mouseUp(with event: NSEvent) {
        let wasDragging = dragStarted
        mouseDownEvent = nil
        dragStarted = false
        guard !wasDragging, let item, let shelf else { return }

        let point = convert(event.locationInWindow, from: nil)
        if !removeRect.isEmpty, removeRect.contains(point) {
            shelf.remove(item)
        } else {
            shelf.reveal(item)
        }
    }

    override func rightMouseDown(with event: NSEvent) {
        guard item != nil, shelf != nil else { return }

        let menu = NSMenu()
        menu.addItem(entry("Open", #selector(openItem)))
        menu.addItem(entry("Reveal in Finder", #selector(revealItem)))
        menu.addItem(entry("Copy Path", #selector(copyPath)))
        menu.addItem(.separator())
        menu.addItem(entry("Remove from Shelf", #selector(removeFromShelf)))

        // Menu tracking moves the pointer off the island, which would otherwise
        // collapse it with the menu still open.
        model?.isInteracting = true
        NSMenu.popUpContextMenu(menu, with: event, for: self)
        model?.isInteracting = false
    }

    /// The row sits above SwiftUI's content, so wheel events have to be passed on
    /// or the list stops scrolling whenever the pointer is over a row.
    override func scrollWheel(with event: NSEvent) {
        nextResponder?.scrollWheel(with: event)
    }

    // MARK: Dragging out

    private func draggingItem() -> NSDraggingItem {
        // NSURL conforms to NSPasteboardWriting and writes `public.file-url` for a
        // file URL, which is what Finder and browser upload fields accept.
        // NSItemProvider does not conform on this SDK, so it cannot be the writer.
        let writer: NSPasteboardWriting = (item?.url as NSURL?) ?? NSPasteboardItem()
        let draggingItem = NSDraggingItem(pasteboardWriter: writer)

        let size = NSSize(width: 32, height: 32)
        let preview = item.map { NSWorkspace.shared.icon(forFile: $0.url.path) }
            ?? NSImage(size: size)
        preview.size = size
        draggingItem.setDraggingFrame(NSRect(origin: .zero, size: size), contents: preview)
        return draggingItem
    }

    func draggingSession(
        _ session: NSDraggingSession,
        sourceOperationMaskFor context: NSDraggingContext
    ) -> NSDragOperation {
        // Copy only, unconditionally: the shelf holds a reference, so dragging out
        // must never move the user's real file onto another volume.
        .copy
    }

    func draggingSession(
        _ session: NSDraggingSession,
        endedAt screenPoint: NSPoint,
        operation: NSDragOperation
    ) {
        model?.isInteracting = false
    }

    private func entry(_ title: String, _ action: Selector) -> NSMenuItem {
        let menuItem = NSMenuItem(title: title, action: action, keyEquivalent: "")
        menuItem.target = self
        return menuItem
    }

    @objc private func openItem() { if let item, let shelf { shelf.open(item) } }
    @objc private func revealItem() { if let item, let shelf { shelf.reveal(item) } }
    @objc private func copyPath() { if let item, let shelf { shelf.copyPath(item) } }
    @objc private func removeFromShelf() { if let item, let shelf { shelf.remove(item) } }
}

// MARK: - Open: clipboard

struct ClipboardPanel: View {
    @ObservedObject var model: IslandModel
    @ObservedObject var clipboard: ClipboardService

    private var entries: [ClipEntry] { clipboard.entries }

    var body: some View {
        VStack(spacing: 6) {
            // Clean layout leaves just the list; the controls are in Settings.
            if !model.cleanLayout {
                if !entries.isEmpty {
                    header
                }
                if !clipboard.frequent.isEmpty {
                    chipRow
                }
            }

            if clipboard.visible.isEmpty {
                emptyState
            } else {
                list
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }

    private var header: some View {
        PanelSectionHeader(title: "FREQUENT") {
            PasteToggle(enabled: model.autoPasteEnabled) { model.autoPasteEnabled.toggle() }
                .padding(.trailing, 8)
            HistoryWindowPicker(window: clipboard.window) { clipboard.window = $0 }
        }
    }

    /// Most-used entries, one click away. Equal widths and one line each: uneven
    /// chip sizes were what made the old strip look messy.
    private var chipRow: some View {
        HStack(spacing: 6) {
            ForEach(clipboard.frequent) { entry in
                FrequentChip(
                    symbol: entry.kind.symbol,
                    text: entry.preview,
                    help: "Paste “\(entry.preview.prefix(80))”"
                ) { paste(entry) }
            }
        }
        .frame(height: 24)
    }

    /// The row the keyboard picker is on, when the island was opened from the
    /// clipboard shortcut.
    private var pickedIndex: Int? {
        model.pickerActive ? model.pickerSelection : nil
    }

    private var list: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                rows
            }
            // Follows the selection, scrolling only as far as it takes to show it.
            .onChange(of: pickedIndex) { _, index in
                guard let index, clipboard.visible.indices.contains(index) else { return }
                proxy.scrollTo(clipboard.visible[index].id)
            }
        }
    }

    private var rows: some View {
        LazyVStack(spacing: 1) {
            ForEach(Array(clipboard.visible.enumerated()), id: \.element.id) { index, entry in
                HistoryRow(
                    symbol: entry.kind.symbol,
                    text: entry.preview,
                    monospaced: entry.isMonospaced,
                    help: "Click to paste · ⌥-click to copy only",
                    selected: index == pickedIndex,
                    action: { paste(entry) }
                ) {
                    // Ages are recomputed on a timeline rather than only when
                    // the row is rebuilt, so "3m" cannot sit there for an hour
                    // on a panel left open. `.everyMinute`, not
                    // `.periodic(from: .now, ...)`: `.now` is re-evaluated every
                    // render, which restarts the schedule and pins a core.
                    TimelineView(.everyMinute) { context in
                        Text(Age.string(entry.copiedAt, now: context.date))
                            .font(.system(size: 10))
                            .foregroundStyle(.white.opacity(0.3))
                            .help("Copied \(entry.copiedAt.formatted(date: .abbreviated, time: .shortened))")
                    }
                }
                    .contextMenu {
                        Button("Copy") { clipboard.write(entry) }
                        Button("Remove", role: .destructive) { clipboard.remove(entry) }
                        Divider()
                        Button("Clear History", role: .destructive) { clipboard.clear() }
                    }
                    .id(entry.id)
            }
        }
    }

    /// Two different nothings: an empty history, or a window that excludes
    /// everything in it. Saying "nothing copied yet" while 300 entries sit behind
    /// a filter would read as broken.
    /// Two different nothings: an empty history, or a window that excludes
    /// everything in it.
    private var emptyState: some View {
        let filtered = !entries.isEmpty
        return PanelEmptyState(
            symbol: filtered ? "line.3.horizontal.decrease" : "doc.on.clipboard",
            title: filtered
                ? "Nothing in the last \(clipboard.window.span)"
                : "Nothing copied yet",
            subtitle: filtered
                ? (model.cleanLayout ? "Choose All in Settings to see older items" : "Pick All to see older items")
                : "Copy something and it shows up here"
        )
    }

    /// ⌥-click copies without pasting, for when the target app is not the one that
    /// had focus.
    private func paste(_ entry: ClipEntry) {
        let copyOnly = NSEvent.modifierFlags.contains(.option)
        model.pasteClipboard(entry, autoPaste: !copyOnly)
    }
}

/// Short relative age: `now`, `4m`, `3h`, `2d`.
enum Age {
    static func string(_ date: Date, now: Date = Date()) -> String {
        let seconds = max(0, now.timeIntervalSince(date))
        switch seconds {
        case ..<60: return "now"
        case ..<3600: return "\(Int(seconds / 60))m"
        case ..<86_400: return "\(Int(seconds / 3600))h"
        default: return "\(Int(seconds / 86_400))d"
        }
    }
}


// MARK: - Open: terminal

struct TerminalPanel: View {
    @ObservedObject var model: IslandModel
    @ObservedObject var terminal: TerminalService

    var body: some View {
        VStack(spacing: 6) {
            if !model.cleanLayout {
                if !terminal.entries.isEmpty {
                    header
                }
                if !terminal.frequent.isEmpty {
                    chipRow
                }
            }

            if terminal.visible.isEmpty {
                emptyState
            } else {
                list
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }

    private var header: some View {
        PanelSectionHeader(title: "FREQUENT") {
            // The filtered count, so the number agrees with the rows below it and
            // clicking a window gives immediate feedback.
            Text("\(terminal.visible.count) command\(terminal.visible.count == 1 ? "" : "s")")
                .font(.system(size: 10))
                .foregroundStyle(.white.opacity(0.22))
                .padding(.trailing, 10)
            PasteToggle(enabled: model.autoPasteEnabled) { model.autoPasteEnabled.toggle() }
                .padding(.trailing, 8)
            HistoryWindowPicker(window: terminal.window) { terminal.window = $0 }
        }
    }

    private var chipRow: some View {
        HStack(spacing: 6) {
            ForEach(terminal.frequent) { entry in
                FrequentChip(
                    symbol: "terminal",
                    text: entry.display,
                    monospaced: true,
                    help: "Paste “\(entry.display.prefix(80))”"
                ) { paste(entry) }
            }
        }
        .frame(height: 24)
    }

    private var list: some View {
        ScrollView(.vertical, showsIndicators: false) {
            LazyVStack(spacing: 1) {
                ForEach(terminal.visible) { entry in
                    HistoryRow(
                        symbol: "terminal",
                        text: entry.display,
                        monospaced: true,
                        help: entry.isSecret
                            ? "Contains a credential — click to paste, ⌥-click to copy only"
                            : "Click to paste · ⌥-click to copy only",
                        action: { paste(entry) }
                    ) {
                        Text("\(entry.uses)×")
                            .font(.system(size: 10))
                            .foregroundStyle(.white.opacity(0.3))
                    }
                        .contextMenu {
                            Button("Copy") { model.clipboard.writeText(entry.command) }
                        }
                }
            }
        }
    }

    private var emptyState: some View {
        let filtered = !terminal.entries.isEmpty
        return PanelEmptyState(
            symbol: filtered ? "line.3.horizontal.decrease" : "terminal",
            title: filtered ? "Nothing in the last \(terminal.window.span)" : "No history yet",
            subtitle: filtered
                ? (model.cleanLayout ? "Choose All in Settings to see older commands" : "Pick All to see older commands")
                : "Run something in a new terminal"
        )
    }

    private func paste(_ entry: TerminalEntry) {
        let copyOnly = NSEvent.modifierFlags.contains(.option)
        model.pasteTerminal(entry, autoPaste: !copyOnly)
    }
}


// MARK: - Open: settings

/// Every setting in one place, so the history panels can drop their controls when
/// `cleanLayout` is on. Each row is a label with a one-line hint under it, and a
/// pill picker; the row count and height are `PanelID.settingsRowCount` and
/// `settingsRowHeight`, which size the panel.
struct SettingsPanel: View {
    @ObservedObject var model: IslandModel
    @ObservedObject var clipboard: ClipboardService
    @ObservedObject var terminal: TerminalService

    var body: some View {
        VStack(spacing: 1) {
            row("Clean layout", hint: "Hides filters and Frequent") {
                onOff(model.cleanLayout) { model.cleanLayout = $0 }
            }
            row(
                "Autopaste",
                hint: needsAccessibility ? "Needs Accessibility — click to open" : "Click pastes; ⌥-click copies",
                warning: needsAccessibility,
                hintAction: needsAccessibility ? AccessibilityPaster.openSettings : nil
            ) {
                onOff(model.autoPasteEnabled) { model.autoPasteEnabled = $0 }
            }
            row(
                "Clipboard shortcut",
                hint: model.clipboardShortcutAvailable ? "Opens the clipboard anywhere" : "In use by another app",
                warning: !model.clipboardShortcutAvailable
            ) {
                PillPicker(
                    options: ClipboardShortcut.allCases.map(Optional.some) + [nil],
                    selection: model.clipboardShortcut,
                    size: .regular,
                    label: { $0?.title ?? "Off" },
                    select: { model.clipboardShortcut = $0 }
                )
            }
            row("Clipboard history", hint: "How far back the list goes") {
                windowPicker(clipboard.window) { clipboard.window = $0 }
            }
            row("Terminal history", hint: "How far back the list goes") {
                windowPicker(terminal.window) { terminal.window = $0 }
            }
            row("Opens on", hint: "Where hover lands") {
                // nil is "Last used".
                PillPicker(
                    options: [nil] + PanelID.contentPanels.map(Optional.some),
                    selection: model.reopensLastPanel ? nil : model.defaultPanel,
                    size: .regular,
                    label: { $0?.title ?? "Last used" },
                    select: { choice in
                        if let choice {
                            model.defaultPanel = choice
                            model.reopensLastPanel = false
                        } else {
                            model.reopensLastPanel = true
                        }
                    }
                )
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }

    private var needsAccessibility: Bool { model.pastePermissionNotice != nil }

    private func onOff(_ value: Bool, select: @escaping (Bool) -> Void) -> some View {
        PillPicker(
            options: [false, true],
            selection: value,
            size: .regular,
            label: { $0 ? "On" : "Off" },
            select: select
        )
    }

    private func windowPicker(_ window: HistoryWindow, select: @escaping (HistoryWindow) -> Void) -> some View {
        PillPicker(
            options: HistoryWindow.allCases,
            selection: window,
            size: .regular,
            label: { $0.label },
            help: { $0.title },
            select: select
        )
    }

    /// Label and hint on the panels' text edge, the control's last label on the
    /// right-hand one.
    private func row<Control: View>(
        _ title: String,
        hint: String,
        warning: Bool = false,
        hintAction: (() -> Void)? = nil,
        @ViewBuilder control: () -> Control
    ) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(0.88))
                Text(hint)
                    .font(.system(size: 10))
                    .foregroundStyle(warning ? .orange.opacity(0.85) : .white.opacity(0.35))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .contentShape(Rectangle())
                    .onTapGesture { hintAction?() }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            control()
                .layoutPriority(1)
        }
        .padding(.leading, IslandMetrics.textInset)
        .padding(.trailing, IslandMetrics.textInset - PillSize.regular.padding)
        .frame(height: PanelID.settingsRowHeight)
    }
}

// MARK: - Open: music

struct MusicPanel: View {
    @ObservedObject var model: IslandModel

    private var track: NowPlaying? { model.nowPlaying }

    /// Square for album art, the frame's aspect for a video — see `MusicLayout`.
    private var tile: CGSize { MusicLayout.tileSize(for: track?.artwork) }

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)

            HStack(alignment: .top, spacing: IslandMetrics.panelPadding) {
                // Sits in the body's bottom-left corner, so its radius is the
                // concentric one rather than its own choice.
                ArtworkView(image: track?.artwork, size: tile, radius: IslandMetrics.innerRadius, shadow: true)

                VStack(alignment: .leading, spacing: 0) {
                    MarqueeText(
                        text: track?.title ?? "Nothing Playing",
                        width: textColumnWidth,
                        font: .system(size: 19, weight: .semibold),
                        nsFont: .systemFont(ofSize: 19, weight: .semibold)
                    )
                    .foregroundStyle(.white)
                    .id(track?.title ?? "none")

                    Text(subtitle)
                        .font(.system(size: 14))
                        .foregroundStyle(.white.opacity(0.5))
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .padding(.top, 3)

                    Spacer(minLength: 0)

                    progress

                    // The controls end on the artwork's bottom edge, which is one
                    // panel padding above the island's. This gap is that same
                    // padding, so they sit midway between the time labels and the
                    // island's edge.
                    Color.clear.frame(height: Self.transportGap)

                    transport
                }
                // Matches the artwork so the block reads as one unit instead of a
                // column stretched to the panel height.
                .frame(height: tile.height, alignment: .top)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            Spacer(minLength: 0)
        }
    }

    /// The panel padding, less the 3 pt of empty line under the digits of the 10 pt
    /// time labels, so the gap measures the same above the controls as below them.
    static let transportGap: CGFloat = IslandMetrics.panelPadding - 3

    /// Panel width minus the body inset and the panel padding on each side, the
    /// artwork, and the gap beside it.
    private var textColumnWidth: CGFloat {
        MusicLayout.panelWidth
            - 2 * (IslandMetrics.openInset + IslandMetrics.panelPadding)
            - tile.width
            - IslandMetrics.panelPadding
    }

    private var subtitle: String {
        guard let track else { return "Nothing playing" }
        if !track.artist.isEmpty { return track.artist }
        if !track.album.isEmpty { return track.album }
        return "Unknown Artist"
    }

    private var transport: some View {
        // Centred across the text column rather than pushed to its right edge:
        // right-aligned left the block floating in the corner of a panel this tall.
        HStack(spacing: 20) {
            Spacer(minLength: 0)
            TransportButton(symbol: "backward.fill", size: 17) { model.player.previous() }
            TransportButton(
                symbol: track?.isPlaying == true ? "pause.fill" : "play.fill",
                size: 15,
                prominent: true
            ) { model.player.toggle() }
            TransportButton(symbol: "forward.fill", size: 17) { model.player.next() }
            Spacer(minLength: 0)
        }
        .frame(height: TransportButton.height)
    }

    @ViewBuilder
    private var progress: some View {
        if let track, track.duration > 0 {
            ScrubBar(track: track) { seconds in
                model.player.seek(to: seconds)
            }
        } else {
            Color.clear.frame(height: 26)
        }
    }
}


// MARK: - Pieces

struct TransportButton: View {
    let symbol: String
    let size: CGFloat
    var prominent = false
    let action: () -> Void

    /// The play/pause circle's diameter, and the row's height.
    static let height: CGFloat = 36

    var body: some View {
        Button(action: action) {
            if prominent {
                // Filled white circle with a dark glyph: the one high-contrast
                // element in the panel, so play/pause reads at a glance.
                ZStack {
                    Circle().fill(.white.opacity(0.92))
                    Image(systemName: symbol)
                        .font(.system(size: size, weight: .bold))
                        .foregroundStyle(.black.opacity(0.85))
                }
                .frame(width: Self.height, height: Self.height)
            } else {
                Image(systemName: symbol)
                    .font(.system(size: size, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.75))
                    .frame(width: 30, height: Self.height)
                    .contentShape(Rectangle())
            }
        }
        .buttonStyle(.plain)
    }
}

struct ArtworkView: View {
    let image: NSImage?
    /// Square for album art, the source's aspect for a video frame.
    let size: CGSize
    let radius: CGFloat
    var shadow = false

    init(image: NSImage?, size: CGFloat, radius: CGFloat, shadow: Bool = false) {
        self.image = image
        self.size = CGSize(width: size, height: size)
        self.radius = radius
        self.shadow = shadow
    }

    init(image: NSImage?, size: CGSize, radius: CGFloat, shadow: Bool = false) {
        self.image = image
        self.size = size
        self.radius = radius
        self.shadow = shadow
    }

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                LinearGradient(
                    colors: [
                        Color(red: 0.32, green: 0.38, blue: 0.95),
                        Color(red: 0.78, green: 0.32, blue: 0.86)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                .overlay(
                    Image(systemName: "music.note")
                        .font(.system(size: min(size.width, size.height) * 0.36, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.85))
                )
            }
        }
        .frame(width: size.width, height: size.height)
        .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .strokeBorder(.white.opacity(0.1), lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(shadow ? 0.45 : 0), radius: shadow ? 12 : 0, y: shadow ? 6 : 0)
    }
}

struct ScrubBar: View {
    let track: NowPlaying
    let onSeek: (Double) -> Void

    @State private var dragFraction: Double?

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let liveFraction = track.duration > 0
                ? track.position(at: context.date) / track.duration
                : 0
            let fraction = min(max(dragFraction ?? liveFraction, 0), 1)
            let shownSeconds = fraction * track.duration

            VStack(spacing: 3) {
                GeometryReader { geometry in
                    let width = max(geometry.size.width, 1)
                    ZStack(alignment: .leading) {
                        Capsule()
                            .fill(.white.opacity(0.16))
                            .frame(height: 3)
                        Capsule()
                            .fill(.white.opacity(0.85))
                            .frame(width: width * fraction, height: 3)
                        Circle()
                            .fill(.white)
                            .frame(
                                width: dragFraction == nil ? 0 : 9,
                                height: dragFraction == nil ? 0 : 9
                            )
                            .offset(x: width * fraction - 4.5)
                    }
                    .frame(height: 14)
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { value in
                                dragFraction = min(max(value.location.x / width, 0), 1)
                            }
                            .onEnded { value in
                                let target = min(max(value.location.x / width, 0), 1)
                                dragFraction = nil
                                onSeek(target * track.duration)
                            }
                    )
                }
                .frame(height: 14)

                HStack {
                    Text(TimeLabel.string(shownSeconds))
                    Spacer()
                    Text(TimeLabel.string(track.duration))
                }
                .font(.system(size: 10, weight: .medium).monospacedDigit())
                .foregroundStyle(.white.opacity(0.45))
            }
        }
    }
}

enum TimeLabel {
    static func string(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let total = Int(seconds.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}


/// Scrolls only when the text is wider than the space it has, and drives the
/// offset from a clock rather than a repeatForever animation so re-renders
/// (the progress bar ticks every second) cannot restart it.
struct MarqueeText: View {
    let text: String
    let width: CGFloat
    var font: Font = .system(size: 15, weight: .semibold)
    var nsFont: NSFont = .systemFont(ofSize: 15, weight: .semibold)
    var speed: CGFloat = 26
    var gap: CGFloat = 32

    @State private var start = Date()

    private var textWidth: CGFloat {
        ceil((text as NSString).size(withAttributes: [.font: nsFont]).width)
    }

    var body: some View {
        Group {
            if textWidth <= width {
                Text(text)
                    .font(font)
                    .lineLimit(1)
            } else {
                TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { context in
                    let span = max(textWidth + gap, 1)
                    let period = Double(span / speed)
                    let elapsed = context.date.timeIntervalSince(start)
                    let x = CGFloat(elapsed.truncatingRemainder(dividingBy: period)) * speed

                    HStack(spacing: gap) {
                        Text(text).font(font).fixedSize()
                        Text(text).font(font).fixedSize()
                    }
                    .offset(x: -x)
                }
                .frame(width: width, alignment: .leading)
                .clipped()
                .mask(
                    LinearGradient(
                        stops: [
                            .init(color: .black, location: 0),
                            .init(color: .black, location: 0.92),
                            .init(color: .clear, location: 1)
                        ],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                )
            }
        }
        .frame(width: width, alignment: .leading)
    }
}

/// What a click just did, as a short message under the island.
///
/// It has to appear *after* the collapse — the panel is gone by the time the
/// keystroke lands — so it cannot be a row highlight or anything inside the panel.
/// The chin was the first home for it, but the chin is only ~32 pt either side of
/// the camera cutout: room for a glyph, not for "Copied to clipboard".
struct PasteToastView: View {
    let toast: IslandModel.PasteToast

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: toast.pasted ? "checkmark.circle.fill" : "doc.on.clipboard")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white.opacity(0.9))
            Text(toast.text)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.white.opacity(0.9))
                .lineLimit(1)
        }
        .padding(.horizontal, 12)
        .frame(height: IslandModel.toastHeight)
        .background(
            RoundedRectangle(cornerRadius: IslandMetrics.rowRadius, style: .continuous)
                .fill(.black.opacity(0.92))
                .overlay(
                    RoundedRectangle(cornerRadius: IslandMetrics.rowRadius, style: .continuous)
                        .strokeBorder(.white.opacity(0.12), lineWidth: 0.5)
                )
        )
        .shadow(color: .black.opacity(0.45), radius: 10, y: 4)
    }
}

/// What the closed island draws in the chin while music plays: artwork on one side,
/// a waveform on the other.
///
/// macOS also draws a now-playing live activity further along the menu bar. Both are
/// visible on purpose — this one is attached to the notch, which is where the island
/// lives, and it is the only one that can sit inside the cutout's own band. It is
/// affordable because `CoreAnimationEqualizer` runs on the window server.
///
/// Symmetric by construction: each wing is a square as tall as the band (see
/// `IslandModel.islandSize`), and the artwork and the indicator each sit centred
/// in a same-sized slot inside one. So both get the same padding above, below,
/// towards the outer edge and towards the cutout, and the artwork's corners are
/// concentric with the island's.
struct WingContent: View {
    @ObservedObject var model: IslandModel

    private var slot: CGFloat { IslandMetrics.wingArtwork }

    /// The gap around a slot on every side.
    private var padding: CGFloat { max((model.notchSize.height - slot) / 2, 0) }

    private var edge: CGFloat { IslandMetrics.closedInset + padding }

    var body: some View {
        HStack(spacing: 0) {
            if let track = model.nowPlaying {
                ArtworkView(
                    image: track.artwork,
                    size: slot,
                    radius: max(IslandMetrics.closedBottomRadius - padding, 4)
                )
                .padding(.leading, edge)
            }

            Spacer(minLength: 0)

            Group {
                if model.nowPlaying?.isPlaying == true {
                    CoreAnimationEqualizer()
                        .frame(width: 11.5, height: 12)
                } else if model.nowPlaying != nil {
                    Image(systemName: "pause.fill")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.white.opacity(0.5))
                }
            }
            .frame(width: slot, height: slot)
            .padding(.trailing, edge)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
