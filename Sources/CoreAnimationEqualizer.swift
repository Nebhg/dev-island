import AppKit
import QuartzCore
import SwiftUI

/// Three bars pulsing beside the notch, animated by Core Animation.
///
/// **Why not SwiftUI.** An implicit `repeatForever` animation is driven by the app:
/// it repaints the island at display rate, and measured 9% of a core for a 12 pt
/// glyph — in the state the app sits in most, music playing and the island closed.
/// A `TimelineView` at 8 fps halved that but was still app-driven.
///
/// Core Animation is different: `add(anim, forKey:)` commits the animation to the
/// window server, which interpolates it from then on. The app is not woken per
/// frame, so a looping bar animation costs it nothing — the same mechanism macOS
/// uses for its own now-playing indicator. Measured after the change: 0.0%.
struct CoreAnimationEqualizer: NSViewRepresentable {
    var barCount = 3
    var height: CGFloat = 12

    func makeNSView(context: Context) -> EqualizerView {
        EqualizerView(barCount: barCount, height: height)
    }

    func updateNSView(_ view: EqualizerView, context: Context) {}
}

final class EqualizerView: NSView {
    private let barCount: Int
    private let height: CGFloat
    private var bars: [CALayer] = []

    private static let barWidth: CGFloat = 2.5
    private static let gap: CGFloat = 2

    init(barCount: Int, height: CGFloat) {
        self.barCount = barCount
        self.height = height
        super.init(frame: .zero)
        wantsLayer = true
        layer?.masksToBounds = false

        for _ in 0..<barCount {
            let bar = CALayer()
            bar.backgroundColor = NSColor.white.withAlphaComponent(0.85).cgColor
            bar.cornerRadius = Self.barWidth / 2
            layer?.addSublayer(bar)
            bars.append(bar)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    override var intrinsicContentSize: NSSize {
        let width = CGFloat(barCount) * Self.barWidth + CGFloat(barCount - 1) * Self.gap
        return NSSize(width: width, height: height)
    }

    override func layout() {
        super.layout()
        // Layers are positioned in points from the bottom-left, and the scale
        // animation is about each bar's centre so they grow both ways.
        let step = Self.barWidth + Self.gap
        for (index, bar) in bars.enumerated() {
            bar.bounds = CGRect(x: 0, y: 0, width: Self.barWidth, height: height)
            bar.position = CGPoint(
                x: CGFloat(index) * step + Self.barWidth / 2,
                y: bounds.midY
            )
            animate(bar, index: index)
        }
    }

    private func animate(_ bar: CALayer, index: Int) {
        guard bar.animation(forKey: "pulse") == nil else { return }
        let pulse = CABasicAnimation(keyPath: "transform.scale.y")
        pulse.fromValue = 0.35
        pulse.toValue = 1.0
        pulse.duration = 0.42 + Double(index) * 0.13
        pulse.autoreverses = true
        pulse.repeatCount = .infinity
        pulse.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        // Offsetting each bar stops them pulsing in lockstep.
        pulse.timeOffset = Double(index) * 0.17
        bar.add(pulse, forKey: "pulse")
    }

    /// The animations are torn down with the view; nothing to clean up, but leaving
    /// this explicit documents that they are infinite.
    deinit {
        bars.forEach { $0.removeAllAnimations() }
    }
}
