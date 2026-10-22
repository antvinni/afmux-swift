import Foundation
import FoundationModels

public let compactionInstructions = "Summarise this conversation for later reference. Keep facts, names, numbers, file paths and decisions. Omit pleasantries."

/// Transcript entries as plain text, labelled by role, for the summary call.
public func render(_ entries: [Transcript.Entry]) -> String {
    entries.compactMap { entry -> String? in
        switch entry {
        case .prompt(let p): return "User: " + text(of: p.segments)
        case .response(let r): return "Assistant: " + text(of: r.segments)
        case .toolCalls(let calls): return calls.map { "Tool call: \($0.toolName)(\(compactJSON($0.arguments)))" }.joined(separator: "\n")
        case .toolOutput(let o): return "Tool output (\(o.toolName)): " + text(of: o.segments)
        default: return nil
        }
    }.joined(separator: "\n\n")
}

public func summaryEntries(_ summary: String) -> [Transcript.Entry] {
    [
        .prompt(Transcript.Prompt(segments: [.text(.init(content: "Summary of earlier conversation:\n" + summary))])),
        .response(Transcript.Response(segments: [.text(.init(content: "OK"))])),
    ]
}

struct Compaction {
    let name: String
    let budget: Int
    let maxChunks: Int
    let timeout: Double
    let counter: any TokenCounter
    let model: any LanguageModel
    let backend: any Backend
    let err: @Sendable (String) -> Void

    /// fixed is the new prompt + instructions + schema. Returns a history that fits, or throws exit 6.
    func compact(_ history: [Transcript.Entry], fixed: Int) async throws -> [Transcript.Entry] {
        if fixed > budget { throw AfmError(.budget, "input is \(fixed) tokens, budget is \(budget)") }
        let before = fixed + (try await counter.count(entries: history))
        let split = history.lastIndex { if case .prompt = $0 { return true } else { return false } } ?? history.count
        var middle = Array(history[..<split])
        var kept = Array(history[split...])
        if middle.isEmpty {
            middle = kept
            kept = []
        }
        var total = before
        for _ in 0..<2 {
            let candidate = summaryEntries(try await summarise(middle)) + kept
            total = fixed + (try await counter.count(entries: candidate))
            if total <= budget {
                err("afm: session \(name) compacted (\(before) \u{2192} \(total) tokens)\n")
                return candidate
            }
            if kept.isEmpty { break }
            middle = candidate
            kept = []
        }
        throw AfmError(.budget, "input is \(total) tokens, budget is \(budget)")
    }

    private func summarise(_ entries: [Transcript.Entry]) async throws -> String {
        let text = render(entries)
        let instructions = instructionsEntry(compactionInstructions, tools: [])
        let total = try await counter.count(prompt: text, instructions: instructions)
        var pieces = [text]
        if total > budget {
            do {
                pieces = try await planChunks(text: text, instructions: instructions, schemaTokens: 0, budget: budget,
                                              maxChunks: maxChunks, totalTokens: total, counter: counter)
            } catch let e as AfmError where e.code == .budget {
                throw AfmError(.budget, "session \(name) is too large to compact")
            }
        }
        var parts: [String] = []
        for piece in pieces {
            let call = ModelCall(instructions: instructions, prompt: piece, maxResponseTokens: budget / 3)
            let model = self.model
            do {
                parts.append(try await withTimeout(timeout) { try await runModel(call, model: model) }.text.rstripped())
            } catch {
                let e = mapError(error, backend: backend)
                throw AfmError(e.code, "compaction: \(e.message)")
            }
        }
        return parts.joined(separator: "\n")
    }
}
