import AppKit
import Carbon.HIToolbox

/// The global shortcut that opens the keyboard history selection. Presets rather
/// than a key recorder: each is picked from the menu bar, and each takes over one
/// shortcut in other apps, which the menu cannot hide from whoever picks it.
enum ClipboardShortcut: String, CaseIterable {
    case shiftCommandV
    case optionCommandV
    case controlCommandV

    var title: String {
        switch self {
        case .shiftCommandV: "⇧⌘V"
        case .optionCommandV: "⌥⌘V"
        case .controlCommandV: "⌃⌘V"
        }
    }

    /// `⇧⌘V` is Paste and Match Style in Chrome, Slack, Docs and Notion, and this
    /// shortcut is registered for the whole process, not just while the island is
    /// open. `⌥⌘V` is Finder's Move Item Here. All three steal something; ⌃⌘V is
    /// the one nothing common uses.
    static let `default`: ClipboardShortcut = .controlCommandV

    fileprivate var modifiers: UInt32 {
        switch self {
        case .shiftCommandV: UInt32(cmdKey | shiftKey)
        case .optionCommandV: UInt32(cmdKey | optionKey)
        case .controlCommandV: UInt32(cmdKey | controlKey)
        }
    }
}

/// Global shortcuts.
///
/// Carbon's `RegisterEventHotKey` is used rather than `NSEvent` global monitors
/// because a global key monitor needs Accessibility permission, and rather than
/// menu key equivalents because the panel never becomes the active app — which is
/// also what lets a picked row paste into the app that still has focus.
///
/// Three groups, each registered only while it can mean something:
///
/// - **always** — `⌃⌥↓` and the clipboard shortcut. Both have to work while the
///   island is shut, since a closed island is exactly when they are needed.
/// - **panel** — `⌥1`–`⌥5`, `⌃⌥←/→` and the `⌥Tab` aliases, while the island is
///   open. Their meaning narrows when the keyboard mode is on; see `PanelKey`.
/// - **mode** — `↩`, `⌥↩` and `⎋`, while the island is being driven from the
///   keyboard. These are the only chords here with no modifier, which is why their
///   lifetime is tied to that mode and nothing else.
final class HotKeys {
    /// What a panel-group chord means right now. The controller decides, because
    /// only it knows whether the island is in keyboard mode.
    enum PanelKey {
        case select(Int)
    }

    /// What a mode-group chord means. Only live while `modeKeys` is installed.
    ///
    /// `cyclePanel` and `moveRow` are named apart rather than folded into one
    /// `step(Int)`: the two used to travel as the same case because the same chord
    /// served both, and at the call site they were indistinguishable. They are not
    /// the same action and do not read as one.
    enum ModeKey {
        /// `←` / `→`. Previous or next list panel.
        case cyclePanel(Int)
        /// `↑` / `↓`. Previous or next row in the list on screen.
        case moveRow(Int)
        case paste
        case close
    }

    /// All called on the main thread.
    var onPanelKey: ((PanelKey) -> Void)?
    /// Opens or closes the island. The only shortcut that lives for the whole
    /// process alongside the clipboard one, because an island that is closed still
    /// needs a way in.
    var onToggle: (() -> Void)?
    /// The clipboard shortcut: opens the island on the clipboard with a row
    /// selected, or leaves that mode if it is already on.
    var onClipboard: (() -> Void)?
    var onModeKey: ((ModeKey) -> Void)?

    private var handler: EventHandlerRef?
    private var panelRefs: [EventHotKeyRef] = []
    private var modeRefs: [EventHotKeyRef] = []
    private var toggleRef: EventHotKeyRef?
    private var shortcutRef: EventHotKeyRef?
    private var isInstalled = false

    /// One raw-value namespace shared by every group, so a hotkey ID identifies
    /// exactly one chord. Numbered in one pass, contiguously: the two branches this
    /// file was merged from inserted at different offsets, and overlapping numbers
    /// would make `dispatch` ambiguous.
    private enum Slot: UInt32 {
        case toggle = 0
        case panel1 = 1
        case panel2 = 2
        case panel3 = 3
        case panel4 = 4
        case panel5 = 5
        case clipboard = 6
        case left = 7
        case right = 8
        case up = 9
        case down = 10
        case paste = 11
        case pasteKeypad = 12
        case close = 13
    }

    private struct Key {
        let slot: Slot
        let keyCode: UInt32
        let modifiers: UInt32
    }

    /// `⌥1`–`⌥5` jump straight to a panel, in `PanelID.allCases` order. `⌃⌥↓` opens
    /// the island and `←`/`→` cycle panels once it is being driven from the keyboard;
    /// neither lives in this group.
    ///
    /// `⌘1`–`⌘5` is the obvious choice and the wrong one: macOS and most apps claim
    /// `⌘`-number and `⌃`-number first (tab switching, Spaces), and those win before
    /// a Carbon hotkey is consulted, so the shortcut would silently never arrive.
    /// `⌥`-number is claimed by nothing, which is why plain `⌥` is what these use.
    /// The same mistake in reverse — `⌥⌘1`–`⌥⌘5` — was tried and withdrawn for the
    /// same reason.
    ///
    /// What used to be here is worth recording, because both looked reasonable:
    /// `⌃⌥←/→` for cycling and `⌥Tab`/`⌥⇧Tab` as an alias. The arrows took three keys
    /// to change panel and had to be overloaded — the same chord cycled panels or
    /// moved the selected row depending on a mode the user could not see. The Tab
    /// alias was the one chord in the file whose cost had been weighed rather than
    /// dodged: while the island was open it took Option-Tab from every app. Both are
    /// gone. Panels are reachable by number at any time, and by arrow once the mode is
    /// armed, which is the only state where a bare arrow is already spoken for.
    private static let keys: [Key] = [
        Key(slot: .panel1, keyCode: UInt32(kVK_ANSI_1), modifiers: UInt32(optionKey)),
        Key(slot: .panel2, keyCode: UInt32(kVK_ANSI_2), modifiers: UInt32(optionKey)),
        Key(slot: .panel3, keyCode: UInt32(kVK_ANSI_3), modifiers: UInt32(optionKey)),
        Key(slot: .panel4, keyCode: UInt32(kVK_ANSI_4), modifiers: UInt32(optionKey)),
        Key(slot: .panel5, keyCode: UInt32(kVK_ANSI_5), modifiers: UInt32(optionKey))
    ]

    /// `⌃⌥↓` toggles the island.
    ///
    /// This one is registered at launch and never unregistered, so it cannot be a
    /// bare `⌥↓`: that is next-paragraph in every text editor, and stealing it
    /// permanently would be a much worse trade than the panel keys, which only
    /// exist while the island is already open.
    private static let toggleKey = Key(
        slot: .toggle,
        keyCode: UInt32(kVK_DownArrow),
        modifiers: UInt32(controlKey | optionKey)
    )

    /// Navigation and dismissal, while the island is being driven from the keyboard.
    ///
    /// This is the widest interception in the app: while installed, `← → ↑ ↓ ↩ ⌤ ⎋`
    /// stop reaching the frontmost app. That is affordable only because the mode is
    /// entered deliberately and ends on the first thing that means "done" — paste,
    /// escape, panel change, outside click, app switch or collapse.
    ///
    /// Hovering the island never installs them. That distinction is the whole reason
    /// the arrows can be bare: a pointer resting near the notch is not a request to
    /// take the arrow keys off every other app, and a hovered island has no way to say
    /// so.
    private static let modeKeys: [Key] = [
        Key(slot: .left, keyCode: UInt32(kVK_LeftArrow), modifiers: 0),
        Key(slot: .right, keyCode: UInt32(kVK_RightArrow), modifiers: 0),
        Key(slot: .up, keyCode: UInt32(kVK_UpArrow), modifiers: 0),
        Key(slot: .down, keyCode: UInt32(kVK_DownArrow), modifiers: 0),
        Key(slot: .paste, keyCode: UInt32(kVK_Return), modifiers: 0),
        Key(slot: .pasteKeypad, keyCode: UInt32(kVK_ANSI_KeypadEnter), modifiers: 0),
        Key(slot: .close, keyCode: UInt32(kVK_Escape), modifiers: 0)
    ]

    // MARK: - Lifecycle

    func install() {
        guard !isInstalled else { return }
        isInstalled = true
        installEventHandler()
        for key in Self.keys {
            if let ref = register(key) { panelRefs.append(ref) }
        }
    }

    /// Registers the open/close key, which outlives the island.
    ///
    /// Separate from `install()` because that pair is tied to the expanded state,
    /// and separate storage so `uninstall()` on collapse cannot take this one with
    /// it.
    func installToggle() {
        installEventHandler()
        guard toggleRef == nil else { return }
        toggleRef = register(Self.toggleKey)
    }

    func uninstall() {
        panelRefs.forEach { UnregisterEventHotKey($0) }
        panelRefs.removeAll()
        // The mode cannot outlive the island, so collapsing takes its keys too. The
        // `$expanded` sink already does this a moment earlier; clearing here as well
        // means the invariant holds structurally, and a sink that stops firing cannot
        // leave bare `↩` stolen from every app with no island on screen.
        uninstallModeKeys()
        isInstalled = false
        // The Carbon event handler, the toggle hotkey and the clipboard shortcut
        // stay installed: collapsing the island must not also disarm the keys that
        // can reopen it.
    }

    /// Row actions and dismissal, while the island is in keyboard mode.
    ///
    /// Registered in pairs with `uninstallModeKeys()` and nowhere else: every path out
    /// of the mode has to come through here, or bare `↩` stays stolen from every app.
    func installModeKeys() {
        guard modeRefs.isEmpty else { return }
        modeRefs = Self.modeKeys.compactMap(register)
    }

    func uninstallModeKeys() {
        modeRefs.forEach { UnregisterEventHotKey($0) }
        modeRefs.removeAll()
    }

    /// Replaces the clipboard shortcut; nil switches it off.
    ///
    /// The result says only whether Carbon returned an error. It is **not** a
    /// statement that the chord is free: `RegisterEventHotKey` returns `noErr` for a
    /// chord another process already holds, and for chords the system itself owns —
    /// measured, see `PLAN.md` §2. Nothing is reported to the user on the strength
    /// of this value.
    @discardableResult
    func setClipboardShortcut(_ shortcut: ClipboardShortcut?) -> Bool {
        if let shortcutRef {
            UnregisterEventHotKey(shortcutRef)
            self.shortcutRef = nil
        }
        guard let shortcut else { return true }
        shortcutRef = register(Key(
            slot: .clipboard,
            keyCode: UInt32(kVK_ANSI_V),
            modifiers: shortcut.modifiers
        ))
        return shortcutRef != nil
    }

    // MARK: - Internals

    private func installEventHandler() {
        guard handler == nil else { return }
        var spec = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let context = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(GetApplicationEventTarget(), { _, event, userData in
            guard let event, let userData else { return noErr }
            var hotKeyID = EventHotKeyID()
            let status = GetEventParameter(
                event,
                EventParamName(kEventParamDirectObject),
                EventParamType(typeEventHotKeyID),
                nil,
                MemoryLayout<EventHotKeyID>.size,
                nil,
                &hotKeyID
            )
            guard status == noErr else { return noErr }
            let hotKeys = Unmanaged<HotKeys>.fromOpaque(userData).takeUnretainedValue()
            hotKeys.dispatch(Slot(rawValue: hotKeyID.id))
            return noErr
        }, 1, &spec, context, &handler)
    }

    @discardableResult
    private func register(_ key: Key) -> EventHotKeyRef? {
        var ref: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: OSType(0x4449_534C), id: key.slot.rawValue) // 'DISL'
        let status = RegisterEventHotKey(
            key.keyCode,
            key.modifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &ref
        )
        guard status == noErr, let ref else {
            NSLog("DevIsland: hotkey \(key.slot) registration failed (\(status))")
            return nil
        }
        return ref
    }

    private func dispatch(_ slot: Slot?) {
        guard let slot else { return }
        switch slot {
        case .panel1, .panel2, .panel3, .panel4, .panel5:
            // Slot numbers start at 1, so `panel1` is index 0 into
            // `PanelID.allCases`. Settings is the fifth case, which is what makes
            // ⌥5 reach it.
            onPanelKey?(.select(Int(slot.rawValue) - 1))
        case .toggle:
            onToggle?()
        case .clipboard:
            onClipboard?()
        case .left:
            onModeKey?(.cyclePanel(-1))
        case .right:
            onModeKey?(.cyclePanel(1))
        case .up:
            onModeKey?(.moveRow(-1))
        case .down:
            onModeKey?(.moveRow(1))
        case .paste, .pasteKeypad:
            onModeKey?(.paste)
        case .close:
            onModeKey?(.close)
        }
    }
}
