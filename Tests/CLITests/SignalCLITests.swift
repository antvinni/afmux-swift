import Foundation
import Testing

/// Start afm in fake mode without waiting, for signal tests.
private func start(_ args: [String], fake: [String: Any], dir: URL) throws -> (Process, Pipe, Pipe) {
    var script = fake
    script["log"] = dir.appendingPathComponent("log.jsonl").path
    try JSONSerialization.data(withJSONObject: script).write(to: dir.appendingPathComponent("fake.json"))
    let p = Process()
    p.executableURL = URL(fileURLWithPath: afmPath)
    p.arguments = args
    var e = ProcessInfo.processInfo.environment
    e["AFMUX_FAKE"] = dir.appendingPathComponent("fake.json").path
    e["AFMUX_SESSIONS_DIR"] = dir.appendingPathComponent("sessions").path
    p.environment = e
    p.currentDirectoryURL = dir
    let out = Pipe(), err = Pipe(), input = Pipe()
    p.standardOutput = out
    p.standardError = err
    p.standardInput = input
    try p.run()
    input.fileHandleForWriting.write(Data("hello".utf8))
    try input.fileHandleForWriting.close()
    return (p, out, err)
}

private func waitFor(_ condition: () -> Bool) {
    for _ in 0..<100 where !condition() { usleep(100_000) }
}

@Suite struct SignalCLITests {
    @Test func sigtermDuringGenerationExits1() throws {
        let dir = makeTmp()
        let (p, out, err) = try start(["classify", "--labels", "a,b"], fake: ["respond": ["delay": 10]], dir: dir)
        waitFor { Run(code: 0, out: "", err: "", tmp: dir).records("respond").count > 0 }
        p.terminate()
        p.waitUntilExit()
        #expect(p.terminationStatus == 1)
        #expect(out.fileHandleForReading.readDataToEndOfFile().isEmpty)
        #expect(String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).contains("interrupted by signal 15"))
    }

    @Test func sigtermKillsToolProcessGroupAndKeepsSession() throws {
        let dir = makeTmp()
        let pidFile = dir.appendingPathComponent("child.pid").path
        let tools = dir.appendingPathComponent("tools.json")
        try #"{"tools":[{"name":"slow","description":"slow","arguments":{"type":"object","properties":{"f":{"type":"string"}},"required":["f"]},"command":["/bin/sh","-c","sleep 30 & echo $! > \"$1\"; wait","_","{f}"]}]}"#
            .write(to: tools, atomically: true, encoding: .utf8)
        #expect(try afm(["ask", "x", "--session", "s"], stdin: "one", tmp: dir).code == 0)
        let before = try Data(contentsOf: dir.appendingPathComponent("sessions/s.json"))
        let call = ["name": "slow", "arguments": "{\"f\":\"\(pidFile)\"}"]
        let (p, _, _) = try start(["ask", "go", "--session", "s", "--tools-file", tools.path, "--tool-timeout", "60"],
                                  fake: ["respond": ["toolCalls": [call]]], dir: dir)
        waitFor { FileManager.default.fileExists(atPath: pidFile) && ((try? String(contentsOfFile: pidFile, encoding: .utf8)) ?? "").hasSuffix("\n") }
        let child = pid_t(try String(contentsOfFile: pidFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines))!
        p.terminate()
        p.waitUntilExit()
        #expect(p.terminationStatus == 1)
        waitFor { kill(child, 0) != 0 }
        #expect(kill(child, 0) != 0)
        #expect(try Data(contentsOf: dir.appendingPathComponent("sessions/s.json")) == before)
    }
}
