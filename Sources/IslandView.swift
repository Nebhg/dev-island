import AppKit
import SwiftUI

struct IslandRootView: View {
    @ObservedObject var model: IslandModel

    static let expandedSize = CGSize(width: 440, height: 162)

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
                    ExpandedContent(model: model)
                        .transition(.opacity)
                } else {
                    WingContent(model: model)
                }
            }
            .frame(width: size.width, height: size.height, alignment: .top)
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
            .onTapGesture { model.openSpotlight() }
            .shadow(
                color: .black.opacity(model.expanded ? 0.5 : 0),
                radius: 8,
                x: 0,
                y: 4
            )
            .animation(.spring(response: 0.4, dampingFraction: 0.8), value: size)
            .animation(.easeInOut(duration: 0.18), value: model.expanded)

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
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

// MARK: - Open

struct ExpandedContent: View {
    @ObservedObject var model: IslandModel

    private var track: NowPlaying? { model.nowPlaying }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                ArtworkView(image: track?.artwork, size: 60, radius: 12)

                VStack(alignment: .leading, spacing: 3) {
                    Text(track?.title ?? "Nothing Playing")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .truncationMode(.tail)

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

            Color.clear.frame(height: 10)

            progress.frame(height: 29)
        }
        .padding(.horizontal, 26)
        .padding(.top, model.notchSize.height + 12)
        .padding(.bottom, 18)
    }

    private var subtitle: String {
        guard let track else { return "Click to open Spotlight" }
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
