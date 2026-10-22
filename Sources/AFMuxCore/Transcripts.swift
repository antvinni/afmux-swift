import Foundation
import FoundationModels

/// The instructions entry for a call; tools are carried as its tool definitions.
public func instructionsEntry(_ text: String, tools: [any Tool]) -> Transcript.Instructions {
    Transcript.Instructions(segments: [.text(.init(content: text))], toolDefinitions: tools.map { definition(of: $0) })
}

private func definition(of tool: some Tool) -> Transcript.ToolDefinition {
    Transcript.ToolDefinition(tool: tool)
}

/// Plain text of transcript segments; structured segments as compact JSON.
public func text(of segments: [Transcript.Segment]) -> String {
    segments.compactMap { segment -> String? in
        switch segment {
        case .text(let t): return t.content
        case .structure(let s): return compactJSON(s.content)
        default: return nil
        }
    }.joined(separator: "\n")
}

public func entryText(_ entry: Transcript.Entry) -> String {
    switch entry {
    case .instructions(let i):
        return text(of: i.segments) + i.toolDefinitions.map { " " + $0.name + " " + $0.description }.joined()
    case .prompt(let p):
        return text(of: p.segments)
    case .response(let r):
        return text(of: r.segments)
    case .toolCalls(let calls):
        return calls.map { $0.toolName + compactJSON($0.arguments) }.joined(separator: "\n")
    case .toolOutput(let o):
        return text(of: o.segments)
    default:
        return ""
    }
}
