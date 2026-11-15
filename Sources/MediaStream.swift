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
    private var isStopping = false

    /// Parsing lives in its own type so it can be tested without a subprocess.
    private var decoder = MediaStreamDecoder()

    func start() {
        guard process == nil else { return }
        guard let script = Bundle.main.url(forResource: "mediaremote-adapter", withExtension: "pl"),
              let frameworksPath = Bundle.main.privateFrameworksPath
        else {
            NSLog("DevIsland: mediaremote-adapter missing from the bundle")
            return
        }

        sweepOrphan()

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
            try? String(process.processIdentifier).write(
                to: Self.pidURL, atomically: true, encoding: .utf8)
        } catch {
            NSLog("DevIsland: could not start media stream: \(error)")
        }
    }

    /// Where the child's pid is remembered between runs.
    private static var pidURL: URL {
        AppSupport.directory().appendingPathComponent("media-helper.pid")
    }

    /// Kills the helper left behind by an earlier run, if there is one.
    ///
    /// The adapter writes only when the session *changes*, so a killed app does not
    /// reliably close the pipe and the child can outlive it — observed: two helpers
    /// streaming at once. `applicationWillTerminate` covers a clean quit, but nothing
    /// runs on SIGKILL and nothing is guaranteed on SIGTERM, so the next launch
    /// cleans up.
    ///
    /// **A pid file, not `pkill -f`.** Pattern matching on the script name killed
    /// whatever else happened to mention it — including a shell running a command
    /// line that referenced the adapter, which is how this was noticed: the app
    /// terminated the terminal that launched it. Signalling one remembered pid,
    /// after confirming by inspection that it is still our helper, cannot do that.
    private func sweepOrphan() {
        guard let text = try? String(contentsOf: Self.pidURL, encoding: .utf8),
              let pid = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)),
              pid > 0
        else { return }

        // A recycled pid must not take a stray process with it, so ask ps what it
        // is before signalling. This inspects one process; it does not hunt.
        let ps = Process()
        ps.executableURL = URL(fileURLWithPath: "/bin/ps")
        ps.arguments = ["-o", "command=", "-p", String(pid)]
        let pipe = Pipe()
        ps.standardOutput = pipe
        ps.standardError = FileHandle.nullDevice
        guard (try? ps.run()) != nil else { return }
        ps.waitUntilExit()
        let command = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        guard command.contains("mediaremote-adapter.pl") else { return }
        kill(pid, SIGTERM)
    }

    func stop() {
        isStopping = true
        pipe?.fileHandleForReading.readabilityHandler = nil
        process?.terminate()
        process = nil
        pipe = nil
        try? FileManager.default.removeItem(at: Self.pidURL)
    }

    // MARK: - Parsing

    /// Runs on the pipe's background queue: split on newlines and decode. Artwork
    /// is decoded there too, off the main thread, because it is a ~75 KB JPEG.
    private func consume(_ data: Data) {
        pending.append(data)
        while let newline = pending.firstIndex(of: 0x0A) {
            let line = pending[pending.startIndex..<newline]
            pending = pending[pending.index(after: newline)...]
            guard !line.isEmpty else { continue }
            switch decoder.decode(line) {
            case .nothingPlaying:
                DispatchQueue.main.async { [weak self] in self?.onUpdate?(nil) }
            case let .track(track):
                DispatchQueue.main.async { [weak self] in self?.onUpdate?(track) }
            case nil:
                continue
            }
        }
    }
}
