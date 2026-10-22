import Foundation
import Testing

@Suite struct SessionCLITests {
    func sessionFile(_ dir: URL, _ name: String) -> URL { dir.appendingPathComponent("sessions/\(name).json") }

    @Test func twoTurnAskSession() throws {
        let dir = makeTmp()
        let first = try afm(["ask", "Remember this.", "--session", "s1"], stdin: "The codename is BLUEHERON.", tmp: dir)
        #expect(first.code == 0, "\(first.err)")
        let second = try afm(["ask", "What is the codename?", "--session", "s1"], tty: true, fake: ["respond": ["text": "BLUEHERON"]], tmp: dir)
        #expect(second.code == 0, "\(second.err)")
        #expect(second.out == "BLUEHERON\n")
        let rec = second.records("respond").last!
        #expect(rec["instructions"] as? String == "Remember this.")
        #expect(rec["prompt"] as? String == "What is the codename?")
        #expect(rec["history"] as? Int == 2)
        let file = try JSONSerialization.jsonObject(with: Data(contentsOf: sessionFile(dir, "s1"))) as! [String: Any]
        #expect(file["turns"] as? Int == 2 && file["job"] as? String == "ask")
    }

    @Test func followUpAppendsStdinToQuestion() throws {
        let dir = makeTmp()
        try afm(["ask", "Read logs.", "--session", "s"], stdin: "log one", tmp: dir)
        let r = try afm(["ask", "And this?", "--session", "s"], stdin: "log two", tmp: dir)
        #expect(r.records("respond").last!["prompt"] as? String == "And this?\n\nlog two")
    }

    @Test func failedTurnLeavesFileUnchanged() throws {
        let dir = makeTmp()
        try afm(["ask", "x", "--session", "s"], stdin: "one", tmp: dir)
        let before = try Data(contentsOf: sessionFile(dir, "s"))
        let r = try afm(["ask", "y", "--session", "s"], stdin: "two", fake: ["respond": ["error": "guardrail"]], tmp: dir)
        #expect(r.code == 1)
        #expect(try Data(contentsOf: sessionFile(dir, "s")) == before)
    }

    @Test func presetSessionKeepsLabels() throws {
        let dir = makeTmp()
        let fake: [String: Any] = ["respond": ["text": #"{"label":"bug"}"#]]
        #expect(try afm(["classify", "--labels", "bug,feature", "--session", "c"], stdin: "crash", fake: fake, tmp: dir).code == 0)
        let r = try afm(["classify", "--session", "c"], stdin: "another crash", fake: fake, tmp: dir)
        #expect(r.code == 0, "\(r.err)")
        #expect(r.records("respond").last!["prompt"] as? String == "another crash")
        #expect(try afm(["classify", "--labels", "x,y", "--session", "c"], stdin: "z", fake: fake, tmp: dir).err.contains("was created with --labels bug,feature"))
    }

    @Test func mismatchesAreUsageErrors() throws {
        let dir = makeTmp()
        try afm(["ask", "x", "--session", "s"], stdin: "one", tmp: dir)
        #expect(try afm(["summarise", "--session", "s"], stdin: "two", tmp: dir).err.contains("session s is a ask session"))
        let g = try afm(["ask", "y", "--session", "s", "--guardrails", "default"], stdin: "two", tmp: dir)
        #expect(g.code == 2 && g.err.contains("was created with --guardrails permissive-content-transformations"))
        #expect(try afm(["ask", "y", "--session", "bad/name"], stdin: "two", tmp: dir).code == 2)
        #expect(try afm(["ask", "y", "--session", "s", "--chunk"], stdin: "two", tmp: dir).err.contains("--chunk is not allowed with --session"))
    }

    @Test func busySessionTimesOut() throws {
        let dir = makeTmp()
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("sessions"), withIntermediateDirectories: true)
        let fd = open(dir.appendingPathComponent("sessions/s.lock").path, O_CREAT | O_RDWR, 0o644)
        #expect(flock(fd, LOCK_EX) == 0)
        defer { close(fd) }
        let r = try afm(["ask", "x", "--session", "s", "--timeout", "0.3"], stdin: "one", tmp: dir)
        #expect(r.code == 1)
        #expect(r.err.contains("session s is busy"))
    }

    @Test func listAndRemove() throws {
        let dir = makeTmp()
        try afm(["ask", "x", "--session", "alpha"], stdin: "one", tmp: dir)
        let list = try afm(["sessions"], tmp: dir)
        #expect(list.code == 0)
        let fields = list.out.trimmingCharacters(in: .newlines).split(separator: "\t").map(String.init)
        #expect(fields[0] == "alpha" && fields[1] == "1" && Int(fields[2]) != nil && fields[3].contains("T"))
        #expect(try afm(["sessions", "rm", "alpha"], tmp: dir).code == 0)
        #expect(try afm(["sessions"], tmp: dir).out == "")
        let missing = try afm(["sessions", "rm", "alpha"], tmp: dir)
        #expect(missing.code == 2 && missing.err.contains("session alpha does not exist"))
    }
}
