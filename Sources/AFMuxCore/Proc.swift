import Darwin
import Foundation

public struct ProcResult: Sendable {
    public var status: Int32
    public var stdout: String
    public var stderr: String
    public var timedOut: Bool
}

/// Process groups of running tools, so a signal handler can kill them all.
public final class ProcessGroups: @unchecked Sendable {
    public static let shared = ProcessGroups()
    private let lock = NSLock()
    private var groups = Set<pid_t>()

    func add(_ group: pid_t) { lock.withLock { _ = groups.insert(group) } }
    func remove(_ group: pid_t) { lock.withLock { _ = groups.remove(group) } }

    public func killAll() {
        lock.withLock { for g in groups { kill(-g, SIGKILL) } }
    }
}

/// Run argv (PATH lookup) in its own process group, stdin /dev/null; on timeout kill the group.
public func runProcess(_ argv: [String], timeout: Double) async -> ProcResult {
    await withCheckedContinuation { continuation in
        DispatchQueue.global().async {
            continuation.resume(returning: runProcessSync(argv, timeout: timeout))
        }
    }
}

private final class Box<T>: @unchecked Sendable {
    var value: T
    init(_ value: T) { self.value = value }
}

private func readAll(_ fd: Int32) -> Data {
    var data = Data()
    var buffer = [UInt8](repeating: 0, count: 65536)
    while true {
        let n = read(fd, &buffer, buffer.count)
        if n <= 0 { break }
        data.append(buffer, count: n)
    }
    close(fd)
    return data
}

private func runProcessSync(_ argv: [String], timeout: Double) -> ProcResult {
    var outPipe: [Int32] = [0, 0]
    var errPipe: [Int32] = [0, 0]
    pipe(&outPipe)
    pipe(&errPipe)
    var actions: posix_spawn_file_actions_t?
    posix_spawn_file_actions_init(&actions)
    posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
    posix_spawn_file_actions_adddup2(&actions, outPipe[1], 1)
    posix_spawn_file_actions_adddup2(&actions, errPipe[1], 2)
    for fd in outPipe + errPipe { posix_spawn_file_actions_addclose(&actions, fd) }
    var attr: posix_spawnattr_t?
    posix_spawnattr_init(&attr)
    posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETPGROUP))
    posix_spawnattr_setpgroup(&attr, 0)
    var pid: pid_t = 0
    let cargs: [UnsafeMutablePointer<CChar>?] = argv.map { strdup($0) } + [nil]
    let rc = posix_spawnp(&pid, argv[0], &actions, &attr, cargs, environ)
    cargs.forEach { free($0) }
    posix_spawn_file_actions_destroy(&actions)
    posix_spawnattr_destroy(&attr)
    close(outPipe[1])
    close(errPipe[1])
    if rc != 0 {
        close(outPipe[0])
        close(errPipe[0])
        return ProcResult(status: 127, stdout: "", stderr: "cannot run \(argv[0]): \(String(cString: strerror(rc)))\n", timedOut: false)
    }
    ProcessGroups.shared.add(pid)
    let out = Box(Data()), err = Box(Data()), status = Box(Int32(0))
    let readers = DispatchGroup()
    readers.enter()
    DispatchQueue.global().async { out.value = readAll(outPipe[0]); readers.leave() }
    readers.enter()
    DispatchQueue.global().async { err.value = readAll(errPipe[0]); readers.leave() }
    let exited = DispatchSemaphore(value: 0)
    DispatchQueue.global().async {
        var s: Int32 = 0
        waitpid(pid, &s, 0)
        status.value = s
        exited.signal()
    }
    var timedOut = false
    if exited.wait(timeout: .now() + timeout) == .timedOut {
        timedOut = true
        kill(-pid, SIGKILL)
        exited.wait()
    }
    // Leftover members of the group (background children) would hold the pipes open.
    kill(-pid, SIGKILL)
    readers.wait()
    ProcessGroups.shared.remove(pid)
    let s = status.value
    let code = (s & 0x7f) == 0 ? (s >> 8) & 0xff : 128 + (s & 0x7f)
    return ProcResult(status: code, stdout: String(decoding: out.value, as: UTF8.self),
                      stderr: String(decoding: err.value, as: UTF8.self), timedOut: timedOut)
}
