import AFMuxCore
import Foundation

Signals.install()

let environment = ProcessInfo.processInfo.environment
let backend: any Backend
if let path = environment["AFMUX_FAKE"] {
    do {
        backend = try FakeBackend(scriptPath: path)
    } catch {
        FileHandle.standardError.write(Data("afm: cannot load AFMUX_FAKE script: \(error)\n".utf8))
        exit(2)
    }
} else {
    backend = SystemBackend()
}
exit(await runAfm(Array(CommandLine.arguments.dropFirst()), io: .standard(), backend: backend))
