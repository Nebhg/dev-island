import AppKit
import Carbon.HIToolbox

/// Global shortcuts for switching panels while the island is open.
///
/// Carbon's `RegisterEventHotKey` is used rather than `NSEvent` global monitors
/// because a global key monitor needs Accessibility permission, and rather than
/// menu key equivalents because the panel never becomes the active app.
///
/// Panel shortcuts are only registered while the island is expanded, so they cannot
/// shadow anything system-wide when it is closed. The single exception is the
/// open/close key, which has to listen while the island is shut — that is why it
/// carries a second modifier.
final class HotKeys {
    /// Called on the main thread with the shortcut that fired.
    var onPanel: ((Int) -> Void)?
    var onCycle: ((Int) -> Void)?
    /// Opens or closes the island. The only shortcut that lives for the whole
    /// process, because an island that is closed still needs a way in.
    var onToggle: (() -> Void)?

    private var handler: EventHandlerRef?
    private var registered: [EventHotKeyRef] = []
    private var toggleRef: EventHotKeyRef?
    private var isInstalled = false

    private enum Slot: UInt32 {
        case panel1 = 1
        case panel2 = 2
        case panel3 = 3
        case panel4 = 4
        case previous = 5
        case next = 6
        case toggle = 7
    }

    private struct Key {
        let slot: Slot
        let keyCode: UInt32
        let modifiers: UInt32
    }

    /// ⌥1–4 jump straight to a panel; ⌃⌥←/→ cycle; ⌃⌥↓ opens the island.
    ///
    /// ⌘1–4 is the obvious choice and the wrong one: macOS and most apps claim
    /// ⌘-number and ⌃-number first (tab switching, Spaces), and those win before a
    /// Carbon hotkey is consulted, so the shortcut would silently never arrive.
    /// ⌥-number is claimed by nothing, which is why plain ⌥ is what these use.
    ///
    /// Cycling sits on ⌃⌥ arrows so it shares the open key's modifier and the hand
    /// is already on the arrow cluster. ⌥← / ⌥→ is word-wise text navigation and
    /// would be a bad trade even while the island is open.
    private static let keys: [Key] = [
        Key(slot: .panel1, keyCode: UInt32(kVK_ANSI_1), modifiers: UInt32(optionKey)),
        Key(slot: .panel2, keyCode: UInt32(kVK_ANSI_2), modifiers: UInt32(optionKey)),
        Key(slot: .panel3, keyCode: UInt32(kVK_ANSI_3), modifiers: UInt32(optionKey)),
        Key(slot: .panel4, keyCode: UInt32(kVK_ANSI_4), modifiers: UInt32(optionKey)),
        Key(slot: .previous, keyCode: UInt32(kVK_LeftArrow), modifiers: UInt32(controlKey | optionKey)),
        Key(slot: .next, keyCode: UInt32(kVK_RightArrow), modifiers: UInt32(controlKey | optionKey)),
        Key(slot: .previous, keyCode: UInt32(kVK_Tab), modifiers: UInt32(optionKey | shiftKey)),
        Key(slot: .next, keyCode: UInt32(kVK_Tab), modifiers: UInt32(optionKey))
    ]

    /// ⌃⌥↓ toggles the island.
    ///
    /// This one is registered at launch and never unregistered, so it cannot be a
    /// bare ⌥↓: that is next-paragraph in every text editor, and stealing it
    /// permanently would be a much worse trade than the panel keys, which only
    /// exist while the island is already open.
    private static let toggleKey = Key(
        slot: .toggle,
        keyCode: UInt32(kVK_DownArrow),
        modifiers: UInt32(controlKey | optionKey)
    )

    // MARK: - Lifecycle

    func install() {
        guard !isInstalled else { return }
        isInstalled = true
        installEventHandler()
        for key in Self.keys {
            if let ref = register(key) { registered.append(ref) }
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
        registered.forEach { UnregisterEventHotKey($0) }
        registered.removeAll()
        isInstalled = false
        // The Carbon event handler and the toggle hotkey stay installed: collapsing
        // the island must not also disarm the key that can reopen it.
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
            NSLog("DevIsland: hotkey \(key.slot.rawValue) registration failed (\(status))")
            return nil
        }
        return ref
    }

    private func dispatch(_ slot: Slot?) {
        guard let slot else { return }
        switch slot {
        case .panel1, .panel2, .panel3, .panel4:
            onPanel?(Int(slot.rawValue) - 1)
        case .previous:
            onCycle?(-1)
        case .next:
            onCycle?(1)
        case .toggle:
            onToggle?()
        }
    }
}
