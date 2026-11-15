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

    // BoringNotch's corner language: 6/14 when closed, 19/24 when open.
    private var topRadius: CGFloat { model.expanded ? 19 : 6 }
    private var bottomRadius: CGFloat { model.expanded ? 24 : 14 }

    private var shape: NotchShape {
        NotchShape(topRadius: topRadius, bottomRadius: bottomRadius)
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
                        // The glass belongs to the shell rather than the panel, so it
                        // fills the shape as it animates instead of sitting inside a
                        // larger black card mid-switch. The notch band above it stays
                        // pure black, so the cutout remains invisible.
                        GlassSurface()
                            .padding(.top, model.notchSize.height)
                    }
                }
                .clipShape(shape)
                // Straightens the top edge against the bezel, exactly like BoringNotch.
                .overlay(alignment: .top) {
                    Rectangle()
                        .fill(.black)
                        .frame(height: 1)
                        .padding(.horizontal, topRadius)
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


/// Rounded on all four corners; the top pair is much tighter so the shape still
/// reads as attached to the bezel.
struct NotchShape: Shape {
    var topRadius: CGFloat
    var bottomRadius: CGFloat

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(topRadius, bottomRadius) }
        set {
            topRadius = newValue.first
            bottomRadius = newValue.second
        }
    }

    func path(in rect: CGRect) -> Path {
        let limit = min(rect.width, rect.height) / 2
        let tr = min(topRadius, limit)
        let br = min(bottomRadius, limit)

        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addQuadCurve(
            to: CGPoint(x: rect.minX + tr, y: rect.minY + tr),
            control: CGPoint(x: rect.minX + tr, y: rect.minY)
        )
        path.addLine(to: CGPoint(x: rect.minX + tr, y: rect.maxY - br))
        path.addQuadCurve(
            to: CGPoint(x: rect.minX + tr + br, y: rect.maxY),
            control: CGPoint(x: rect.minX + tr, y: rect.maxY)
        )
        path.addLine(to: CGPoint(x: rect.maxX - tr - br, y: rect.maxY))
        path.addQuadCurve(
            to: CGPoint(x: rect.maxX - tr, y: rect.maxY - br),
            control: CGPoint(x: rect.maxX - tr, y: rect.maxY)
        )
        path.addLine(to: CGPoint(x: rect.maxX - tr, y: rect.minY + tr))
        path.addQuadCurve(
            to: CGPoint(x: rect.maxX, y: rect.minY),
            control: CGPoint(x: rect.maxX - tr, y: rect.minY)
        )
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
            // A gap under the hairline that separates the notch band from the
            // glass. Without it the first label sat hard against the separator.
            .padding(.top, 10)
            .padding(.bottom, 8)
            // NotchShape tapers inward by topRadius on each side, so the body is
            // narrower than the panel. Content has to clear that or it gets clipped.
            .padding(.horizontal, 24)
        }
    }

    @ViewBuilder
    private var content: some View {
        switch model.activePanel {
        case .music: MusicPanel(model: model)
        case .clipboard: ClipboardPanel(model: model, clipboard: model.clipboard)
        case .terminal: TerminalPanel(model: model, terminal: model.terminal)
        case .shelf: ShelfPanel(model: model, shelf: model.shelf)
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
                    Image(systemName: panel.symbol)
                        .font(.system(size: 12, weight: .semibold))
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

/// Black, but with a glassy lower half.
///
/// The notch band above stays pure black so the cutout is invisible against it;
/// below, a faint gradient and a hairline read as a pane rather than a flat
/// rectangle. Deliberately not `.ultraThinMaterial`: a material samples the desktop
/// and would make the island's edge visible against the bezel.
struct GlassSurface: View {
    var body: some View {
        ZStack {
            Color.black
            LinearGradient(
                colors: [.white.opacity(0.055), .white.opacity(0.012)],
                startPoint: .top,
                endPoint: .bottom
            )
        }
        .overlay(alignment: .top) {
            Rectangle()
                .fill(.white.opacity(0.09))
                .frame(height: 0.5)
        }
    }
}

/// Whether the notch acknowledges a click at all.
///
/// A separate switch from autopaste because they answer different questions: "does
/// a click paste" and "does it say so". Someone may want the paste without the
/// animation, or vice versa.
struct PasteConfirmationToggle: View {
    let enabled: Bool
    let toggle: () -> Void

    var body: some View {
        Button(action: toggle) {
            Image(systemName: enabled ? "checkmark.circle.fill" : "checkmark.circle")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.white.opacity(enabled ? 0.75 : 0.3))
                .frame(width: 14, height: 14)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(enabled ? "The notch confirms each click — click to stop" : "The notch is silent after a click — click to confirm")
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
///
/// Four small buttons rather than a `Picker`, because a segmented control inside
/// a 14 pt header row is taller than the row and drags the layout around. The
/// selected one gets a faint fill; the rest stay at 0.3 so the row still reads as
/// a label first and a control second.
struct HistoryWindowPicker: View {
    let window: HistoryWindow
    let select: (HistoryWindow) -> Void

    var body: some View {
        HStack(spacing: 2) {
            ForEach(HistoryWindow.allCases) { option in
                Button { select(option) } label: {
                    Text(option.label)
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.white.opacity(window == option ? 0.9 : 0.3))
                        .padding(.horizontal, 6)
                        .frame(height: 14)
                        .background(
                            RoundedRectangle(cornerRadius: 4, style: .continuous)
                                .fill(.white.opacity(window == option ? 0.12 : 0))
                        )
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(option.title)
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

    @State private var isTargeted = false

    /// Shares `ISLAND_DRAG_PROBE` with the controller, so one flag traces a drag
    /// from the monitor through to the drop landing.
    private static let dropProbe =
        ProcessInfo.processInfo.environment["ISLAND_DRAG_PROBE"] == "1"

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
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(.white.opacity(isTargeted ? 0.35 : 0), lineWidth: 1)
                .animation(.easeOut(duration: 0.12), value: isTargeted)
        )
        .onDrop(of: [.fileURL], isTargeted: $isTargeted) { providers in
            handleDrop(providers)
        }
    }

    private var header: some View {
        PanelSectionHeader(title: "SHELF") {
            Text(shelf.items.isEmpty
                 ? "drop files here"
                 : "\(shelf.items.count) item\(shelf.items.count == 1 ? "" : "s")")
                .font(.system(size: 10))
                .foregroundStyle(.white.opacity(0.22))
        }
    }

    private var list: some View {
        ScrollView(.vertical, showsIndicators: false) {
            LazyVStack(spacing: 1) {
                ForEach(shelf.items) { item in
                    ShelfRow(item: item, model: model, shelf: shelf)
                }
            }
            .padding(.bottom, 2)
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

    /// Returns true synchronously so AppKit accepts the drop; the items load
    /// asynchronously because `NSItemProvider` may hand back a file promise.
    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        // Files only. Text and links are the clipboard's job: copying them is one
        // keystroke, the clipboard already captures them automatically, and a shelf
        // row would add a second place to look for the same string. A file is the
        // one thing the clipboard cannot hold as a usable reference.
        let fileProviders = providers.filter {
            $0.registeredTypeIdentifiers.contains(UTType.fileURL.identifier)
        }
        guard !fileProviders.isEmpty else {
            if Self.dropProbe {
                NSLog("[probe] drop rejected, no file provider: \(providers.flatMap(\.registeredTypeIdentifiers).prefix(6))")
            }
            return false
        }

        if Self.dropProbe {
            NSLog("[probe] drop providers=\(fileProviders.count)")
        }

        // Set before any async work: the controller checks this on mouse-up to tell
        // a completed drop from a cancelled drag, and a late flag would make it
        // restore the previous panel over the file that was just dropped.
        model.shelfDidReceiveDrop = true

        for provider in fileProviders {
            _ = provider.loadObject(ofClass: URL.self) { url, error in
                if Self.dropProbe {
                    NSLog("[probe] loaded url=\(url?.path ?? "nil") error=\(error?.localizedDescription ?? "none")")
                }
                guard let url, url.isFileURL else { return }
                DispatchQueue.main.async { shelf.addFiles([url]) }
            }
        }
        return true
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
        .padding(.horizontal, 8)
        .frame(height: 30)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
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
            if !entries.isEmpty {
                header
            }
            if !clipboard.frequent.isEmpty {
                chipRow
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
            PasteConfirmationToggle(enabled: model.pasteConfirmationEnabled) {
                model.pasteConfirmationEnabled.toggle()
            }
            .padding(.leading, 8)
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

    private var list: some View {
        ScrollView(.vertical, showsIndicators: false) {
            LazyVStack(spacing: 1) {
                ForEach(clipboard.visible) { entry in
                    HistoryRow(
                        symbol: entry.kind.symbol,
                        text: entry.preview,
                        monospaced: entry.isMonospaced,
                        help: "Click to paste · ⌥-click to copy only",
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
                }
            }
            .padding(.bottom, 2)
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
                ? "Pick All to see older items"
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
            if !terminal.entries.isEmpty {
                header
            }
            if !terminal.frequent.isEmpty {
                chipRow
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
            .padding(.bottom, 2)
        }
    }

    private var emptyState: some View {
        let filtered = !terminal.entries.isEmpty
        return PanelEmptyState(
            symbol: filtered ? "line.3.horizontal.decrease" : "terminal",
            title: filtered ? "Nothing in the last \(terminal.window.span)" : "No history yet",
            subtitle: filtered ? "Pick All to see older commands" : "Run something in a new terminal"
        )
    }

    private func paste(_ entry: TerminalEntry) {
        let copyOnly = NSEvent.modifierFlags.contains(.option)
        model.pasteTerminal(entry, autoPaste: !copyOnly)
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

            HStack(alignment: .top, spacing: 16) {
                ArtworkView(image: track?.artwork, size: tile, radius: 20, shadow: true)

                VStack(alignment: .leading, spacing: 3) {
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

                    Spacer(minLength: 0)

                    progress

                    Spacer(minLength: 0)

                    transport
                }
                // Matches the artwork so the block reads as one unit instead of a
                // column stretched to the panel height.
                .frame(height: tile.height, alignment: .top)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
    }

    /// Panel width minus the shell inset (24 each side), the panel inset (8 each
    /// side), the artwork and the gap beside it.
    private var textColumnWidth: CGFloat {
        MusicLayout.panelWidth - 48 - 16 - tile.width - 16
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
        HStack(spacing: 16) {
            Spacer(minLength: 0)
            TransportButton(symbol: "backward.fill", size: 13) { model.player.previous() }
            TransportButton(
                symbol: track?.isPlaying == true ? "pause.fill" : "play.fill",
                size: 12,
                prominent: true
            ) { model.player.toggle() }
            TransportButton(symbol: "forward.fill", size: 13) { model.player.next() }
            Spacer(minLength: 0)
        }
        .frame(height: 28)
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
                .frame(width: 28, height: 28)
            } else {
                Image(systemName: symbol)
                    .font(.system(size: size, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.75))
                    .frame(width: 22, height: 28)
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
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(.black.opacity(0.92))
                .overlay(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
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
struct WingContent: View {
    @ObservedObject var model: IslandModel

    var body: some View {
        HStack(spacing: 0) {
            if let track = model.nowPlaying {
                ArtworkView(image: track.artwork, size: 20, radius: 4)
                    .padding(.leading, 6)
            }

            Spacer(minLength: 0)

            if model.nowPlaying?.isPlaying == true {
                CoreAnimationEqualizer()
                    .frame(width: 11.5, height: 12)
                    .padding(.trailing, 8)
            } else if model.nowPlaying != nil {
                Image(systemName: "pause.fill")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.white.opacity(0.5))
                    .padding(.trailing, 10)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
