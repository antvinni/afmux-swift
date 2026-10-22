import Foundation
import FoundationModels
import Testing
@testable import AFMuxCore

private func context(maxCalls: Int = 8, budget: Int = 600, contextSize: Int = 8192) -> ToolContext {
    var script = FakeScript()
    script.contextSize = contextSize
    return ToolContext(counter: FakeBackend(script: script).counter, maxCalls: maxCalls, outputBudget: budget, toolTimeout: 2)
}

private func tool(_ name: String, _ ctx: ToolContext) -> AfmTool {
    builtinTools(context: ctx).first { $0.name == name }!
}

private func fixture() throws -> URL {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("afm-tools-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: dir.appendingPathComponent("sub"), withIntermediateDirectories: true)
    try (1...10).map { "line \($0)" }.joined(separator: "\n").appending("\n").write(to: dir.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
    try "needle here\n".write(to: dir.appendingPathComponent("sub/b.md"), atomically: true, encoding: .utf8)
    return dir
}

@Test func processRunnerBasics() async {
    let ok = await runProcess(["/bin/echo", "hi"], timeout: 5)
    #expect(ok.status == 0 && ok.stdout == "hi\n" && !ok.timedOut)
    let fail = await runProcess(["/bin/sh", "-c", "echo err >&2; exit 3"], timeout: 5)
    #expect(fail.status == 3 && fail.stderr == "err\n")
    let missing = await runProcess(["no-such-command-xyz"], timeout: 5)
    #expect(missing.status == 127)
}

@Test func processTimeoutKillsTheGroup() async throws {
    let r = await runProcess(["/bin/sh", "-c", "sleep 30 & echo $!; wait"], timeout: 0.5)
    #expect(r.timedOut)
    let pid = pid_t(r.stdout.trimmingCharacters(in: .whitespacesAndNewlines))!
    try await Task.sleep(nanoseconds: 300_000_000)
    #expect(kill(pid, 0) != 0)
}

@Test func readFileNumbersAndRanges() async throws {
    let dir = try fixture()
    let ctx = context()
    let read = tool("read_file", ctx)
    let out = try await read.call(arguments: GeneratedContent(json: #"{"path":"\#(dir.path)/a.txt","start_line":2,"end_line":3}"#))
    #expect(out == "2\tline 2\n3\tline 3")
    let missing = try await read.call(arguments: GeneratedContent(json: #"{"path":"/nonexistent"}"#))
    #expect(missing.hasPrefix("error: "))
}

@Test func readFileTruncatesWithMarker() async throws {
    let dir = try fixture()
    let ctx = context(budget: 12)
    let out = try await tool("read_file", ctx).call(arguments: GeneratedContent(json: #"{"path":"\#(dir.path)/a.txt"}"#))
    #expect(out.contains("[truncated: "))
    #expect(out.contains("more lines; call read_file with start_line="))
}

@Test func grepAndListDir() async throws {
    let dir = try fixture()
    let ctx = context()
    let hits = try await tool("grep", ctx).call(arguments: GeneratedContent(json: #"{"pattern":"needle","path":"\#(dir.path)"}"#))
    #expect(hits.contains("sub/b.md:1:needle here"))
    let none = try await tool("grep", ctx).call(arguments: GeneratedContent(json: #"{"pattern":"zzz","path":"\#(dir.path)"}"#))
    #expect(none == "no matches")
    let list = try await tool("list_dir", ctx).call(arguments: GeneratedContent(json: #"{"path":"\#(dir.path)"}"#))
    #expect(list == "a.txt\nsub/")
}

@Test func callCapThrows() async throws {
    let dir = try fixture()
    let ctx = context(maxCalls: 1)
    let list = tool("list_dir", ctx)
    _ = try await list.call(arguments: GeneratedContent(json: #"{"path":"\#(dir.path)"}"#))
    await #expect(throws: ToolCapExceeded(max: 1)) {
        _ = try await list.call(arguments: GeneratedContent(json: #"{"path":"\#(dir.path)"}"#))
    }
}

@Test func nearlyFullContext() async throws {
    let dir = try fixture()
    let ctx = context(contextSize: 1100)
    ctx.start(used: 0)
    let out = try await tool("list_dir", ctx).call(arguments: GeneratedContent(json: #"{"path":"\#(dir.path)"}"#))
    #expect(out == nearlyFull)
}
