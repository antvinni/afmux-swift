import Darwin
import Foundation

public enum Signals {
    nonisolated(unsafe) private static var sources: [DispatchSourceSignal] = []

    /// SIGINT, SIGTERM, SIGHUP: kill tool process groups, remove temp files, exit 1.
    /// The session lock is released by process exit and the session file is only ever renamed into place.
    public static func install() {
        for sig in [SIGINT, SIGTERM, SIGHUP] {
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .global())
            source.setEventHandler {
                ProcessGroups.shared.killAll()
                TempFiles.shared.removeAll()
                FileHandle.standardError.write(Data("afm: interrupted by signal \(sig)\n".utf8))
                _exit(1)
            }
            source.resume()
            sources.append(source)
        }
    }
}
