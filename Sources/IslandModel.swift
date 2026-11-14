import AppKit
import Combine
import Foundation

final class IslandModel: ObservableObject {
    @Published var expanded = false
    @Published var nowPlaying: NowPlaying?
    @Published var notchSize = CGSize(width: 185, height: 32)

    /// Which panel the island is showing. Resets to `defaultPanel` each time it
    /// opens, so the island always lands where it was configured to.
    @Published var activePanel = PanelID.music

    /// The panel opened on hover. Persisted.
    @Published var defaultPanel: PanelID {
        didSet { UserDefaults.standard.set(defaultPanel.rawValue, forKey: Self.defaultPanelKey) }
    }

    /// Set by a provider when its panel is degraded — e.g. terminal history
    /// needing `setopt INC_APPEND_HISTORY`. Rendered as a strip above content.
    @Published var panelNotice: String?

    private static let defaultPanelKey = "defaultPanel"

    /// Set by the screenshot/launch flag so the island does not close while
    /// the pointer is elsewhere.
    var locksOpen = false

    /// While true, hovering will not reopen the island. Set while Spotlight is
    /// open, because the pointer is still sitting on the island.
    var suppressed = false

    /// Set while a drag is in flight or a context menu is tracking, so the 30 ms
    /// collapse does not fire while the pointer is legitimately outside the island.
    /// Lives here rather than on the controller because views need it too: a menu
    /// opened from a row moves the pointer off the island, and a drag-out leaves it
    /// entirely.
    var isInteracting = false

    let player = PlayerService()
    let clipboard = ClipboardService()
    let ignoreRules = IgnoreRules()
    let terminal: TerminalService
    let shelf = ShelfStore()

    /// Set by the shelf panel when a drop lands, so the controller can tell a
    /// completed drop from a cancelled drag and put the previous panel back.
    var shelfDidReceiveDrop = false

    /// Mirrors the player's strip state so SwiftUI re-renders when it changes.
    @Published var showsPlayerStrip = false

    private var cancellables = Set<AnyCancellable>()

    init() {
        let stored = UserDefaults.standard.string(forKey: Self.defaultPanelKey)
        let initial = stored.flatMap(PanelID.init(rawValue:)) ?? .music
        self.defaultPanel = initial
        self.activePanel = initial
        self.terminal = TerminalService(rules: ignoreRules)

        player.$nowPlaying
            .receive(on: RunLoop.main)
            .sink { [weak self] track in self?.nowPlaying = track }
            .store(in: &cancellables)

        player.$showsStrip
            .receive(on: RunLoop.main)
            .sink { [weak self] visible in self?.showsPlayerStrip = visible }
            .store(in: &cancellables)
    }

    // MARK: - Geometry

    /// Idle: exactly the camera cutout (no pixels, so invisible).
    /// Playing: the cutout plus a wing either side for artwork and a waveform,
    ///          which is real menu-bar screen but reads as one black band.
    /// Expanded: a black panel flush with the top edge, NotchNook style.
    var islandSize: CGSize {
        if expanded { return activePanel.preferredSize }
        // BoringNotch's "chin": the closed notch is 2pt wider than the cutout,
        // and grows by 2*(height-12)+20 while music plays.
        let base = notchSize.width + 4
        let playing = nowPlaying?.isPlaying == true
        let chin = playing ? (2 * max(0, notchSize.height - 12) + 20) : 0
        return CGSize(width: base + chin, height: notchSize.height)
    }

    /// The island is always pinned to the top edge of the display.
    var islandTopGap: CGFloat { 0 }

    // MARK: - Panels

    func selectPanel(_ panel: PanelID) {
        guard panel != activePanel else { return }
        activePanel = panel
    }

    // MARK: - Presentation

    func expand() {
        guard !expanded, !suppressed else { return }
        activePanel = defaultPanel
        expanded = true
    }

    func collapse() {
        guard expanded else { return }
        expanded = false
    }

    func toggleExpanded() {
        expanded ? collapse() : expand()
    }

    /// Moves to the next or previous panel, wrapping at the ends.
    func cyclePanel(by step: Int) {
        let all = PanelID.allCases
        guard let index = all.firstIndex(of: activePanel) else { return }
        let next = (index + step + all.count) % all.count
        selectPanel(all[next])
    }

    // MARK: - Clipboard

    /// Copies an entry back and, when asked and permitted, pastes it into whatever
    /// app had focus. The panel never activates the app, so focus is already where
    /// the user left it — there is no focus to restore.
    func pasteClipboard(_ entry: ClipEntry, autoPaste: Bool) {
        guard clipboard.write(entry) else { return }
        deliverPaste(autoPaste: autoPaste)
    }

    /// Terminal commands paste with the trailing newline stripped: history is full
    /// of one-shot destructive commands, and a stray Return would run one.
    func pasteTerminal(_ entry: TerminalEntry, autoPaste: Bool) {
        var text = entry.command
        while text.hasSuffix("\n") || text.hasSuffix("\r") { text.removeLast() }
        guard clipboard.writeText(text) else { return }
        deliverPaste(autoPaste: autoPaste)
    }

    private func deliverPaste(autoPaste: Bool) {
        collapse()
        guard autoPaste, clipboard.canAutoPaste else { return }
        // Next runloop turn: the pasteboard write and the window teardown both have
        // to land before the keystroke, or the target app pastes the old contents.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { [weak self] in
            guard let self else { return }
            if !AccessibilityPaster.postPaste() {
                self.panelNotice = "Grant Accessibility to paste directly."
            }
        }
    }
}

final class PlayerService: ObservableObject {
    @Published private(set) var nowPlaying: NowPlaying? {
        didSet { updateStripVisibility() }
    }

    /// Whether the compact strip should be drawn on the non-music panels.
    ///
    /// The strip is chrome on every other panel, so it should not sit there forever
    /// after playback stops. It stays for `stripGrace` seconds past the last moment
    /// something was actually playing, then disappears.
    @Published private(set) var showsStrip = false

    /// How long the strip lingers after playback stops or pauses. One constant, so
    /// tuning it is a one-line change.
    static let stripGrace: TimeInterval = 120

    private var lastPlaybackAt: Date?
    private var hideWork: DispatchWorkItem?

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

        // No timer here: the controller starts polling when the island opens
        // and stops it when it closes, so a closed island costs nothing.
        refresh()
    }

    deinit {
        observers.forEach(NotificationCenter.default.removeObserver)
        poll?.invalidate()
    }

    /// Runs the 1.5 s AppleScript refresh. Called only while the island is open.
    func startPolling() {
        guard poll == nil else { return }
        poll = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            self?.refresh()
        }
        // Don't show stale state for up to 1.5 s after opening.
        refresh()
    }

    func stopPolling() {
        poll?.invalidate()
        poll = nil
    }

    // MARK: - Strip visibility

    /// Re-evaluated on every `nowPlaying` change, which the 1.5 s poll drives while
    /// the island is open.
    private func updateStripVisibility() {
        if nowPlaying?.isPlaying == true {
            lastPlaybackAt = Date()
            hideWork?.cancel()
            hideWork = nil
            setStripVisible(true)
            return
        }

        guard let lastPlaybackAt else {
            setStripVisible(false)
            return
        }

        let remaining = Self.stripGrace - Date().timeIntervalSince(lastPlaybackAt)
        guard remaining > 0 else {
            setStripVisible(false)
            return
        }

        setStripVisible(true)
        // Only one pending hide: the poll would otherwise queue a new one every
        // 1.5 s while playback is paused.
        guard hideWork == nil else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.hideWork = nil
            guard self.nowPlaying?.isPlaying != true else { return }
            self.setStripVisible(false)
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + remaining, execute: work)
    }

    private func setStripVisible(_ visible: Bool) {
        guard showsStrip != visible else { return }
        showsStrip = visible
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
