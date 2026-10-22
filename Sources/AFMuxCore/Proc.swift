import Darwin
import Foundation

public struct ProcResult: Sendable {
    public var status: Int32
    public var stdout: String
    public var stderr: String
    public var timedOut: Bool
}

/// Process groups of running tools, so a signal handler or an expired --timeout can kill them all.
public final class ProcessGroups: @unchecked Sendable {
    public static let shared = ProcessGroups()
    private let lock = NSLock()
    private var groups = Set<pid_t>()

    /// Spawn under the lock, so a signal handler calling killAll() never misses a just-started group.
    func spawn(_ start: () -> pid_t?) -> pid_t? {
        lock.withLock {
            let pid = start()
            if let pid { groups.insert(pid) }
            return pid
        }
    }

    func remove(_ group: pid_t) { lock.withLock { _ = groups.remove(group) } }

    public func killAll() {
        lock.withLock { for g in groups { kill(-g, SIGKILL) } }
    }
}

private final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    func set() { lock.withLock { value = true } }
    var isSet: Bool { lock.withLock { value } }
}

/// Run argv (PATH lookup) in its own process group with stdin /dev/null, default signal
/// dispositions and only fds 0-2. On timeout or task cancellation the group is killed.
public func runProcess(_ argv: [String], timeout: Double) async -> ProcResult {
    let cancelled = Flag()
    return await withTaskCancellationHandler {
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                continuation.resume(returning: runProcessSync(argv, timeout: timeout, cancelled: cancelled))
            }
        }
    } onCancel: {
        cancelled.set()
    }
}

/// Seconds to keep reading after the child exits, for output still held by its descendants.
private let drainGrace = 0.5

private func runProcessSync(_ argv: [String], timeout: Double, cancelled: Flag) -> ProcResult {
    var outPipe: [Int32] = [0, 0]
    var errPipe: [Int32] = [0, 0]
    pipe(&outPipe)
    pipe(&errPipe)
    var actions: posix_spawn_file_actions_t?
    posix_spawn_file_actions_init(&actions)
    posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
    posix_spawn_file_actions_adddup2(&actions, outPipe[1], 1)
    posix_spawn_file_actions_adddup2(&actions, errPipe[1], 2)
    var attr: posix_spawnattr_t?
    posix_spawnattr_init(&attr)
    // Own group; afm ignores INT/TERM/HUP (Signals), so reset them; the spawning GCD thread
    // blocks most signals, so clear the mask; close every fd above 2.
    posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_CLOEXEC_DEFAULT))
    posix_spawnattr_setpgroup(&attr, 0)
    var defaults = sigset_t()
    sigemptyset(&defaults)
    for sig in [SIGINT, SIGTERM, SIGHUP] { sigaddset(&defaults, sig) }
    posix_spawnattr_setsigdefault(&attr, &defaults)
    var emptyMask = sigset_t()
    sigemptyset(&emptyMask)
    posix_spawnattr_setsigmask(&attr, &emptyMask)
    let cargs: [UnsafeMutablePointer<CChar>?] = argv.map { strdup($0) } + [nil]
    var rc: Int32 = 0
    let spawned = ProcessGroups.shared.spawn {
        var pid: pid_t = 0
        rc = posix_spawnp(&pid, argv[0], &actions, &attr, cargs, environ)
        return rc == 0 ? pid : nil
    }
    cargs.forEach { free($0) }
    posix_spawn_file_actions_destroy(&actions)
    posix_spawnattr_destroy(&attr)
    close(outPipe[1])
    close(errPipe[1])
    guard let pid = spawned else {
        close(outPipe[0])
        close(errPipe[0])
        return ProcResult(status: 127, stdout: "", stderr: "cannot run \(argv[0]): \(String(cString: strerror(rc)))\n", timedOut: false)
    }

    var data = [Data(), Data()]
    var fds = [outPipe[0], errPipe[0]]
    var open = [true, true]
    var status: Int32 = 0
    var exited = false
    var exitedAt = Date.distantFuture
    var timedOut = false
    let deadline = Date().addingTimeInterval(timeout)
    var buffer = [UInt8](repeating: 0, count: 65536)
    while true {
        if !exited, waitpid(pid, &status, WNOHANG) == pid {
            exited = true
            exitedAt = Date()
        }
        if exited && !open.contains(true) { break }
        let now = Date()
        if cancelled.isSet || (!exited && now >= deadline) {
            timedOut = !cancelled.isSet
            kill(-pid, SIGKILL)
            if !exited { waitpid(pid, &status, 0) }
            exited = true
            break
        }
        // Descendants that left the group can hold the pipes open: stop reading shortly after exit.
        if exited && now >= min(deadline, exitedAt.addingTimeInterval(drainGrace)) { break }
        var polls = (0..<2).filter { open[$0] }.map { pollfd(fd: fds[$0], events: Int16(POLLIN), revents: 0) }
        if polls.isEmpty {
            usleep(10_000)
            continue
        }
        if poll(&polls, nfds_t(polls.count), 50) <= 0 { continue }
        for p in polls where p.revents != 0 {
            let k = fds.firstIndex(of: p.fd)!
            let n = read(p.fd, &buffer, buffer.count)
            if n > 0 { data[k].append(buffer, count: n) } else { open[k] = false }
        }
    }
    for k in 0..<2 { close(fds[k]) }
    kill(-pid, SIGKILL)  // stragglers still in the group
    ProcessGroups.shared.remove(pid)
    let code = (status & 0x7f) == 0 ? (status >> 8) & 0xff : 128 + (status & 0x7f)
    return ProcResult(status: code, stdout: String(decoding: data[0], as: UTF8.self),
                      stderr: String(decoding: data[1], as: UTF8.self), timedOut: timedOut)
}
