import Foundation
import Testing

@Suite struct ToolCLITests {
    @Test func askWithToolsAndNoStdinUsesToolInstructions() throws {
        let r = try afm(["ask", "--tools", "fs", "which file defines x?"], tty: true)
        #expect(r.code == 0, "\(r.err)")
        let rec = r.records("respond")[0]
        #expect(rec["instructions"] as? String == "Answer the request. Use the tools to find the information you need. Reply with only the answer.")
        #expect(rec["prompt"] as? String == "which file defines x?")
        #expect(rec["tools"] as? [String] == ["read_file", "grep", "list_dir"])
    }

    @Test func toolOutputReachesTheModel() throws {
        let dir = makeTmp()
        try "hello tools\n".write(to: dir.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        let r = try afm(["ask", "--tools", "fs", "read a.txt"], fake: ["respond": ["toolCalls": [["name": "read_file", "arguments": #"{"path":"a.txt"}"#]], "text": "done"]], tmp: dir)
        #expect(r.code == 0, "\(r.err)")
        #expect(r.out == "done\n")
        #expect((r.records("toolOutputs")[0]["outputs"] as? [String]) == ["1\thello tools"])
    }

    @Test func toolCallCapIsExit1() throws {
        let call = ["name": "list_dir", "arguments": #"{"path":"."}"#]
        let r = try afm(["ask", "--tools", "fs", "--max-tool-calls", "2", "look"], fake: ["respond": ["toolCalls": [call, call, call]]])
        #expect(r.code == 1, "\(r.err)")
        #expect(r.err.contains("more than 2 tool calls"))
    }

    @Test func commandToolFromFile() throws {
        let dir = makeTmp()
        let file = dir.appendingPathComponent("tools.json")
        try #"{"tools":[{"name":"say","description":"echo","arguments":{"type":"object","properties":{"msg":{"type":"string"}},"required":["msg"]},"command":["/bin/echo","{msg}"]}]}"#
            .write(to: file, atomically: true, encoding: .utf8)
        let r = try afm(["ask", "--tools-file", file.path, "say hi"], fake: ["respond": ["toolCalls": [["name": "say", "arguments": #"{"msg":"hi"}"#]]]], tmp: dir)
        #expect(r.code == 0, "\(r.err)")
        #expect((r.records("toolOutputs")[0]["outputs"] as? [String]) == ["exit 0\nstdout:\nhi\nstderr:\n"])
    }

    @Test func toolUsageErrors() throws {
        #expect(try afm(["ask", "--tools", "fs", "--chunk", "x"], stdin: "y").err.contains("--chunk is not allowed with tools"))
        let r = try afm(["summarise", "--tools", "fs"], tty: true)
        #expect(r.code == 2 && r.err.contains("reads its input from stdin"))
        #expect(try afm(["ask", "--tools-file", "/nonexistent.json", "x"], stdin: "y").err.contains("tools file not found: /nonexistent.json"))
    }
}
