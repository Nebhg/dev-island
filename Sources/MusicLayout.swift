import AppKit
import CoreGraphics

/// The music panel has two layouts, and the **artwork's own shape** picks between
/// them.
///
/// Not the source: there is no reliable way to tell a video from a song. Spotify
/// publishes `mediaType: …TypeAudio`, but a browser playing YouTube omits
/// `mediaType` entirely, and a YouTube *music* video and a YouTube video are the
/// same thing to the system. The image is the one honest signal — album art is
/// square, a video frame is 16:9 — so a song posted as a video correctly shows as
/// a video, because that is what its artwork is.
///
/// Square artwork keeps the panel at 440 and the tile square. Wide artwork widens
/// the panel to 520 (the width the lists already use) and stretches the tile to
/// the frame's aspect, so nothing is cropped.
enum MusicLayout {
    static let panelHeight: CGFloat = 190

    /// Album art.
    static let squarePanelWidth: CGFloat = 440
    /// A video frame: wide enough for a 16:9 tile plus a usable text column.
    static let widePanelWidth: CGFloat = 520

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

    static func panelWidth(for image: NSImage?) -> CGFloat {
        isWide(image) ? widePanelWidth : squarePanelWidth
    }
}
