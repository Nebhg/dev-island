import AppKit
import Carbon.HIToolbox

/// The global shortcut that opens the clipboard picker. Presets rather than a key
/// recorder: each is picked from the menu bar, and each takes over one shortcut in
/// other apps, which the menu cannot hide from whoever picks it.
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
/// also what lets a picked entry paste into the app that still has focus.
///
/// Three groups, each registered only while it can mean something:
/// - the clipboard shortcut, always, unless it is switched off;
/// - ⌥⌘1–5 and ⌥⌘← / ⌥⌘→, while the island is open;
/// - ↑ ↓ ↩ ⌥↩ ⎋, while the clipboard picker is open. These carry no modifier, so
///   they shadow those keys in every app while registered — which is why they live
///   exactly as long as the picker does.
final class HotKeys {
    enum PickerKey {
        case up, down, paste, copy, close
    }

    /// All called on the main thread.
    var onPanel: ((Int) -> Void)?
    var onCycle: ((Int) -> Void)?
    var onPicker: (() -> Void)?
    var onPickerKey: ((PickerKey) -> Void)?

    private var handler: EventHandlerRef?
    private var panelRefs: [EventHotKeyRef] = []
    private var pickerRefs: [EventHotKeyRef] = []
    private var shortcutRef: EventHotKeyRef?

    private enum Slot: UInt32 {
        case panel1 = 1
        case panel2 = 2
        case panel3 = 3
        case panel4 = 4
        case panel5 = 5
        case previous = 6
        case next = 7
        case picker = 8
        case up = 9
        case down = 10
        case paste = 11
        case pasteKeypad = 12
        case copy = 13
        case close = 14
    }

    private static let panelModifiers = UInt32(cmdKey | optionKey)

    /// ⌥⌘1–5 jump straight to a panel, in `PanelID.allCases` order; ⌥⌘← / ⌥⌘→ cycle.
    private static let panelKeys: [(Slot, Int, UInt32)] = [
        (.panel1, kVK_ANSI_1, panelModifiers),
        (.panel2, kVK_ANSI_2, panelModifiers),
        (.panel3, kVK_ANSI_3, panelModifiers),
        (.panel4, kVK_ANSI_4, panelModifiers),
        (.panel5, kVK_ANSI_5, panelModifiers),
        (.previous, kVK_LeftArrow, panelModifiers),
        (.next, kVK_RightArrow, panelModifiers)
    ]

    /// ⌥↩ copies without pasting, matching ⌥-click on a row.
    private static let pickerKeys: [(Slot, Int, UInt32)] = [
        (.up, kVK_UpArrow, 0),
        (.down, kVK_DownArrow, 0),
        (.paste, kVK_Return, 0),
        (.pasteKeypad, kVK_ANSI_KeypadEnter, 0),
        (.copy, kVK_Return, UInt32(optionKey)),
        (.close, kVK_Escape, 0)
    ]

    init() {
        installHandler()
    }

    deinit {
        uninstall()
        uninstallPickerKeys()
        setClipboardShortcut(nil)
        if let handler { RemoveEventHandler(handler) }
    }

    // MARK: - Groups

    /// Panel switching, while the island is open.
    func install() {
        guard panelRefs.isEmpty else { return }
        panelRefs = Self.panelKeys.compactMap { register($0.0, keyCode: $0.1, modifiers: $0.2) }
    }

    func uninstall() {
        panelRefs.forEach { UnregisterEventHotKey($0) }
        panelRefs.removeAll()
    }

    /// Picker navigation, while the picker is open.
    func installPickerKeys() {
        guard pickerRefs.isEmpty else { return }
        pickerRefs = Self.pickerKeys.compactMap { register($0.0, keyCode: $0.1, modifiers: $0.2) }
    }

    func uninstallPickerKeys() {
        pickerRefs.forEach { UnregisterEventHotKey($0) }
        pickerRefs.removeAll()
    }

    /// Replaces the clipboard shortcut; nil switches it off. Returns false when the
    /// combination could not be registered — usually because another app holds it.
    @discardableResult
    func setClipboardShortcut(_ shortcut: ClipboardShortcut?) -> Bool {
        if let shortcutRef {
            UnregisterEventHotKey(shortcutRef)
            self.shortcutRef = nil
        }
        guard let shortcut else { return true }
        shortcutRef = register(.picker, keyCode: kVK_ANSI_V, modifiers: shortcut.modifiers)
        return shortcutRef != nil
    }

    // MARK: - Internals

    /// One handler for the process lifetime: the clipboard shortcut has to work
    /// while the island is closed.
    private func installHandler() {
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

    private func register(_ slot: Slot, keyCode: Int, modifiers: UInt32) -> EventHotKeyRef? {
        var ref: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: OSType(0x4449_534C), id: slot.rawValue) // 'DISL'
        let status = RegisterEventHotKey(
            UInt32(keyCode),
            modifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &ref
        )
        guard status == noErr, let ref else {
            NSLog("DevIsland: hotkey \(slot) registration failed (\(status))")
            return nil
        }
        return ref
    }

    private func dispatch(_ slot: Slot?) {
        guard let slot else { return }
        switch slot {
        case .panel1, .panel2, .panel3, .panel4, .panel5:
            onPanel?(Int(slot.rawValue) - 1)
        case .previous:
            onCycle?(-1)
        case .next:
            onCycle?(1)
        case .picker:
            onPicker?()
        case .up:
            onPickerKey?(.up)
        case .down:
            onPickerKey?(.down)
        case .paste, .pasteKeypad:
            onPickerKey?(.paste)
        case .copy:
            onPickerKey?(.copy)
        case .close:
            onPickerKey?(.close)
        }
    }
}
