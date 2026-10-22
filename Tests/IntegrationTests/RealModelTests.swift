import Foundation
import Testing

private let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
private let binary = root.appendingPathComponent(".build/debug/afm").path

private func run(_ args: [String], stdin: String = "", cwd: URL? = nil, sessions: URL? = nil) throws -> (Int32, String, String) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: binary)
    p.arguments = args
    var e = ProcessInfo.processInfo.environment
    e.removeValue(forKey: "AFMUX_FAKE")
    if let sessions { e["AFMUX_SESSIONS_DIR"] = sessions.path }
    p.environment = e
    if let cwd { p.currentDirectoryURL = cwd }
    let out = Pipe(), err = Pipe(), input = Pipe()
    p.standardOutput = out
    p.standardError = err
    p.standardInput = input
    try p.run()
    input.fileHandleForWriting.write(Data(stdin.utf8))
    try input.fileHandleForWriting.close()
    let o = out.fileHandleForReading.readDataToEndOfFile(), r = err.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return (p.terminationStatus, String(decoding: o, as: UTF8.self), String(decoding: r, as: UTF8.self))
}

private let realModelWorks: Bool = {
    guard FileManager.default.isExecutableFile(atPath: binary) else { return false }
    return (try? run(["ask", "Reply with one word."], stdin: "hi").0) == 0
}()

private func tmp() -> URL {
    let u = FileManager.default.temporaryDirectory.appendingPathComponent("afm-int-" + UUID().uuidString)
    try! FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
    return u
}

@Suite(.enabled(if: realModelWorks, "on-device model not usable here"), .serialized)
struct RealModelTests {
    @Test func classifyReal() throws {
        let (code, out, err) = try run(["classify", "--labels", "positive,negative"], stdin: "I absolutely loved this film.")
        #expect(code == 0, "\(err)")
        let obj = try JSONSerialization.jsonObject(with: Data(out.utf8)) as! [String: Any]
        #expect(["positive", "negative"].contains(obj["label"] as! String))
    }

    @Test func extractWithFmFormatSchema() throws {
        let dir = tmp()
        let schema = dir.appendingPathComponent("s.json")
        try #"{"title":"Counts","type":"object","properties":{"errors":{"type":"integer"}},"required":["errors"],"x-order":["errors"],"additionalProperties":false}"#
            .write(to: schema, atomically: true, encoding: .utf8)
        let (code, out, err) = try run(["extract", "--schema", schema.path], stdin: "The build finished with 3 errors and 2 warnings.")
        #expect(code == 0, "\(err)")
        #expect(out == "{\"errors\":3}\n")
    }

    @Test func twoTurnSession() throws {
        let sessions = tmp()
        #expect(try run(["ask", "Remember the facts you are given.", "--session", "it"], stdin: "The project codename is BLUEHERON.", sessions: sessions).0 == 0)
        let (code, out, err) = try run(["ask", "What is the project codename? Reply with the codename only.", "--session", "it"], sessions: sessions)
        #expect(code == 0, "\(err)")
        #expect(out.uppercased().contains("BLUEHERON"))
    }

    @Test func toolsFindAString() throws {
        let dir = tmp()
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("docs"), withIntermediateDirectories: true)
        try "nothing here\n".write(to: dir.appendingPathComponent("docs/a.txt"), atomically: true, encoding: .utf8)
        try "the magic token is ZEBRA-42\n".write(to: dir.appendingPathComponent("docs/notes.txt"), atomically: true, encoding: .utf8)
        let (code, out, err) = try run(["ask", "--tools", "fs", "Which file under docs contains the text ZEBRA-42? Reply with the file name only."], cwd: dir)
        #expect(code == 0, "\(err)")
        #expect(out.contains("notes.txt"))
    }
}
