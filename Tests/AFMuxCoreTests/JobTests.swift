import Foundation
import Testing
@testable import AFMuxCore

struct StubInput: InputSource {
    var isTerminal = false
    var data = Data()
    func readAll() -> Data { data }
}

private func jobError(_ argv: [String]) -> String? {
    do { _ = try resolveJob(try parseArgs(argv)); return nil } catch let e as AfmError {
        #expect(e.code == .usage)
        return e.message
    } catch { return "\(error)" }
}

@Test func usageMessagesMatchAfmux() {
    #expect(jobError([]) == usageLine)
    #expect(jobError(["ask"]) == "ask needs instructions as its argument")
    #expect(jobError(["summarise", "extra"]) == "unexpected argument 'extra' (only ask takes instructions)")
    #expect(jobError(["nosuch"]) == "unknown preset 'nosuch'; run afm --list")
    #expect(jobError(["classify"]) == "classify needs --labels a,b,c")
    #expect(jobError(["classify", "--labels", "a,b", "--schema", "x.json"]) == "--schema is not allowed with classify (its schema is generated)")
    #expect(jobError(["summarise", "--labels", "a"]) == "--labels is only for classify")
    #expect(jobError(["extract"]) == "extract needs --schema FILE")
    #expect(jobError(["commit-msg", "--chunk"]) == "--chunk is not allowed with commit-msg; pipe a smaller diff")
    #expect(jobError(["extract", "--schema", "/nonexistent.json"]) == "schema file not found: /nonexistent.json")
}

@Test func labelRules() throws {
    #expect(try parseLabels("bug, feature ,question") == ["bug", "feature", "question"])
    #expect(throws: AfmError(.usage, "empty label in --labels (labels are comma-separated and cannot contain commas)")) { try parseLabels("a,,b") }
    #expect(throws: AfmError(.usage, "duplicate label in --labels")) { try parseLabels("a,b,a") }
    #expect(throws: AfmError(.usage, "label 'b\"c': quotes and backslashes are not allowed in labels")) { try parseLabels("a,b\"c") }
}

@Test func classifySubstitutesLabels() throws {
    let job = try resolveJob(try parseArgs(["classify", "--labels", "bug,feature"]))
    #expect(job.instructions.contains("labels: bug, feature."))
    #expect(job.labels == ["bug", "feature"])
}

@Test func schemaFileMustBeJSONObject() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let bad = dir.appendingPathComponent("bad.json")
    try "{not json".write(to: bad, atomically: true, encoding: .utf8)
    #expect(jobError(["extract", "--schema", bad.path])?.hasPrefix("schema file \(bad.path) is not valid JSON (") == true)
    let list = dir.appendingPathComponent("list.json")
    try "[1]".write(to: list, atomically: true, encoding: .utf8)
    #expect(jobError(["extract", "--schema", list.path]) == "schema file \(list.path) must be a JSON object")
}

@Test func newCombos() throws {
    #expect(throws: AfmError(.usage, "--chunk is not allowed with --session")) { try checkNewCombos(try parseArgs(["ask", "x", "--chunk", "--session", "s"])) }
    #expect(throws: AfmError(.usage, "--chunk is not allowed with tools")) { try checkNewCombos(try parseArgs(["ask", "x", "--chunk", "--tools", "fs"])) }
}

@Test func inputRules() throws {
    #expect(throws: AfmError(.usage, "afm reads its input from stdin; pipe or redirect it")) { try readInput(StubInput(isTerminal: true)) }
    #expect(throws: AfmError(.usage, "input is empty")) { try readInput(StubInput(data: Data("  \n\n".utf8))) }
    #expect(try readInput(StubInput(isTerminal: true), optional: true) == nil)
    #expect(try readInput(StubInput(data: Data()), optional: true) == nil)
    #expect(try readInput(StubInput(data: Data("a\r\nb\rc".utf8))) == "a\nb\nc")
    #expect(try readInput(StubInput(data: Data([0x63, 0x61, 0x66, 0xe9]))) == "caf\u{FFFD}")
}

@Test func callShapes() {
    let job = Job(name: "ask", instructions: "find it", labels: nil, schemaPath: nil)
    #expect(callShape(job: job, input: "text") == ("find it", "text"))
    #expect(callShape(job: job, input: nil) == (toolUseInstructions, "find it"))
}
