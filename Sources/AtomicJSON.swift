import Foundation

/// Atomic `Codable` JSON with restrictive permissions, for the two on-disk stores.
///
/// Same five lines in both: encode, write a temp file, chmod it, swap it in. The
/// order matters and is the reason this is a helper rather than a one-liner at
/// each site — the permissions are set on the **temp file before the swap**.
/// Creating the real file and fixing its mode afterwards leaves a window where
/// the clipboard history is world-readable.
enum AtomicJSON {
    /// Returns whether the write landed. Failure is not worth surfacing: the
    /// in-memory state is still correct, and the next mutation retries.
    @discardableResult
    static func write<T: Encodable>(_ value: T, to url: URL, permissions: Int = 0o600) -> Bool {
        guard let data = try? JSONEncoder().encode(value) else { return false }

        let temp = url.appendingPathExtension("tmp")
        do {
            try data.write(to: temp, options: .atomic)
            try FileManager.default.setAttributes(
                [.posixPermissions: permissions], ofItemAtPath: temp.path
            )
            _ = try FileManager.default.replaceItemAt(url, withItemAt: temp)
            return true
        } catch {
            try? FileManager.default.removeItem(at: temp)
            return false
        }
    }
}
