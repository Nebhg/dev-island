import AppKit
import Foundation

struct SpotifySnapshot {
    var isPlaying: Bool
    var title: String
    var artist: String
    var album: String
    var position: Double
    var duration: Double
    var artworkURL: String
}

/// Talks to Spotify directly. MediaRemote only reports whichever app owns the
/// system "now playing" session, and its commands are unreliable when another
/// player is around — Spotify itself is the source of truth.
final class SpotifyBridge {
    static let shared = SpotifyBridge()

    private let queue = DispatchQueue(label: "dynamicisland.spotify", qos: .userInitiated)
    private var artworkCache: [String: NSImage] = [:]
    private var pendingArtwork: Set<String> = []

    var isRunning: Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: "com.spotify.client").isEmpty
    }

    func fetch(_ completion: @escaping (SpotifySnapshot?) -> Void) {
        guard isRunning else {
            completion(nil)
            return
        }
        queue.async {
            let source = """
            tell application "Spotify"
                try
                    set playerState to player state is playing
                    set trackName to name of current track
                    set trackArtist to artist of current track
                    set trackAlbum to album of current track
                    set trackPosition to player position
                    set trackDuration to duration of current track
                    set artURL to artwork url of current track
                    return {playerState, trackName, trackArtist, trackAlbum, trackPosition, trackDuration, artURL}
                on error
                    return {false, "", "", "", 0, 0, ""}
                end try
            end tell
            """
            var error: NSDictionary?
            guard let descriptor = NSAppleScript(source: source)?.executeAndReturnError(&error),
                  descriptor.numberOfItems >= 7
            else {
                DispatchQueue.main.async { completion(nil) }
                return
            }
            let title = descriptor.atIndex(2)?.stringValue ?? ""
            let snapshot = SpotifySnapshot(
                isPlaying: descriptor.atIndex(1)?.booleanValue ?? false,
                title: title,
                artist: descriptor.atIndex(3)?.stringValue ?? "",
                album: descriptor.atIndex(4)?.stringValue ?? "",
                position: descriptor.atIndex(5)?.doubleValue ?? 0,
                duration: (descriptor.atIndex(6)?.doubleValue ?? 0) / 1000,
                artworkURL: descriptor.atIndex(7)?.stringValue ?? ""
            )
            DispatchQueue.main.async { completion(title.isEmpty ? nil : snapshot) }
        }
    }

    func command(_ verb: String) {
        queue.async {
            _ = NSAppleScript(source: "tell application \"Spotify\" to \(verb)")?
                .executeAndReturnError(nil)
        }
    }

    func seek(to seconds: Double) {
        command("set player position to \(max(0, seconds))")
    }

    func artwork(for urlString: String, completion: @escaping (NSImage?) -> Void) {
        guard !urlString.isEmpty, let url = URL(string: urlString) else {
            completion(nil)
            return
        }
        if let cached = artworkCache[urlString] {
            completion(cached)
            return
        }
        guard !pendingArtwork.contains(urlString) else {
            completion(nil)
            return
        }
        pendingArtwork.insert(urlString)
        URLSession.shared.dataTask(with: url) { [weak self] data, _, _ in
            let image = data.flatMap { NSImage(data: $0) }
            DispatchQueue.main.async {
                guard let self else { return }
                self.pendingArtwork.remove(urlString)
                if let image { self.artworkCache[urlString] = image }
                completion(image)
            }
        }.resume()
    }
}
