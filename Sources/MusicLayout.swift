import AppKit
import CoreGraphics

/// The music panel is **one size** — `520 × 190`, the same width the list panels
/// use — and only the artwork tile changes shape.
///
/// An earlier version widened the panel for video artwork and kept it narrow for
/// album art. That looked clever and behaved badly: the island changed width every
/// time the track changed, and because the browser publishes a 16:9 thumbnail for
/// *every* YouTube video, a music video and a lecture pulled the same lever. One
/// panel size, always. The tile still follows the image's aspect so neither a
/// square cover nor a 16:9 frame is cropped, and that is the only thing that
/// varies.
enum MusicLayout {
    static let panelWidth: CGFloat = 520
    static let panelHeight: CGFloat = 190

    static let artworkHeight: CGFloat = 132
    /// A 16:9 tile at this height is ~235 pt; the cap only stops something absurd
    /// from eating the whole panel.
    static let maxArtworkWidth: CGFloat = 236

    /// Above this, treat the image as a video frame rather than album art.
    static let wideAspectRatio: CGFloat = 1.2

    static func isWide(_ image: NSImage?) -> Bool {
        guard let size = image?.size, size.height > 0 else { return false }
        return size.width / size.height > wideAspectRatio
    }

    static func tileSize(for image: NSImage?) -> CGSize {
        guard isWide(image), let size = image?.size, size.height > 0 else {
            return CGSize(width: artworkHeight, height: artworkHeight)
        }
        let width = min(artworkHeight * (size.width / size.height), maxArtworkWidth)
        return CGSize(width: width, height: artworkHeight)
    }

}
