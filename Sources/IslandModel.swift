import AppKit
import Combine
import Foundation

final class IslandModel: ObservableObject {
    @Published var expanded = false
    @Published var nowPlaying: NowPlaying?
    @Published var notchSize = CGSize(width: 185, height: 32)

    /// Set by the screenshot/launch flag so the island does not close while
    /// the pointer is elsewhere.
    var locksOpen = false

    /// While true, hovering will not reopen the island. Set when handing off to
    /// Spotlight, because the pointer is still sitting on the island.
    var suppressed = false

    /// Hides the whole window while Spotlight is up — a status-bar-level window
    /// would otherwise sit on top of the panel.
    var onHandOff: (() -> Void)?

    let player = PlayerService()

    private var cancellables = Set<AnyCancellable>()

    init() {
        player.$nowPlaying
            .receive(on: RunLoop.main)
            .sink { [weak self] track in self?.nowPlaying = track }
            .store(in: &cancellables)
    }

    // MARK: - Geometry

    /// Idle: exactly the camera cutout (no pixels, so invisible).
    /// Playing: the cutout plus a wing either side for artwork and a waveform,
    ///          which is real menu-bar screen but reads as one black band.
    /// Expanded: a black panel flush with the top edge, NotchNook style.
    var islandSize: CGSize {
        if expanded { return IslandRootView.expandedSize }
        // BoringNotch's "chin": the closed notch is 2pt wider than the cutout,
        // and grows by 2*(height-12)+20 while music plays.
        let base = notchSize.width + 4
        let playing = nowPlaying?.isPlaying == true
        let chin = playing ? (2 * max(0, notchSize.height - 12) + 20) : 0
        return CGSize(width: base + chin, height: notchSize.height)
    }

    /// The island is always pinned to the top edge of the display.
    var islandTopGap: CGFloat { 0 }

    // MARK: - Presentation

    func expand() {
        guard !expanded, !suppressed else { return }
        expanded = true
    }

    func collapse() {
        guard expanded else { return }
        expanded = false
    }

    func toggleExpanded() {
        expanded ? collapse() : expand()
    }

    /// Clicking the island hands off to Spotlight / Siri search. The island
    /// gets out of the way first, otherwise it floats above the panel.
    func openSpotlight() {
        suppressed = true
        collapse()
        onHandOff?()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            guard let url = URL(string: "spotlight://") else { return }
            NSWorkspace.shared.open(url)
        }
    }
}

final class PlayerService: ObservableObject {
    @Published private(set) var nowPlaying: NowPlaying?

    private let remote = MediaRemote.shared
    private let spotify = SpotifyBridge.shared
    private var observers: [NSObjectProtocol] = []
    private var poll: Timer?
    private var spotifyIsSource = false
    private var lastArtworkURL = ""

    init() {
        remote.startObserving()

        for name in [Notification.Name.nowPlayingDidChange, .playingStateDidChange] {
            observers.append(NotificationCenter.default.addObserver(
                forName: name, object: nil, queue: .main
            ) { [weak self] _ in self?.refresh() })
        }

        // Spotify posts this on every track / state change, so titles and
        // artwork land immediately instead of waiting for the poll.
        observers.append(DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("com.spotify.client.PlaybackStateChanged"),
            object: nil,
            queue: .main
        ) { [weak self] _ in self?.refresh() })

        poll = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            self?.refresh()
        }
        refresh()
    }

    deinit {
        observers.forEach(NotificationCenter.default.removeObserver)
    }

    func refresh() {
        guard spotify.isRunning else {
            useMediaRemote()
            return
        }
        spotify.fetch { [weak self] snapshot in
            guard let self else { return }
            if let snapshot, snapshot.isPlaying {
                self.apply(snapshot)
                return
            }
            self.remote.fetch { [weak self] track in
                guard let self else { return }
                if let track {
                    self.spotifyIsSource = false
                    self.nowPlaying = track
                } else if let snapshot {
                    self.apply(snapshot)
                } else {
                    self.spotifyIsSource = false
                    self.nowPlaying = nil
                }
            }
        }
    }

    private func useMediaRemote() {
        remote.fetch { [weak self] track in
            self?.spotifyIsSource = false
            self?.nowPlaying = track
        }
    }

    private func apply(_ snapshot: SpotifySnapshot) {
        spotifyIsSource = true
        let keepArtwork = snapshot.artworkURL == lastArtworkURL
        nowPlaying = NowPlaying(
            title: snapshot.title,
            artist: snapshot.artist,
            album: snapshot.album,
            duration: snapshot.duration,
            elapsed: snapshot.position,
            rate: snapshot.isPlaying ? 1 : 0,
            timestamp: Date(),
            artwork: keepArtwork ? nowPlaying?.artwork : nil
        )

        guard snapshot.artworkURL != lastArtworkURL else { return }
        lastArtworkURL = snapshot.artworkURL
        let url = snapshot.artworkURL
        spotify.artwork(for: url) { [weak self] image in
            guard let self, let image, self.lastArtworkURL == url,
                  var current = self.nowPlaying
            else { return }
            current.artwork = image
            self.nowPlaying = current
        }
    }

    // MARK: - Transport

    func toggle() {
        if spotifyIsSource {
            spotify.command("playpause")
        } else {
            remote.togglePlayPause()
        }
        refreshSoon()
    }

    func next() {
        if spotifyIsSource {
            spotify.command("next track")
        } else {
            remote.next()
        }
        refreshSoon()
    }

    func previous() {
        if spotifyIsSource {
            spotify.command("previous track")
        } else {
            remote.previous()
        }
        refreshSoon()
    }

    func seek(to seconds: Double) {
        if spotifyIsSource {
            spotify.seek(to: seconds)
        } else {
            remote.setElapsedTime(seconds)
        }
        if var track = nowPlaying {
            track.elapsed = seconds
            track.timestamp = Date()
            nowPlaying = track
        }
        refreshSoon()
    }

    private func refreshSoon() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            self?.refresh()
        }
    }
}
