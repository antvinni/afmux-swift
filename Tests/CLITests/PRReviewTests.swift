import Foundation
import Testing

/// Regressions from the PR #1 code review.
@Suite struct PRReviewTests {
    /// A tools file with one command tool "run" that takes no arguments.
    func tool(_ dir: URL, _ command: [String]) throws -> String {
        let spec: [String: Any] = ["tools": [["name": "run", "description": "run it", "command": command]]]
        let file = dir.appendingPathComponent("tools.json")
        try JSONSerialization.data(withJSONObject: spec).write(to: file)
        return file.path
    }

    let runCall: [String: Any] = ["respond": ["toolCalls": [["name": "run", "arguments": "{}"]]]]

    @Test func timeoutCutsOffARunningTool() throws {
        let dir = makeTmp()
        let tools = try tool(dir, ["/bin/sh", "-c", "sleep 8"])
        let start = Date()
        let r = try afm(["ask", "--tools-file", tools, "--timeout", "1", "go"], fake: runCall, tmp: dir)
        #expect(r.code == 1, "\(r.err)")
        #expect(r.err.contains("timed out after 1 s"))
        #expect(Date().timeIntervalSince(start) < 6)  // about 1 s alone; the tool sleeps 8
    }

    @Test func childOutsideTheGroupDoesNotHangAfm() throws {
        let dir = makeTmp()
        let tools = try tool(dir, ["/bin/sh", "-c", "set -m; sleep 12 & echo started"])
        let start = Date()
        let r = try afm(["ask", "--tools-file", tools, "--tool-timeout", "1", "--timeout", "30", "go"], fake: runCall, tmp: dir)
        #expect(r.code == 0, "\(r.err)")
        #expect(Date().timeIntervalSince(start) < 8)  // about 0.6 s alone; the stray child sleeps 12
        let out = (r.records("toolOutputs").first?["outputs"] as? [String])?.first ?? ""
        #expect(out.contains("started"))
    }

    @Test func toolsGetDefaultSignalDispositions() throws {
        let dir = makeTmp()
        let tools = try tool(dir, ["/bin/sh", "-c", "kill -TERM $$; echo survived"])
        let r = try afm(["ask", "--tools-file", tools, "go"], fake: runCall, tmp: dir)
        #expect(r.code == 0, "\(r.err)")
        let out = (r.records("toolOutputs").first?["outputs"] as? [String])?.first ?? ""
        #expect(out.hasPrefix("exit 143"), "\(out)")
        #expect(!out.contains("survived"))
    }

    @Test func toolsInheritOnlyStandardDescriptors() throws {
        let dir = makeTmp()
        #expect(try afm(["ask", "x", "--session", "s"], stdin: "one", tmp: dir).code == 0)
        let tools = try tool(dir, ["/bin/sh", "-c", "for f in 3 4 5 6 7 8 9 10 11 12; do [ -e /dev/fd/$f ] && echo open $f; done; true"])
        let r = try afm(["ask", "go", "--session", "s", "--tools-file", tools], fake: runCall, tmp: dir)
        #expect(r.code == 0, "\(r.err)")
        let out = (r.records("toolOutputs").first?["outputs"] as? [String])?.first ?? ""
        #expect(!out.contains("open "), "\(out)")
    }

    @Test func sessionsRmWaitsForTheLock() throws {
        let dir = makeTmp()
        #expect(try afm(["ask", "x", "--session", "s"], stdin: "one", tmp: dir).code == 0)
        let fd = open(dir.appendingPathComponent("sessions/s.lock").path, O_RDWR)
        #expect(flock(fd, LOCK_EX) == 0)
        defer { close(fd) }
        let r = try afm(["sessions", "rm", "s"], tmp: dir)  // waits up to 2 s
        #expect(r.code == 1, "\(r.err)")
        #expect(r.err.contains("session s is busy"))
        #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("sessions/s.json").path))
    }

    @Test func helpWinsOverLaterArguments() throws {
        for args in [["-h", "--bogus"], ["-h", "--budget", "x"], ["--help", "extra", "more", "args"]] {
            let r = try afm(args)
            #expect(r.code == 0, "\(args): \(r.err)")
            #expect(r.out.hasPrefix("usage: afm"))
        }
        #expect(try afm(["--budget", "x", "-h"]).code == 2)
    }

    @Test func concurrentTurnsSerialiseUnderTheLock() throws {
        let dir = makeTmp()
        #expect(try afm(["ask", "x", "--session", "s"], stdin: "one", tmp: dir).code == 0)
        let fake: [String: Any] = ["respond": ["delay": 0.5]]
        let results = UnsafeMutableBufferPointer<Int32>.allocate(capacity: 2)
        defer { results.deallocate() }
        DispatchQueue.concurrentPerform(iterations: 2) { k in
            let sub = dir.appendingPathComponent("run\(k)")
            try! FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
            results[k] = (try? afm(["ask", "turn \(k)", "--session", "s"], stdin: "", fake: fake,
                                   env: ["AFMUX_SESSIONS_DIR": dir.appendingPathComponent("sessions").path], tmp: sub))?.code ?? -1
        }
        #expect(Array(results) == [0, 0])
        let file = try JSONSerialization.jsonObject(with: Data(contentsOf: dir.appendingPathComponent("sessions/s.json"))) as! [String: Any]
        #expect(file["turns"] as? Int == 3)
    }

    @Test func lockIsReleasedAfterSignal() throws {
        let dir = makeTmp()
        #expect(try afm(["ask", "x", "--session", "s"], stdin: "one", tmp: dir).code == 0)
        var script: [String: Any] = ["respond": ["delay": 10]]
        script["log"] = dir.appendingPathComponent("log.jsonl").path
        try JSONSerialization.data(withJSONObject: script).write(to: dir.appendingPathComponent("slow.json"))
        let p = Process()
        p.executableURL = URL(fileURLWithPath: afmPath)
        p.arguments = ["ask", "slow", "--session", "s"]
        var e = ProcessInfo.processInfo.environment
        e["AFMUX_FAKE"] = dir.appendingPathComponent("slow.json").path
        e["AFMUX_SESSIONS_DIR"] = dir.appendingPathComponent("sessions").path
        p.environment = e
        p.standardInput = FileHandle.nullDevice
        p.standardOutput = FileHandle.nullDevice
        let err = Pipe()
        p.standardError = err
        try p.run()
        for _ in 0..<100 where Run(code: 0, out: "", err: "", tmp: dir).records("respond").count < 2 { usleep(100_000) }
        p.terminate()
        p.waitUntilExit()
        #expect(p.terminationStatus == 1)
        #expect(String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).contains("interrupted by signal 15"))
        let r = try afm(["ask", "after", "--session", "s", "--timeout", "1"], stdin: "", tmp: dir)
        #expect(r.code == 0, "\(r.err)")
    }

    @Test func staleToolDefinitionsAreNotKept() throws {
        let dir = makeTmp()
        #expect(try afm(["ask", "x", "--session", "s", "--tools", "fs"], stdin: "one", tmp: dir).code == 0)
        let path = dir.appendingPathComponent("sessions/s.json")
        #expect(try String(contentsOf: path, encoding: .utf8).contains("read_file"))
        #expect(try afm(["ask", "y", "--session", "s"], stdin: "two", tmp: dir).code == 0)
        #expect(!(try String(contentsOf: path, encoding: .utf8).contains("read_file")))
    }

    @Test func compactionFoldsTheKeptTurnWhenNeeded() throws {
        // Fake counts are ceil(bytes / 4). Turn 3 (fixed 44) + history 54 = 98 > 90: the first
        // summary leaves the 51-token turn 2 verbatim (106 > 90), so it is folded in and the
        // fold's rendered text is summarised in two pieces.
        let dir = makeTmp()
        #expect(try afm(["ask", "Keep notes.", "--session", "s"], stdin: "a", tmp: dir).code == 0)
        #expect(try afm(["ask", "Q2", "--session", "s"], stdin: String(repeating: "b", count: 200), tmp: dir).code == 0)
        let r = try afm(["ask", "Q3?", "--session", "s", "--budget", "90"], stdin: String(repeating: "c", count: 160),
                        fake: ["respond": ["texts": ["S1", "S2", "S3", "ANSWER"]]], tmp: dir)
        #expect(r.code == 0, "\(r.err)")
        #expect(r.out == "ANSWER\n")
        #expect(r.err.contains("compacted ("))
        #expect(Array(r.records("respond").dropFirst(2)).count == 4)
        let saved = try String(contentsOf: dir.appendingPathComponent("sessions/s.json"), encoding: .utf8)
        #expect(saved.contains("S2\\nS3") && !saved.contains("bbbb"))
    }
}
