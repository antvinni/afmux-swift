import Foundation
import Testing

@Suite struct CompactionCLITests {
    // Fake counts are ceil(bytes / 4). Turn 1 stores 200 bytes (50 tokens); turn 2's prompt is
    // "Q?" + 320 bytes (about 84 tokens with instructions), so 135 > 120 triggers compaction,
    // the rendered history plus compaction instructions (about 88) fits one summary call,
    // and the summary pair (13) brings the total to about 97.
    let first = String(repeating: "word ", count: 40)
    let second = String(repeating: "x", count: 320)
    let long = String(repeating: "word ", count: 80)

    @Test func compactsWhenHistoryOverflows() throws {
        let dir = makeTmp()
        #expect(try afm(["ask", "Keep notes.", "--session", "s"], stdin: first, tmp: dir).code == 0)
        let r = try afm(["ask", "Q?", "--session", "s", "--budget", "120"], stdin: second,
                        fake: ["respond": ["texts": ["SHORT SUMMARY", "ANSWER"]]], tmp: dir)
        #expect(r.code == 0, "\(r.err)")
        #expect(r.out == "ANSWER\n")
        #expect(r.err.contains("afm: session s compacted ("))
        let calls = Array(r.records("respond").dropFirst())  // record 0 is turn 1, in the same log
        #expect(calls[0]["instructions"] as? String == "Summarise this conversation for later reference. Keep facts, names, numbers, file paths and decisions. Omit pleasantries.")
        #expect(calls[0]["maxTokens"] as? Int == 40)
        #expect((calls[0]["prompt"] as? String)?.hasPrefix("User: ") == true)
        #expect(calls[1]["history"] as? Int == 2)
        let saved = try String(contentsOf: dir.appendingPathComponent("sessions/s.json"), encoding: .utf8)
        #expect(saved.contains("SHORT SUMMARY"))
    }

    @Test func failedSummaryLeavesSessionUnchanged() throws {
        let dir = makeTmp()
        try afm(["ask", "Keep notes.", "--session", "s"], stdin: first, tmp: dir)
        let before = try Data(contentsOf: dir.appendingPathComponent("sessions/s.json"))
        let r = try afm(["ask", "Q?", "--session", "s", "--budget", "120"], stdin: second,
                        fake: ["respond": ["error": "guardrail", "failOnCall": 1]], tmp: dir)
        #expect(r.code == 1)
        #expect(r.err.contains("compaction: "))
        #expect(try Data(contentsOf: dir.appendingPathComponent("sessions/s.json")) == before)
    }

    @Test func promptAloneOverBudgetIsExit6() throws {
        let dir = makeTmp()
        try afm(["ask", "Keep notes.", "--session", "s"], stdin: "short", tmp: dir)
        let r = try afm(["ask", "Q?", "--session", "s", "--budget", "40"], stdin: long, tmp: dir)
        #expect(r.code == 6, "\(r.err)")
        #expect(r.err.contains("budget is 40") && !r.err.contains("--chunk"))
    }

    @Test func tooLargeToCompact() throws {
        let dir = makeTmp()
        try afm(["ask", "Keep notes.", "--session", "s"], stdin: Array(repeating: long, count: 6).joined(separator: "\n\n"), tmp: dir)
        let r = try afm(["ask", "Q?", "--session", "s", "--budget", "120", "--max-chunks", "1"], tty: true, tmp: dir)
        #expect(r.code == 6, "\(r.err)")
        #expect(r.err.contains("session s is too large to compact"))
    }
}
