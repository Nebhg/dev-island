import AppKit
import Foundation

/// Reads the system now-playing session out of a `perl` subprocess.
///
/// **Why a subprocess.** Since macOS 15.4, `MRMediaRemoteGetNowPlayingInfo`
/// answers with an empty dictionary unless the caller is entitled, which a normal
/// app is not. Measured on this machine: eight consecutive direct calls returned
/// `keys=0`, with Spotify both paused and playing — so every track Dev Island had
/// ever shown came from the Spotify AppleScript bridge, and MediaRemote was never
/// actually exercised.
///
/// `/usr/bin/perl` *is* entitled, so the vendored `mediaremote-adapter` framework
/// calls the same function from inside it and streams the result as JSON lines.
/// Commands (play/pause/next/seek) are unaffected: those work unentitled and go
/// through the direct dlsym path in `MediaRemote`.
///
/// **Cost, measured:** 0.0% CPU and ~21 MB resident while idle, because the
/// adapter emits only on change rather than polling. It runs for the app's
/// lifetime — the second deliberate exception to "nothing runs unless the panel is
/// visible", because the closed notch shows what is playing and a stale title there
/// is worse than 21 MB. The clipboard capture is the first exception.
final class MediaStream {
    /// Called on the main queue with the decoded session. `nil` when nothing is
    /// playing.
    var onUpdate: ((NowPlaying?) -> Void)?

    private var process: Process?
    private var pipe: Pipe?
    private var pending = Data()
    private var artworkCache: [String: NSImage] = [:]
    private var isStopping = false

    private lazy var decoder = ISO8601DateFormatter()

    func start() {
        guard process == nil else { return }
        guard let script = Bundle.main.url(forResource: "mediaremote-adapter", withExtension: "pl"),
              let frameworksPath = Bundle.main.privateFrameworksPath
        else {
            NSLog("DevIsland: mediaremote-adapter missing from the bundle")
            return
        }

        sweepOrphans(script: script)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        process.arguments = [script.path, frameworksPath + "/MediaRemoteAdapter.framework", "stream"]
        process.standardError = FileHandle.nullDevice

        let pipe = Pipe()
        process.standardOutput = pipe

        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            self?.consume(data)
        }

        process.terminationHandler = { [weak self] _ in
            DispatchQueue.main.async {
                guard let self, !self.isStopping else { return }
                // The helper died — it should not, but a silent freeze is worse
                // than a restart loop that shows up in the log.
                NSLog("DevIsland: media stream exited, restarting")
                self.process = nil
                self.pipe = nil
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) { self.start() }
            }
        }

        do {
            try process.run()
            self.process = process
            self.pipe = pipe
        } catch {
            NSLog("DevIsland: could not start media stream: \(error)")
        }
    }

    /// Kills helpers left behind by an earlier run.
    ///
    /// The adapter writes only when the session *changes*, so a killed app does
    /// not reliably close the pipe and the child can outlive it — observed: two
    /// orphans after a few relaunches. `applicationWillTerminate` covers a clean
    /// quit, but nothing runs on SIGKILL and nothing is guaranteed on SIGTERM, so
    /// the next launch cleans up. Matching on the script path can only ever hit
    /// our own helper.
    private func sweepOrphans(script: URL) {
        let killer = Process()
        killer.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
        killer.arguments = ["-f", script.path]
        killer.standardOutput = FileHandle.nullDevice
        killer.standardError = FileHandle.nullDevice
        try? killer.run()
        killer.waitUntilExit()
    }

    func stop() {
        isStopping = true
        pipe?.fileHandleForReading.readabilityHandler = nil
        process?.terminate()
        process = nil
        pipe = nil
    }

    // MARK: - Parsing

    /// Runs on the pipe's background queue: split on newlines and decode. Artwork
    /// is decoded here too, off the main thread, because it is a ~75 KB JPEG.
    private enum Update {
        case nothingPlaying
        case track(NowPlaying)
    }

    private func consume(_ data: Data) {
        pending.append(data)
        while let newline = pending.firstIndex(of: 0x0A) {
            let line = pending[pending.startIndex..<newline]
            pending = pending[pending.index(after: newline)...]
            guard !line.isEmpty else { continue }
            switch decode(line) {
            case .nothingPlaying:
                DispatchQueue.main.async { [weak self] in self?.onUpdate?(nil) }
            case let .track(track):
                DispatchQueue.main.async { [weak self] in self?.onUpdate?(track) }
            case nil:
                continue
            }
        }
    }

    private func decode(_ line: Data) -> Update? {
        guard let raw = try? JSONSerialization.jsonObject(with: line),
              let object = raw as? [String: Any],
              let payload = object["payload"] as? [String: Any]
        else { return nil }

        // An empty payload means nothing is playing. The adapter emits one of
        // these on startup too, so this must not be treated as an error.
        guard !payload.isEmpty else { return .nothingPlaying }

        guard let title = payload["title"] as? String, !title.isEmpty else { return nil }

        func number(_ key: String) -> Double {
            (payload[key] as? NSNumber)?.doubleValue ?? 0
        }

        let artist = payload["artist"] as? String ?? ""
        let identifier = payload["contentItemIdentifier"] as? String ?? "\(title)|\(artist)"

        // Artwork arrives with the first payload for a track and is absent from
        // the diff updates that follow, so it is cached by item identifier rather
        // than re-decoded — a 75 KB JPEG per update would be absurd.
        var artwork = artworkCache[identifier]
        if artwork == nil,
           let base64 = payload["artworkData"] as? String,
           let bytes = Data(base64Encoded: base64) {
            artwork = NSImage(data: bytes)
            artworkCache[identifier] = artwork
            if artworkCache.count > 8 { artworkCache.removeAll() }
        }

        // `playing` wins: the adapter reports `playbackRate: 1` on a *paused*
        // track, so trusting the rate alone would show a paused video as playing.
        let rate = (payload["playing"] as? Bool).map { $0 ? 1.0 : 0.0 }
            ?? number("playbackRate")
        let stamp = (payload["timestamp"] as? String).flatMap { decoder.date(from: $0) } ?? Date()

        return .track(NowPlaying(
            title: title,
            artist: artist,
            album: payload["album"] as? String ?? "",
            duration: number("duration"),
            elapsed: number("elapsedTime"),
            rate: rate,
            timestamp: stamp,
            artwork: artwork
        ))
    }
}
