import Foundation
import FoundationModels

public struct SessionFile: Codable, Sendable {
    public var version = 1
    public var job: String
    public var labels: [String]?
    public var guardrails: String
    public var useCase: String
    public var turns: Int
    public var tokens: Int
    public var modified: String
    public var transcript: Transcript
}

public struct SessionStore: Sendable {
    public let dir: URL

    public init(env: [String: String]) {
        if let override = env["AFMUX_SESSIONS_DIR"] {
            dir = URL(fileURLWithPath: override)
        } else {
            dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/afmux/sessions")
        }
    }

    public static func validate(_ name: String) throws {
        guard name.range(of: "^[A-Za-z0-9._-]+$", options: .regularExpression) != nil else {
            throw AfmError(.usage, "session name \(pyRepr(name)) must match [A-Za-z0-9._-]+")
        }
    }

    func url(_ name: String) -> URL { dir.appendingPathComponent(name + ".json") }

    public func load(_ name: String) throws -> SessionFile? {
        guard let data = FileManager.default.contents(atPath: url(name).path) else { return nil }
        do {
            return try JSONDecoder().decode(SessionFile.self, from: data)
        } catch {
            throw AfmError(.model, "session \(name) cannot be read (\(error.localizedDescription))")
        }
    }

    /// Write to a temporary file in the same directory, then rename over the session.
    public func save(_ name: String, _ file: SessionFile) throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let tmp = dir.appendingPathComponent(".\(name).\(getpid()).tmp")
        TempFiles.shared.add(tmp.path)
        defer { TempFiles.shared.remove(tmp.path) }
        try JSONEncoder().encode(file).write(to: tmp)
        if rename(tmp.path, url(name).path) != 0 {
            let reason = String(cString: strerror(errno))
            unlink(tmp.path)
            throw AfmError(.model, "cannot save session \(name): \(reason)")
        }
    }

    /// Exclusive flock on NAME.lock, retried every 50 ms until timeout.
    public func lock(_ name: String, timeout: Double) throws -> Int32 {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let fd = open(dir.appendingPathComponent(name + ".lock").path, O_CREAT | O_RDWR | O_CLOEXEC, 0o644)
        guard fd >= 0 else { throw AfmError(.model, "cannot lock session \(name)") }
        let deadline = Date().addingTimeInterval(timeout)
        while flock(fd, LOCK_EX | LOCK_NB) != 0 {
            if Date() >= deadline {
                close(fd)
                throw AfmError(.model, "session \(name) is busy")
            }
            usleep(50_000)
        }
        return fd
    }

    public func unlock(_ fd: Int32) {
        flock(fd, LOCK_UN)
        close(fd)
    }

    /// name<TAB>turns<TAB>tokens<TAB>modified, one line per session, sorted by name.
    public func listing() -> String {
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [])
            .filter { $0.hasSuffix(".json") && !$0.hasPrefix(".") }
            .map { String($0.dropLast(5)) }
            .sorted()
        return names.compactMap { name -> String? in
            guard let file = try? load(name) else { return nil }
            return "\(name)\t\(file.turns)\t\(file.tokens)\t\(file.modified)\n"
        }.joined()
    }

    /// Delete a session under its lock. The lock file stays: unlinking it would let a waiting
    /// turn and a new one lock different inodes at the same time.
    public func remove(_ name: String) throws {
        guard FileManager.default.fileExists(atPath: url(name).path) else {
            throw AfmError(.usage, "session \(name) does not exist")
        }
        let fd = try lock(name, timeout: 2)
        defer { unlock(fd) }
        guard FileManager.default.fileExists(atPath: url(name).path) else {
            throw AfmError(.usage, "session \(name) does not exist")
        }
        try FileManager.default.removeItem(at: url(name))
    }
}

public func sessionsCommand(_ args: [String], io: IO) throws -> Int32 {
    let store = SessionStore(env: io.env)
    if args.isEmpty {
        io.out(store.listing())
        return 0
    }
    if args.count == 2 && args[0] == "rm" {
        try SessionStore.validate(args[1])
        try store.remove(args[1])
        return 0
    }
    throw AfmError(.usage, "usage: afm sessions | afm sessions rm NAME")
}
