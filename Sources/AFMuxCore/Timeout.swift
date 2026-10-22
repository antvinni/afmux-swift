import Foundation

/// Run body, failing with afmux's "timed out after N s" if it takes longer than seconds.
public func withTimeout<T: Sendable>(_ seconds: Double, _ body: @escaping @Sendable () async throws -> T) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await body() }
        group.addTask {
            try await Task.sleep(nanoseconds: UInt64(min(seconds, 1e9) * 1_000_000_000))
            throw AfmError(.fail, "timed out after \(pyG(seconds)) s")
        }
        defer { group.cancelAll() }
        return try await group.next()!
    }
}
