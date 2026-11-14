import AppKit

/// Private SkyLight calls that keep the panel attached to the active Space —
/// including the Space a fullscreen app creates, where `.fullScreenAuxiliary`
/// alone is not always honoured.
///
/// Everything is loaded lazily and degrades to a no-op if Apple moves a symbol.
enum FullscreenSupport {
    private typealias ConnectionFn = @convention(c) () -> Int32
    private typealias ActiveSpaceFn = @convention(c) (Int32) -> UInt64
    private typealias AddToSpacesFn = @convention(c) (Int32, CFArray, CFArray) -> Int32

    private static let skyLight = "/System/Library/PrivateFrameworks/SkyLight.framework/Versions/A/SkyLight"
    private static let coreGraphics = "/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics"

    private static let connection: ConnectionFn? = load("CGSMainConnectionID", from: coreGraphics)
    private static let activeSpace: ActiveSpaceFn? = load("SLSGetActiveSpace", from: skyLight)
    private static let addToSpaces: AddToSpacesFn? = load("SLSAddWindowsToSpaces", from: skyLight)

    static var isAvailable: Bool {
        connection != nil && activeSpace != nil && addToSpaces != nil
    }

    /// Adds the window to whatever Space is frontmost right now.
    static func attach(_ window: NSWindow) {
        guard let connection, let activeSpace, let addToSpaces else { return }
        let cid = connection()
        let space = activeSpace(cid)
        guard space != 0 else { return }
        _ = addToSpaces(
            cid,
            [window.windowNumber] as CFArray,
            [NSNumber(value: space)] as CFArray
        )
    }

    private static func load<T>(_ name: String, from path: String) -> T? {
        guard let handle = dlopen(path, RTLD_NOW), let symbol = dlsym(handle, name) else {
            return nil
        }
        return unsafeBitCast(symbol, to: T.self)
    }
}
