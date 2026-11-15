import AppKit

/// The island window's drop target for files: the window's content view, so a file
/// can be let go of anywhere on the island — the notch band included — rather than
/// only over the shelf's list, which meant dragging up to the notch and then back
/// down again.
///
/// **Why AppKit rather than SwiftUI's `onDrop`.** The Dock's Downloads stack would
/// not drop. Measured with a probe, its drags carry the same pasteboard types as
/// Finder's (`public.file-url`, `NSFilenamesPboardType`, `com.apple.finder.node`)
/// and the hover monitor sees the same dragged events, so the difference is at the
/// drop. Two suspects, both handled here: `onDrop` always proposes a copy, and a
/// source that does not offer one gets the no-entry cursor — here the mask is
/// visible, so the drop takes whatever the source allows; and reading the file URLs
/// while the drag is in flight, which a source that only supplies them at the end
/// answers with nothing — here the decision uses the types alone. Nothing is copied
/// or moved whichever operation is picked: the shelf only records a reference.
///
/// Behind both sits the controller's safety net, which reads a file released over
/// the open shelf straight from the drag pasteboard if no drop arrived at all.
///
/// Files only. Text and links are the clipboard's job: copying them is one keystroke,
/// the clipboard already captures them, and a shelf row would be a second place to
/// look for the same string.
///
/// The hosting view sits inside this one. SwiftUI only registers a drag destination
/// (a hidden subview) for views that use `onDrop`, and nothing in the island does,
/// so drags fall through to here.
final class FileDropView: NSView {
    /// Whether a drop would be taken right now — the island has to be open.
    var canAccept: () -> Bool = { false }
    /// Drives the shelf's outline while a file is over the island.
    var onTargetChange: (Bool) -> Void = { _ in }
    var onDrop: ([URL]) -> Void = { _ in }

    /// Decided once when a drag enters, because asking the pasteboard is a round
    /// trip and `draggingUpdated` fires at pointer rate.
    private var operationForCurrentDrag: NSDragOperation = []

    /// The pre-UTI flavour: a property list of paths. The Dock writes it alongside
    /// `public.file-url`, and some older sources write only this.
    static let filenamesType = NSPasteboard.PasteboardType("NSFilenamesPboardType")

    private static let probe = ProcessInfo.processInfo.environment["ISLAND_DRAG_PROBE"] == "1"

    override init(frame: NSRect) {
        super.init(frame: frame)
        registerForDraggedTypes([.fileURL, Self.filenamesType])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        operationForCurrentDrag = chooseOperation(for: sender)
        if Self.probe {
            let types = (sender.draggingPasteboard.types ?? []).map(\.rawValue).prefix(4).joined(separator: ", ")
            NSLog("[probe] drop target entered mask=\(sender.draggingSourceOperationMask.rawValue) chosen=\(operationForCurrentDrag.rawValue) own=\(sender.draggingSource != nil) open=\(canAccept()) types=[\(types)]")
        }
        return current()
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        current()
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        onTargetChange(false)
    }

    override func draggingEnded(_ sender: NSDraggingInfo) {
        operationForCurrentDrag = []
        onTargetChange(false)
    }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let accepting = current() != []
        if Self.probe {
            NSLog("[probe] drop target prepare accepting=\(accepting)")
        }
        return accepting
    }

    /// The files are read here, at the drop, and not while the drag is in flight.
    /// If this comes back empty the controller's safety net reads the drag
    /// pasteboard again once the source has finished — see
    /// `IslandController.restorePanelIfDragWasCancelled`.
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let start = Date()
        let urls = Self.fileURLs(on: sender.draggingPasteboard)
        if Self.probe {
            NSLog("[probe] drop performed files=\(urls.count) readTook=\(Int(Date().timeIntervalSince(start) * 1000))ms")
        }
        guard !urls.isEmpty else { return false }
        onDrop(urls)
        return true
    }

    /// The island opens partway through a drag, so whether it can accept is
    /// re-checked on every update; the operation itself is not.
    private func current() -> NSDragOperation {
        let operation = canAccept() ? operationForCurrentDrag : []
        onTargetChange(operation != [])
        return operation
    }

    private func chooseOperation(for sender: NSDraggingInfo) -> NSDragOperation {
        // A shelf row being dragged out must not land straight back on the shelf.
        // Drags from other apps have no source object in this process.
        guard sender.draggingSource == nil else { return [] }

        // Types only — never the data. Reading the URLs here asks the source to
        // produce them mid-drag; Finder answers at once, but a source that only
        // supplies them once the drag ends (the suspicion for the Dock) answers
        // with nothing, and the drop was refused before it could happen.
        let types = sender.draggingPasteboard.types ?? []
        guard types.contains(.fileURL) || types.contains(Self.filenamesType) else { return [] }

        // Copy reads best — the cursor gets a plus — then link, which is closest to
        // what the shelf actually does. Move only if it is all the source offers.
        let allowed = sender.draggingSourceOperationMask
        for operation in [NSDragOperation.copy, .link, .generic, .move] where allowed.contains(operation) {
            return operation
        }
        // Anything else bar delete — a private operation, say: take the first one
        // offered rather than refuse a file the shelf could hold.
        let rest = allowed.subtracting(.delete).rawValue
        return rest == 0 ? [] : NSDragOperation(rawValue: rest & (~rest &+ 1))
    }

    /// File URLs on a drag pasteboard, from the modern type or the old list of
    /// paths. Shared with the controller's safety net.
    static func fileURLs(on pasteboard: NSPasteboard) -> [URL] {
        let objects = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true])
        if let urls = objects as? [URL], !urls.isEmpty {
            return urls
        }
        if let paths = pasteboard.propertyList(forType: filenamesType) as? [String] {
            return paths.map { URL(fileURLWithPath: $0) }
        }
        return []
    }
}
