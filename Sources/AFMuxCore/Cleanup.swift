import Foundation

/// Temporary files to delete if a signal ends the process.
public final class TempFiles: @unchecked Sendable {
    public static let shared = TempFiles()
    private let lock = NSLock()
    private var paths = Set<String>()

    func add(_ path: String) { lock.withLock { _ = paths.insert(path) } }
    func remove(_ path: String) { lock.withLock { _ = paths.remove(path) } }

    public func removeAll() {
        lock.withLock {
            for p in paths { unlink(p) }
            paths.removeAll()
        }
    }
}
