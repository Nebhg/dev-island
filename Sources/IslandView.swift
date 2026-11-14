import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct IslandRootView: View {
    @ObservedObject var model: IslandModel

    /// Called with every interpolated size while a resize animates, so the window
    /// can track the shape exactly. Without this the window is pre-sized to the
    /// target, leaving a transparent gap below the still-growing island.
    var onSizeChange: ((CGSize) -> Void)?

    /// Shape animation. Both are critically damped: the window follows the shape
    /// frame by frame, so any spring overshoot shows up as the whole window
    /// bouncing. Bounce is fine for a shape inside a fixed frame, not for a frame
    /// that is itself resizing.
    static let expandAnimation = Animation.spring(response: 0.36, dampingFraction: 1)
    static let collapseAnimation = Animation.spring(response: 0.24, dampingFraction: 1)

    private var sizeAnimation: Animation {
        model.expanded ? Self.expandAnimation : Self.collapseAnimation
    }

    private var size: CGSize { model.islandSize }

    // BoringNotch's corner language: 6/14 when closed, 19/24 when open.
    private var topRadius: CGFloat { model.expanded ? 19 : 6 }
    private var bottomRadius: CGFloat { model.expanded ? 24 : 14 }

    private var shape: NotchShape {
        NotchShape(topRadius: topRadius, bottomRadius: bottomRadius)
    }

    var body: some View {
        VStack(spacing: 0) {
            ZStack(alignment: .top) {
                shape.fill(.black)

                if model.expanded {
                    ExpandedPanel(model: model)
                        .transition(.opacity)
                } else {
                    WingContent(model: model)
                }
            }
            .frame(width: size.width, height: size.height, alignment: .top)
            .modifier(SizeProbe(size: size, onSizeChange: onSizeChange))
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
            // No tap action: the closed island expands on hover before a click
            // can land, so a click-to-Spotlight gesture could never fire. ⌘Space
            // is the system precedent anyway.
            .animation(sizeAnimation, value: size)
            .animation(.easeInOut(duration: 0.18), value: model.expanded)

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

/// Reports every interpolated size while a resize animates, so the window can
/// follow the shape frame by frame. Animatable rather than a `GeometryReader`
/// because layout callbacks only ever see the final value, not the animation.
struct SizeProbe: ViewModifier, Animatable {
    var size: CGSize
    var onSizeChange: ((CGSize) -> Void)?

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(size.width, size.height) }
        set {
            size = CGSize(width: newValue.first, height: newValue.second)
            onSizeChange?(size)
        }
    }

    func body(content: Content) -> some View { content }
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
                Equalizer()
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

// MARK: - Open: panel shell

/// Hosts the active panel: optional now-playing strip, optional notice, the
/// panel body, and the navigation row.
struct ExpandedPanel: View {
    @ObservedObject var model: IslandModel

    var body: some View {
        VStack(spacing: 0) {
            if model.activePanel.showsPlayerStrip, model.nowPlaying != nil {
                PlayerStrip(model: model)
                Color.clear.frame(height: 6)
            }

            if let notice = model.panelNotice {
                NoticeStrip(text: notice)
                Color.clear.frame(height: 6)
            }

            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            Color.clear.frame(height: 4)
            PanelNav(model: model)
        }
        .padding(.top, model.notchSize.height + 4)
        .padding(.bottom, 6)
        // NotchShape tapers inward by topRadius on each side, so the body is
        // narrower than the panel. Content has to clear that or it gets clipped.
        .padding(.horizontal, 24)
        // Switching panel changes the window size; let the content follow.
        .animation(.easeInOut(duration: 0.16), value: model.activePanel)
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

/// Compact now-playing row shown above every non-music panel, so playback stays
/// reachable without giving up the width a list needs. Only drawn when there is
/// actually a track, so an idle island keeps the full panel height for content.
struct PlayerStrip: View {
    @ObservedObject var model: IslandModel

    private var track: NowPlaying? { model.nowPlaying }

    var body: some View {
        GeometryReader { geometry in
            HStack(spacing: 8) {
                ArtworkView(image: track?.artwork, size: 20, radius: 5)

                MarqueeText(
                    text: track?.title ?? "",
                    width: max(geometry.size.width - 74, 60),
                    font: .system(size: 12, weight: .medium),
                    nsFont: .systemFont(ofSize: 12, weight: .medium),
                    speed: 20,
                    gap: 24
                )
                .foregroundStyle(.white.opacity(0.9))
                .id(track?.title ?? "none")

                Spacer(minLength: 0)

                Button { model.player.toggle() } label: {
                    Image(systemName: track?.isPlaying == true ? "pause.fill" : "play.fill")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.white.opacity(0.85))
                        .frame(width: 18, height: 18)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 8)
            .frame(width: geometry.size.width, height: 26, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(.white.opacity(0.055))
                    .overlay(
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .strokeBorder(.white.opacity(0.09), lineWidth: 0.5)
                    )
            )
        }
        .frame(height: 26)
    }
}

/// Shown when a provider reports its panel is degraded rather than broken.
struct NoticeStrip: View {
    let text: String

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 9, weight: .bold))
            Text(text)
                .font(.system(size: 10))
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 0)
        }
        .foregroundStyle(.orange.opacity(0.85))
        .frame(height: 14)
    }
}

struct PanelNav: View {
    @ObservedObject var model: IslandModel

    var body: some View {
        HStack(spacing: 16) {
            ForEach(PanelID.allCases) { panel in
                Button {
                    model.selectPanel(panel)
                } label: {
                    Image(systemName: panel.symbol)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(
                            .white.opacity(model.activePanel == panel ? 0.95 : 0.28)
                        )
                        .frame(width: 24, height: 18)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(panel.title)
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: 18)
    }
}

/// Stand-in for the panels arriving in phases 3–4.
struct PlaceholderPanel: View {
    let panel: PanelID

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: panel.symbol)
                .font(.system(size: 18, weight: .regular))
                .foregroundStyle(.white.opacity(0.25))
            Text(panel.title)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white.opacity(0.55))
            Text("Not wired up yet")
                .font(.system(size: 10))
                .foregroundStyle(.white.opacity(0.3))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
        .onDrop(of: [.fileURL, .url, .text], isTargeted: $isTargeted) { providers in
            handleDrop(providers)
        }
    }

    private var header: some View {
        HStack(spacing: 0) {
            Text("SHELF")
                .font(.system(size: 8, weight: .semibold))
                .tracking(0.7)
                .foregroundStyle(.white.opacity(0.28))
            Spacer(minLength: 0)
            Text(shelf.items.isEmpty
                 ? "drop files here"
                 : "\(shelf.items.count) item\(shelf.items.count == 1 ? "" : "s")")
                .font(.system(size: 8))
                .foregroundStyle(.white.opacity(0.22))
        }
        .frame(height: 9)
    }

    private var list: some View {
        ScrollView(.vertical, showsIndicators: false) {
            LazyVStack(spacing: 1) {
                ForEach(shelf.items) { item in
                    ShelfRow(item: item, shelf: shelf)
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
        guard !providers.isEmpty else { return false }

        if Self.dropProbe {
            let types = providers.flatMap(\.registeredTypeIdentifiers).prefix(8)
            NSLog("[probe] drop providers=\(providers.count) types=\(types)")
        }

        // Set before any async work: the controller checks this on mouse-up to tell
        // a completed drop from a cancelled drag, and a late flag would make it
        // restore the previous panel over the file that was just dropped.
        model.shelfDidReceiveDrop = true

        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                _ = provider.loadObject(ofClass: URL.self) { url, error in
                    if Self.dropProbe {
                        NSLog("[probe] loaded file url=\(url?.path ?? "nil") error=\(error?.localizedDescription ?? "none")")
                    }
                    guard let url else { return }
                    DispatchQueue.main.async {
                        if url.isFileURL {
                            shelf.addFiles([url])
                        } else {
                            shelf.addLink(url)
                        }
                    }
                }
            } else if provider.canLoadObject(ofClass: NSString.self) {
                _ = provider.loadObject(ofClass: NSString.self) { object, _ in
                    guard let text = object as? String else { return }
                    DispatchQueue.main.async { shelf.addText(text) }
                }
            } else if Self.dropProbe {
                NSLog("[probe] provider had no usable type: \(provider.registeredTypeIdentifiers)")
            }
        }
        return true
    }
}

struct ShelfRow: View {
    let item: ShelfItem
    let shelf: ShelfStore

    @State private var hovering = false

    var body: some View {
        HStack(spacing: 8) {
            icon
                .frame(width: 16, height: 16)

            VStack(alignment: .leading, spacing: 0) {
                Text(item.name)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white.opacity(item.isMissing ? 0.4 : 0.9))
                    .lineLimit(1)
                    .truncationMode(.middle)

                if let detail {
                    Text(detail)
                        .font(.system(size: 9))
                        .foregroundStyle(.white.opacity(item.isMissing ? 0.45 : 0.3))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if hovering {
                Button { shelf.remove(item) } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.45))
                        .frame(width: 14, height: 14)
                }
                .buttonStyle(.plain)
                .help("Remove from shelf (the file itself is untouched)")
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 30)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(.white.opacity(hovering ? 0.06 : 0))
        )
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture { shelf.reveal(item) }
        .contextMenu {
            Button("Open") { shelf.open(item) }
            if item.kind == .file {
                Button("Reveal in Finder") { shelf.reveal(item) }
                Button("Copy Path") { shelf.copyPath(item) }
            }
            Divider()
            Button("Remove from Shelf") { shelf.remove(item) }
        }
        .help(item.isMissing
              ? "The original file is gone. Remove it, or ⌥-click to keep the row."
              : "Click to reveal in Finder · right-click for more")
    }

    @ViewBuilder
    private var icon: some View {
        switch item.kind {
        case .file:
            if let url = item.url {
                Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .opacity(item.isMissing ? 0.4 : 1)
            } else {
                Image(systemName: "doc")
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.5))
            }
        case .text:
            Image(systemName: "text.alignleft")
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.5))
        case .link:
            Image(systemName: "link")
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.5))
        }
    }

    /// Folder and size: the two things that tell you whether this is the file you
    /// meant, when the name alone is ambiguous.
    private var detail: String? {
        switch item.kind {
        case .file:
            guard let url = item.url else { return nil }
            if item.isMissing { return "Missing — the file was moved or deleted" }
            let folder = url.deletingLastPathComponent().lastPathComponent
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize
            guard let size else { return folder }
            let formatted = ByteCountFormatter.string(
                fromByteCount: Int64(size), countStyle: .file
            )
            return "\(folder) · \(formatted)"
        case .text:
            return "Text"
        case .link:
            return item.payload
        }
    }
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
                chipRow
            }

            if entries.isEmpty {
                emptyState
            } else {
                list
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }

    /// A label makes the strip read as a deliberate section rather than three
    /// stray strings floating above the list.
    private var header: some View {
        HStack(spacing: 0) {
            Text("FREQUENT")
                .font(.system(size: 8, weight: .semibold))
                .tracking(0.7)
                .foregroundStyle(.white.opacity(0.28))
            Spacer(minLength: 0)
        }
        .frame(height: 9)
    }

    /// Most-used entries, one click away. Equal widths and one line each: uneven
    /// chip sizes were what made the old strip look messy.
    private var chipRow: some View {
        HStack(spacing: 6) {
            ForEach(clipboard.frequent()) { entry in
                Button { paste(entry) } label: {
                    HStack(spacing: 5) {
                        Image(systemName: entry.kind.symbol)
                            .font(.system(size: 8, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.45))

                        Text(entry.preview)
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(.white.opacity(0.82))
                            .lineLimit(1)
                            .truncationMode(.tail)

                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 7)
                    .frame(maxWidth: .infinity, minHeight: 22, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill(.white.opacity(0.055))
                            .overlay(
                                RoundedRectangle(cornerRadius: 7, style: .continuous)
                                    .strokeBorder(.white.opacity(0.07), lineWidth: 0.5)
                            )
                    )
                }
                .buttonStyle(.plain)
                .help("Paste “\(entry.preview.prefix(80))”")
            }
        }
        .frame(height: 22)
    }

    private var list: some View {
        ScrollView(.vertical, showsIndicators: false) {
            LazyVStack(spacing: 1) {
                ForEach(entries) { entry in
                    ClipRow(entry: entry) { paste(entry) }
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

    private var emptyState: some View {
        VStack(spacing: 6) {
            Image(systemName: "doc.on.clipboard")
                .font(.system(size: 18))
                .foregroundStyle(.white.opacity(0.25))
            Text("Nothing copied yet")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white.opacity(0.55))
            Text("Copy something and it shows up here")
                .font(.system(size: 10))
                .foregroundStyle(.white.opacity(0.3))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// ⌥-click copies without pasting, for when the target app is not the one that
    /// had focus.
    private func paste(_ entry: ClipEntry) {
        let copyOnly = NSEvent.modifierFlags.contains(.option)
        model.pasteClipboard(entry, autoPaste: !copyOnly)
    }
}

struct ClipRow: View {
    let entry: ClipEntry
    let action: () -> Void

    @State private var hovering = false

    private var isMonospaced: Bool {
        entry.kind == .command || entry.kind == .code || entry.kind == .path
    }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: entry.kind.symbol)
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(.white.opacity(hovering ? 0.55 : 0.3))
                .frame(width: 12)

            Text(entry.preview)
                .font(isMonospaced
                      ? .system(size: 11, design: .monospaced)
                      : .system(size: 11))
                .foregroundStyle(.white.opacity(0.88))
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)

            Text(Self.age(entry.lastUsed))
                .font(.system(size: 9))
                .foregroundStyle(.white.opacity(0.3))
                .layoutPriority(1)
        }
        .padding(.horizontal, 8)
        .frame(height: 26)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(.white.opacity(hovering ? 0.06 : 0))
        )
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture(perform: action)
        .help("Click to paste · ⌥-click to copy only")
    }

    /// Short relative age: `now`, `4m`, `3h`, `2d`.
    static func age(_ date: Date, now: Date = Date()) -> String {
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

    /// Most recently used first — this is a history view, so recency leads and
    /// the use count is the secondary signal.
    private var ordered: [TerminalEntry] {
        terminal.entries.sorted { $0.lastPosition > $1.lastPosition }
    }

    var body: some View {
        VStack(spacing: 6) {
            if !terminal.entries.isEmpty {
                header
                chipRow
            }

            if terminal.entries.isEmpty {
                emptyState
            } else {
                list
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }

    private var header: some View {
        HStack(spacing: 0) {
            Text("FREQUENT")
                .font(.system(size: 8, weight: .semibold))
                .tracking(0.7)
                .foregroundStyle(.white.opacity(0.28))
            Spacer(minLength: 0)
            Text("\(terminal.entries.count) commands")
                .font(.system(size: 8))
                .foregroundStyle(.white.opacity(0.22))
        }
        .frame(height: 9)
    }

    private var chipRow: some View {
        HStack(spacing: 6) {
            ForEach(terminal.frequent()) { entry in
                Button { paste(entry) } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "terminal")
                            .font(.system(size: 8, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.45))

                        Text(entry.display)
                            .font(.system(size: 10, weight: .medium, design: .monospaced))
                            .foregroundStyle(.white.opacity(0.82))
                            .lineLimit(1)
                            .truncationMode(.tail)

                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 7)
                    .frame(maxWidth: .infinity, minHeight: 22, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill(.white.opacity(0.055))
                            .overlay(
                                RoundedRectangle(cornerRadius: 7, style: .continuous)
                                    .strokeBorder(.white.opacity(0.07), lineWidth: 0.5)
                            )
                    )
                }
                .buttonStyle(.plain)
                .help("Paste “\(entry.display.prefix(80))”")
            }
        }
        .frame(height: 22)
    }

    private var list: some View {
        ScrollView(.vertical, showsIndicators: false) {
            LazyVStack(spacing: 1) {
                ForEach(ordered) { entry in
                    TerminalRow(entry: entry) { paste(entry) }
                        .contextMenu {
                            Button("Copy") { model.clipboard.writeText(entry.command) }
                        }
                }
            }
            .padding(.bottom, 2)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 6) {
            Image(systemName: "terminal")
                .font(.system(size: 18))
                .foregroundStyle(.white.opacity(0.25))
            Text("No history yet")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white.opacity(0.55))
            Text("Run something in a new terminal")
                .font(.system(size: 10))
                .foregroundStyle(.white.opacity(0.3))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func paste(_ entry: TerminalEntry) {
        let copyOnly = NSEvent.modifierFlags.contains(.option)
        model.pasteTerminal(entry, autoPaste: !copyOnly)
    }
}

struct TerminalRow: View {
    let entry: TerminalEntry
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "terminal")
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(.white.opacity(hovering ? 0.55 : 0.3))
                .frame(width: 12)

            Text(entry.display)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.white.opacity(0.88))
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)

            Text("\(entry.uses)×")
                .font(.system(size: 9))
                .foregroundStyle(.white.opacity(0.3))
                .layoutPriority(1)
        }
        .padding(.horizontal, 8)
        .frame(height: 26)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(.white.opacity(hovering ? 0.06 : 0))
        )
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture(perform: action)
        .help(entry.isSecret
              ? "Contains a credential — click to paste, ⌥-click to copy only"
              : "Click to paste · ⌥-click to copy only")
    }
}

// MARK: - Open: music

struct MusicPanel: View {
    @ObservedObject var model: IslandModel

    private var track: NowPlaying? { model.nowPlaying }

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 14) {
                ArtworkView(image: track?.artwork, size: 60, radius: 12)

                VStack(alignment: .leading, spacing: 3) {
                    MarqueeText(
                        text: track?.title ?? "Nothing Playing",
                        width: textColumnWidth
                    )
                    .foregroundStyle(.white)
                    .id(track?.title ?? "none")

                    Text(subtitle)
                        .font(.system(size: 12))
                        .foregroundStyle(.white.opacity(0.55))
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                .layoutPriority(1)

                Spacer(minLength: 8)

                HStack(spacing: 10) {
                    TransportButton(symbol: "backward.fill", size: 12) { model.player.previous() }
                    TransportButton(
                        symbol: track?.isPlaying == true ? "pause.fill" : "play.fill",
                        size: 14,
                        prominent: true
                    ) { model.player.toggle() }
                    TransportButton(symbol: "forward.fill", size: 12) { model.player.next() }
                }
            }
            .frame(height: 60)

            progress.frame(height: 30)
        }
        .padding(.horizontal, 8)
        .frame(maxHeight: .infinity, alignment: .top)
    }

    /// Panel width minus both side insets (shell 24 + panel 8 each side), the
    /// artwork, the three HStack gaps, the spacer and the transport row.
    private var textColumnWidth: CGFloat {
        PanelID.music.preferredSize.width - 64 - 60 - 42 - 8 - 106
    }

    private var subtitle: String {
        guard let track else { return "Nothing playing" }
        if !track.artist.isEmpty { return track.artist }
        if !track.album.isEmpty { return track.album }
        return "Unknown Artist"
    }

    @ViewBuilder
    private var progress: some View {
        if let track, track.duration > 0 {
            ScrubBar(track: track) { seconds in
                model.player.seek(to: seconds)
            }
        } else {
            Color.clear
        }
    }
}

// MARK: - Pieces

struct Equalizer: View {
    @State private var animating = false

    var body: some View {
        HStack(alignment: .center, spacing: 2) {
            ForEach(0..<3, id: \.self) { index in
                Capsule()
                    .fill(.white.opacity(0.85))
                    .frame(width: 2.5, height: animating ? CGFloat(9 + index * 2) : 4)
                    .animation(
                        .easeInOut(duration: 0.45)
                            .repeatForever(autoreverses: true)
                            .delay(Double(index) * 0.12),
                        value: animating
                    )
            }
        }
        .frame(height: 12)
        .onAppear { animating = true }
    }
}

struct TransportButton: View {
    let symbol: String
    let size: CGFloat
    var prominent = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle().fill(.white.opacity(prominent ? 0.14 : 0.07))
                Image(systemName: symbol)
                    .font(.system(size: size, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.9))
            }
            .frame(width: prominent ? 34 : 26, height: prominent ? 34 : 26)
        }
        .buttonStyle(.plain)
    }
}

struct ArtworkView: View {
    let image: NSImage?
    let size: CGFloat
    let radius: CGFloat

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
                        .font(.system(size: size * 0.36, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.85))
                )
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .strokeBorder(.white.opacity(0.1), lineWidth: 0.5)
        )
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
