import AppKit
import Carbon.HIToolbox

/// Global shortcuts for switching panels while the island is open.
///
/// Carbon's `RegisterEventHotKey` is used rather than `NSEvent` global monitors
/// because a global key monitor needs Accessibility permission, and rather than
/// menu key equivalents because the panel never becomes the active app.
///
/// Shortcuts are only registered while the island is expanded, so they cannot
/// shadow anything system-wide when the island is closed.
final class HotKeys {
    /// Called on the main thread with the shortcut that fired.
    var onPanel: ((Int) -> Void)?
    var onCycle: ((Int) -> Void)?

    private var handler: EventHandlerRef?
    private var registered: [EventHotKeyRef] = []
    private var isInstalled = false

    private enum Slot: UInt32 {
        case panel1 = 1
        case panel2 = 2
        case panel3 = 3
        case panel4 = 4
        case previous = 5
        case next = 6
    }

    /// ⌥⌘1–4 jump straight to a panel; ⌥⌘← / ⌥⌘→ cycle.
    private static let panelKeys: [(Slot, UInt32)] = [
        (.panel1, UInt32(kVK_ANSI_1)),
        (.panel2, UInt32(kVK_ANSI_2)),
        (.panel3, UInt32(kVK_ANSI_3)),
        (.panel4, UInt32(kVK_ANSI_4))
    ]

    private static let cycleKeys: [(Slot, UInt32)] = [
        (.previous, UInt32(kVK_LeftArrow)),
        (.next, UInt32(kVK_RightArrow))
    ]

    private static var modifiers: UInt32 {
        UInt32(cmdKey | optionKey)
    }

    // MARK: - Lifecycle

    func install() {
        guard !isInstalled else { return }
        isInstalled = true

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

        for (slot, keyCode) in Self.panelKeys + Self.cycleKeys {
            register(slot: slot, keyCode: keyCode)
        }
    }

    func uninstall() {
        registered.forEach { UnregisterEventHotKey($0) }
        registered.removeAll()
        if let handler {
            RemoveEventHandler(handler)
            self.handler = nil
        }
        isInstalled = false
    }

    // MARK: - Internals

    private func register(slot: Slot, keyCode: UInt32) {
        var ref: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: OSType(0x4449_534C), id: slot.rawValue) // 'DISL'
        let status = RegisterEventHotKey(
            keyCode,
            Self.modifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &ref
        )
        if status == noErr, let ref {
            registered.append(ref)
        } else {
            NSLog("DevIsland: hotkey \(slot.rawValue) registration failed (\(status))")
        }
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
        }
    }
}
