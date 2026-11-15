import AppKit
import Foundation

/// Turns the adapter's JSON lines into `NowPlaying` values.
///
/// Separated from `MediaStream` so it can be exercised without spawning a
/// process — the patch handling below is easy to get wrong and impossible to see
/// from a screenshot.
struct MediaStreamDecoder {
    enum Update {
        case nothingPlaying
        case track(NowPlaying)
    }

    /// Decoded artwork, keyed by item. A 75 KB JPEG re-decoded on every position
    /// tick would be absurd, and the adapter re-sends it on any full payload.
    private var artworkCache: [String: NSImage] = [:]

    /// The track currently on screen. Most payloads are patches against it.
    private var lastTrack: NowPlaying?

    private let iso = ISO8601DateFormatter()

    mutating func decode(_ line: Data) -> Update? {
        guard let raw = try? JSONSerialization.jsonObject(with: line),
              let object = raw as? [String: Any],
              let payload = object["payload"] as? [String: Any]
        else { return nil }

        // An empty payload means nothing is playing. The adapter emits one of
        // these on startup too, so it must not be treated as an error.
        guard !payload.isEmpty else {
            lastTrack = nil
            return .nothingPlaying
        }

        if let title = payload["title"] as? String, !title.isEmpty {
            let track = makeTrack(title: title, from: payload)
            lastTrack = track
            return .track(track)
        }

        // **A payload without a title is a patch, not a new track.** The adapter
        // sends the metadata once and then diffs: artwork, play/pause and position
        // all arrive carrying only the changed keys. Requiring a title here dropped
        // every one of them, which is why a browser showed its video title but kept
        // the placeholder, and why a paused video could keep showing as playing.
        guard var track = lastTrack else { return nil }
        apply(payload, to: &track)
        lastTrack = track
        return .track(track)
    }

    private mutating func makeTrack(title: String, from payload: [String: Any]) -> NowPlaying {
        let artist = payload["artist"] as? String ?? ""
        let identifier = payload["contentItemIdentifier"] as? String ?? "\(title)|\(artist)"

        var track = NowPlaying(
            title: title,
            artist: artist,
            album: payload["album"] as? String ?? "",
            duration: number("duration", in: payload),
            elapsed: number("elapsedTime", in: payload),
            rate: rate(from: payload) ?? number("playbackRate", in: payload),
            timestamp: stamp(from: payload) ?? Date(),
            artwork: artworkCache[identifier]
        )
        apply(payload, to: &track, identifier: identifier)
        return track
    }

    /// Merges whichever keys this payload carries into `track`.
    private mutating func apply(_ payload: [String: Any], to track: inout NowPlaying, identifier: String? = nil) {
        let key = identifier ?? "\(track.title)|\(track.artist)"

        if let base64 = payload["artworkData"] as? String,
           let bytes = Data(base64Encoded: base64),
           let image = NSImage(data: bytes) {
            track.artwork = image
            artworkCache[key] = image
            if artworkCache.count > 8 { artworkCache.removeAll() }
        } else if track.artwork == nil, let cached = artworkCache[key] {
            track.artwork = cached
        }

        // `playing` wins: the adapter reports `playbackRate: 1` on a *paused*
        // track, so trusting the rate alone would show a paused video as playing.
        if let rate = rate(from: payload) { track.rate = rate }
        if let duration = payload["duration"] as? NSNumber { track.duration = duration.doubleValue }
        if let elapsed = payload["elapsedTime"] as? NSNumber { track.elapsed = elapsed.doubleValue }
        if let stamp = stamp(from: payload) { track.timestamp = stamp }
    }

    private func number(_ key: String, in payload: [String: Any]) -> Double {
        (payload[key] as? NSNumber)?.doubleValue ?? 0
    }

    private func rate(from payload: [String: Any]) -> Double? {
        (payload["playing"] as? Bool).map { $0 ? 1.0 : 0.0 }
    }

    private func stamp(from payload: [String: Any]) -> Date? {
        (payload["timestamp"] as? String).flatMap { iso.date(from: $0) }
    }
}
