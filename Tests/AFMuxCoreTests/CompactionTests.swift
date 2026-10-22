import FoundationModels
import Testing
@testable import AFMuxCore

@Test func renderLabelsRoles() throws {
    let entries: [Transcript.Entry] = [
        .prompt(Transcript.Prompt(segments: [.text(.init(content: "hi"))])),
        .toolCalls(Transcript.ToolCalls([Transcript.ToolCall(id: "1", toolName: "grep", arguments: try GeneratedContent(json: #"{"pattern":"x"}"#))])),
        .toolOutput(Transcript.ToolOutput(id: "1", toolName: "grep", segments: [.text(.init(content: "a:1:x"))])),
        .response(Transcript.Response(segments: [.text(.init(content: "found"))])),
    ]
    #expect(render(entries) == "User: hi\n\nTool call: grep({\"pattern\":\"x\"})\n\nTool output (grep): a:1:x\n\nAssistant: found")
}

@Test func summaryEntryShape() {
    let entries = summaryEntries("facts")
    #expect(entries.count == 2)
    #expect(entryText(entries[0]) == "Summary of earlier conversation:\nfacts")
    #expect(entryText(entries[1]) == "OK")
}
