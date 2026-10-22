import Foundation
import Testing

let packageRoot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
let afmPath = packageRoot.appendingPathComponent(".build/debug/afm").path

struct Run {
    var code: Int32
    var out: String
    var err: String
    var tmp: URL

    var log: [[String: Any]] {
        guard let text = try? String(contentsOf: tmp.appendingPathComponent("log.jsonl"), encoding: .utf8) else { return [] }
        return text.split(separator: "\n").compactMap {
            try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any]
        }
    }

    func records(_ kind: String) -> [[String: Any]] { log.filter { $0["kind"] as? String == kind } }
    var kinds: [String] { log.compactMap { $0["kind"] as? String } }
}

func makeTmp() -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("afm-test-" + UUID().uuidString)
    try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

/// Run the built afm in fake mode. fake is the AFMUX_FAKE script; "log" is filled in.
@discardableResult
func afm(_ args: [String], stdin: String = "", stdinData: Data? = nil, tty: Bool = false,
         fake: [String: Any] = [:], env: [String: String] = [:], tmp: URL? = nil) throws -> Run {
    precondition(FileManager.default.isExecutableFile(atPath: afmPath), "run swift build first")
    let dir = tmp ?? makeTmp()
    var script = fake
    script["log"] = dir.appendingPathComponent("log.jsonl").path
    let scriptURL = dir.appendingPathComponent("fake.json")
    try JSONSerialization.data(withJSONObject: script).write(to: scriptURL)
    let p = Process()
    p.executableURL = URL(fileURLWithPath: afmPath)
    p.arguments = args
    var e = ProcessInfo.processInfo.environment
    e["AFMUX_FAKE"] = scriptURL.path
    e["AFMUX_SESSIONS_DIR"] = dir.appendingPathComponent("sessions").path
    e.merge(env) { $1 }
    p.environment = e
    p.currentDirectoryURL = dir
    let outPipe = Pipe(), errPipe = Pipe(), inPipe = Pipe()
    p.standardOutput = outPipe
    p.standardError = errPipe
    var master: Int32 = -1, slave: Int32 = -1
    if tty {
        openpty(&master, &slave, nil, nil, nil)
        p.standardInput = FileHandle(fileDescriptor: slave, closeOnDealloc: false)
    } else {
        p.standardInput = inPipe
    }
    try p.run()
    if tty {
        close(slave)
    } else {
        inPipe.fileHandleForWriting.write(stdinData ?? Data(stdin.utf8))
        try inPipe.fileHandleForWriting.close()
    }
    let out = outPipe.fileHandleForReading.readDataToEndOfFile()
    let err = errPipe.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    if tty { close(master) }
    return Run(code: p.terminationStatus, out: String(decoding: out, as: UTF8.self),
               err: String(decoding: err, as: UTF8.self), tmp: dir)
}

func goodSchema(_ dir: URL, name: String = "s.json") throws -> String {
    let path = dir.appendingPathComponent(name).path
    let obj: [String: Any] = ["title": "T", "type": "object", "properties": ["a": ["type": "integer"]],
                              "required": ["a"], "x-order": ["a"], "additionalProperties": false]
    try JSONSerialization.data(withJSONObject: obj).write(to: URL(fileURLWithPath: path))
    return path
}

let p100 = String(repeating: "P", count: 100)
