import SwiftUI

/// The chrome shared by the clipboard, terminal and shelf panels.
///
/// Four pieces were copy-pasted across those panels and had started to drift: the
/// section header's trailing inset was 6 pt on one panel and 0 on another, and the
/// empty states had been edited in two places with different text. Extracting them
/// means a spacing change is made once.
///
/// The measurements are the ones already in use — 11 pt tracked caps, 24 pt chips,
/// 26 pt rows — so this is a rename, not a redesign.

/// The `FREQUENT` / `SHELF` label row, with whatever controls belong on the right.
///
/// Deliberately **not** wrapped in a fixed width: the trailing content decides, and
/// callers pass a `Spacer` inside it when they want the controls pushed right.
struct PanelSectionHeader<Trailing: View>: View {
    let title: String
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: 0) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .tracking(0.6)
                .foregroundStyle(.white.opacity(0.3))
            Spacer(minLength: 0)
            trailing
        }
        .padding(.leading, IslandMetrics.textInset)
        .padding(.trailing, IslandMetrics.headerTrailingInset)
        .frame(height: 14)
    }
}

/// One of the three "nothing here" panels: a glyph, a line, and a smaller line.
///
/// The text is passed in because the clipboard and terminal both distinguish "empty"
/// from "filtered out by the time window", and saying "nothing copied yet" while 300
/// entries sit behind a filter reads as broken.
struct PanelEmptyState: View {
    let symbol: String
    let title: String
    let subtitle: String

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: symbol)
                .font(.system(size: 18))
                .foregroundStyle(.white.opacity(0.25))
            Text(title)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white.opacity(0.55))
            Text(subtitle)
                .font(.system(size: 10))
                .foregroundStyle(.white.opacity(0.3))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// A pill in the FREQUENT strip: kind glyph, one line of text, equal share of the row.
struct FrequentChip: View {
    let symbol: String
    let text: String
    var monospaced = false
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: symbol)
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.45))

                Text(text)
                    .font(monospaced
                          ? .system(size: 11, weight: .medium, design: .monospaced)
                          : .system(size: 11, weight: .medium))
                    .foregroundStyle(.white.opacity(0.82))
                    .lineLimit(1)
                    .truncationMode(.tail)

                Spacer(minLength: 0)
            }
            .padding(.horizontal, IslandMetrics.textInset)
            .frame(maxWidth: .infinity, minHeight: 22, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: IslandMetrics.rowRadius, style: .continuous)
                    .fill(.white.opacity(0.055))
                    .overlay(
                        RoundedRectangle(cornerRadius: IslandMetrics.rowRadius, style: .continuous)
                            .strokeBorder(.white.opacity(0.07), lineWidth: 0.5)
                    )
            )
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

/// One history row: kind glyph, one middle-truncated line, and whatever the panel
/// puts on the right.
///
/// The trailing slot exists because that is the only place the two panels differ —
/// the clipboard puts a live-updating age there, the terminal puts a use count — and
/// everything else, including the hover fill and the 26 pt height, is identical.
struct HistoryRow<Trailing: View>: View {
    let symbol: String
    let text: String
    var monospaced = false
    let help: String
    /// The keyboard mode's current row. Drawn a step brighter than hover, so the
    /// two can be told apart when the pointer happens to rest on another row.
    var selected = false
    let action: () -> Void
    @ViewBuilder var trailing: Trailing

    @State private var hovering = false

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.white.opacity(selected || hovering ? 0.55 : 0.3))
                .frame(width: 13)

            Text(text)
                .font(monospaced
                      ? .system(size: 12, design: .monospaced)
                      : .system(size: 12))
                .foregroundStyle(.white.opacity(0.88))
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)

            trailing
                .layoutPriority(1)
        }
        .padding(.horizontal, IslandMetrics.textInset)
        .frame(height: 26)
        .background(
            RoundedRectangle(cornerRadius: IslandMetrics.rowRadius, style: .continuous)
                .fill(.white.opacity(selected ? 0.11 : hovering ? 0.06 : 0))
        )
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture(perform: action)
        .help(help)
    }
}
