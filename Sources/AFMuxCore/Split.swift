import Foundation

/// `--split` (MinionS: single-step jobs). A module spec in afmux's style is a header paragraph and
/// one paragraph per function, each starting `name(args)`. Each function becomes its own model job.
struct SplitJobs {
    var header: String
    var functions: [(name: String, text: String)]
}

private let functionStart = try! NSRegularExpression(pattern: "^\\s*(?:def\\s+)?([A-Za-z_][A-Za-z0-9_]*)\\s*\\(")
private let importLine = try! NSRegularExpression(pattern: "^(import\\s+\\S|from\\s+\\S+\\s+import\\s)")

let splitInstructions = "You are a code implementer. Reply with Python source code only: the import lines this one function "
    + "needs, then the function %@ itself. No other functions, no explanation, no markdown fences, no tests, no example "
    + "usage. Use only the standard library unless the spec says otherwise."

/// The jobs for a .py step whose spec names two or more functions, or nil to generate the file whole.
func splitJobs(_ step: Step) -> SplitJobs? {
    guard step.file.hasSuffix(".py") else { return nil }
    var header: [String] = []
    var functions: [(name: String, text: String)] = []
    for unit in splitUnits(step.spec) {
        let ns = unit.text as NSString
        if let m = functionStart.firstMatch(in: unit.text, range: NSRange(location: 0, length: ns.length)) {
            functions.append((ns.substring(with: m.range(at: 1)), unit.text))
        } else if functions.isEmpty {
            header.append(unit.text)
        } else {
            functions[functions.count - 1].text += "\n\n" + unit.text  // a note that belongs to the function above
        }
    }
    return functions.count >= 2 ? SplitJobs(header: header.joined(separator: "\n\n"), functions: functions) : nil
}

/// Put the per-function replies together: their import lines first (once each), then the functions.
func assemble(_ pieces: [String]) -> String {
    var imports: [String] = []
    var bodies: [String] = []
    for piece in pieces {
        var body: [String] = []
        for line in piece.components(separatedBy: "\n") {
            if matches(importLine, line) {
                if !imports.contains(line) { imports.append(line) }
            } else {
                body.append(line)
            }
        }
        bodies.append(body.joined(separator: "\n").stripped())
    }
    let head = imports.isEmpty ? "" : imports.joined(separator: "\n") + "\n\n\n"
    return head + bodies.filter { !$0.isEmpty }.joined(separator: "\n\n\n") + "\n"
}

extension Implementer {
    func generateSplit(_ step: Step, jobs: SplitJobs) async throws -> String {
        var pieces: [String] = []
        for f in jobs.functions {
            var parts: [String] = []
            if !jobs.header.isEmpty { parts.append(jobs.header) }
            parts.append(f.text)
            for path in step.context {
                guard isFile(path) else { throw AfmError(.usage, "step \(step.id): context file not found: \(path)") }
                parts.append("Reference only, do not modify: \(path)\n\n\(readText(path))")
            }
            if !pieces.isEmpty {
                parts.append("Already written in this module, do not repeat it:\n\n" + assemble(pieces))
            }
            let prompt = parts.map { $0.rstripped() }.joined(separator: "\n\n") + "\n"
            let instructions = splitInstructions.replacingOccurrences(of: "%@", with: f.name)
            try await checkBudget(step, prompt, instructions)
            pieces.append(try await generate(instructions, prompt, .greedy))
        }
        return assemble(pieces)
    }
}
