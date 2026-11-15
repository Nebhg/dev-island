import AppKit
import Foundation

extension Notification.Name {
    static let nowPlayingDidChange = Notification.Name("kMRMediaRemoteNowPlayingInfoDidChangeNotification")
    static let playingStateDidChange = Notification.Name("kMRMediaRemoteNowPlayingApplicationIsPlayingDidChangeNotification")
}

struct NowPlaying: Equatable {
    var title: String
    var artist: String
    var album: String
    var duration: Double
    var elapsed: Double
    var rate: Double
    var timestamp: Date
    var artwork: NSImage?

    var isPlaying: Bool { rate > 0.5 }

    /// Elapsed time projected forward to `date`, clamped to the track length.
    func position(at date: Date = Date()) -> Double {
        guard duration > 0 else { return 0 }
        let projected = elapsed + date.timeIntervalSince(timestamp) * rate
        return min(max(projected, 0), duration)
    }

    static func == (lhs: NowPlaying, rhs: NowPlaying) -> Bool {
        lhs.title == rhs.title
            && lhs.artist == rhs.artist
            && lhs.album == rhs.album
            && lhs.duration == rhs.duration
            && lhs.rate == rhs.rate
            && lhs.artwork === rhs.artwork
            && abs(lhs.timestamp.timeIntervalSince(rhs.timestamp)) < 0.5
    }

    /// Carries the current artwork forward when a refresh of the **same** track
    /// arrives without it.
    ///
    /// Artwork is not delivered atomically with the rest of the metadata.
    /// `kMRMediaRemoteNowPlayingInfoArtworkData` is populated by the playing app
    /// some time after the title and duration, and the community wrapper around
    /// this framework is explicit that it "often takes a bit of time to load and
    /// may not appear in the output in all cases — poll regularly to ensure you
    /// get the artwork data eventually".
    ///
    /// Replacing the published track on every poll therefore threw the image away
    /// each time a poll came back without it: a thumbnail that blinks out and
    /// back, and for a browser slow to publish it, missing most of the time. That
    /// is the whole reason YouTube thumbnails would not have shown reliably — there
    /// is no artwork *URL* key to fetch from, so the only lever is not to drop what
    /// we are given.
    ///
    /// Same track means title **and** artist. Matching on title alone would let a
    /// different video inherit the previous thumbnail, which is worse than a gap.
    func carryingArtwork(from current: NowPlaying?) -> NowPlaying {
        guard artwork == nil,
              let current,
              current.title == title,
              current.artist == artist
        else { return self }

        var merged = self
        merged.artwork = current.artwork
        return merged
    }
}

/// Thin bridge over Apple's private MediaRemote framework. Works for every
/// player on the system (Music, Spotify, Safari, VLC...) because it reads the
/// same "now playing" channel Control Center uses.
final class MediaRemote {
    static let shared = MediaRemote()

    private typealias GetInfoFn = @convention(c) (DispatchQueue, @escaping ([String: Any]) -> Void) -> Void
    private typealias GetBoolFn = @convention(c) (DispatchQueue, @escaping (Bool) -> Void) -> Void
    private typealias SendFn = @convention(c) (Int32, UnsafeMutableRawPointer?) -> Void
    private typealias RegisterFn = @convention(c) (DispatchQueue) -> Void
    private typealias SetElapsedFn = @convention(c) (Double) -> Void

    private var getInfo: GetInfoFn?
    private var getIsPlaying: GetBoolFn?
    private var sendCommand: SendFn?
    private var register: RegisterFn?
    private var setElapsedFn: SetElapsedFn?

    private enum Command: Int32 {
        case play = 0
        case pause = 1
        case toggle = 2
        case next = 4
        case previous = 5
    }

    private init() {
        let path = "/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote"
        guard let handle = dlopen(path, RTLD_NOW) else {
            NSLog("DevIsland: MediaRemote unavailable")
            return
        }
        if let symbol = dlsym(handle, "MRMediaRemoteGetNowPlayingInfo") {
            getInfo = unsafeBitCast(symbol, to: GetInfoFn.self)
        }
        if let symbol = dlsym(handle, "MRMediaRemoteGetNowPlayingApplicationIsPlaying") {
            getIsPlaying = unsafeBitCast(symbol, to: GetBoolFn.self)
        }
        if let symbol = dlsym(handle, "MRMediaRemoteSendCommand") {
            sendCommand = unsafeBitCast(symbol, to: SendFn.self)
        }
        if let symbol = dlsym(handle, "MRMediaRemoteRegisterForNowPlayingNotifications") {
            register = unsafeBitCast(symbol, to: RegisterFn.self)
        }
        if let symbol = dlsym(handle, "MRMediaRemoteSetElapsedTime") {
            setElapsedFn = unsafeBitCast(symbol, to: SetElapsedFn.self)
        }
    }

    func startObserving() {
        register?(.main)
    }

    func fetch(_ completion: @escaping (NowPlaying?) -> Void) {
        guard let getInfo else {
            completion(nil)
            return
        }
        getInfo(.global(qos: .userInitiated)) { info in
            let track = MediaRemote.parse(info)
            DispatchQueue.main.async { completion(track) }
        }
    }

    func togglePlayPause() { sendCommand?(Command.toggle.rawValue, nil) }
    func next() { sendCommand?(Command.next.rawValue, nil) }
    func previous() { sendCommand?(Command.previous.rawValue, nil) }
    func setElapsedTime(_ seconds: Double) { setElapsedFn?(seconds) }

    private static func parse(_ info: [String: Any]) -> NowPlaying? {
        guard let title = info["kMRMediaRemoteNowPlayingInfoTitle"] as? String, !title.isEmpty else {
            return nil
        }
        func number(_ key: String) -> Double {
            (info[key] as? NSNumber)?.doubleValue ?? 0
        }
        var artwork: NSImage?
        if let data = info["kMRMediaRemoteNowPlayingInfoArtworkData"] as? Data, !data.isEmpty {
            artwork = NSImage(data: data)
        }
        return NowPlaying(
            title: title,
            artist: info["kMRMediaRemoteNowPlayingInfoArtist"] as? String ?? "",
            album: info["kMRMediaRemoteNowPlayingInfoAlbum"] as? String ?? "",
            duration: number("kMRMediaRemoteNowPlayingInfoDuration"),
            elapsed: number("kMRMediaRemoteNowPlayingInfoElapsedTime"),
            rate: number("kMRMediaRemoteNowPlayingInfoPlaybackRate"),
            timestamp: info["kMRMediaRemoteNowPlayingInfoTimestamp"] as? Date ?? Date(),
            artwork: artwork
        )
    }
}
