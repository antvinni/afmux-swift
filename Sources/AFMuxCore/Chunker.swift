import Foundation
import FoundationModels

public struct Unit: Equatable, Sendable {
    public var text: String
    public var sep: String
    public var line: Int
}

private let blankLines = try! NSRegularExpression(pattern: "\n[ \t]*\n+")

/// Non-blank paragraphs separated by blank lines, each with its first line number.
public func splitUnits(_ text: String) -> [Unit] {
    var units: [Unit] = []
    let ns = text as NSString
    var line = 1
    var pos = 0
    for m in blankLines.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
        addUnit(&units, ns.substring(with: NSRange(location: pos, length: m.range.location - pos)), line)
        line += ns.substring(with: NSRange(location: pos, length: NSMaxRange(m.range) - pos)).filter { $0 == "\n" }.count
        pos = NSMaxRange(m.range)
    }
    addUnit(&units, ns.substring(from: pos), line)
    return units
}

private func addUnit(_ units: inout [Unit], _ chunk: String, _ line: Int) {
    if chunk.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return }
    let stripped = chunk.drop { $0 == "\n" }
    let leading = chunk.count - stripped.count
    var body = String(stripped)
    while body.hasSuffix("\n") { body.removeLast() }
    units.append(Unit(text: body, sep: units.isEmpty ? "" : "\n\n", line: line + leading))
}

private func explodeLines(_ unit: Unit) -> [Unit] {
    var out: [Unit] = []
    for (i, ln) in unit.text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
        if ln.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { continue }
        out.append(Unit(text: String(ln), sep: out.isEmpty ? unit.sep : "\n", line: unit.line + i))
    }
    return out
}

private func join(_ units: [Unit]) -> String {
    units.enumerated().map { ($0.offset > 0 ? $0.element.sep : "") + $0.element.text }.joined()
}

/// Pack units greedily by a byte ratio, confirming each piece with the counter (afmux plan_chunks).
public func planChunks(text: String, instructions: Transcript.Instructions, schemaTokens: Int, budget: Int,
                       maxChunks: Int, totalTokens: Int, counter: any TokenCounter) async throws -> [String] {
    let instrTokens = try await counter.count(prompt: "", instructions: instructions)
    let fixed = schemaTokens + instrTokens
    let ratio = Double(max(1, totalTokens - instrTokens)) / Double(max(1, text.utf8.count))
    var units = splitUnits(text)
    var pieces: [String] = []
    var i = 0
    while i < units.count {
        var piece: [Unit] = []
        var nbytes = 0
        while i < units.count {
            let b = units[i].text.utf8.count + units[i].sep.utf8.count
            if !piece.isEmpty && Double(nbytes + b) * ratio + Double(fixed) > Double(budget) { break }
            piece.append(units[i])
            nbytes += b
            i += 1
        }
        var candidate = ""
        while true {
            candidate = join(piece)
            if try await counter.count(prompt: candidate, instructions: instructions) + schemaTokens <= budget { break }
            if piece.count > 1 {
                piece.removeLast()
                i -= 1
                continue
            }
            let u = piece[0]
            if u.text.contains("\n") {
                units.replaceSubrange((i - 1)..<i, with: explodeLines(u))
                i -= 1
                piece = []
                break
            }
            let n = try await counter.count(prompt: u.text, instructions: nil)
            throw AfmError(.budget, "line \(u.line) is \(n) tokens plus \(fixed) for instructions and schema, budget is \(budget)")
        }
        if piece.isEmpty { continue }
        pieces.append(candidate)
        if pieces.count > maxChunks {
            throw AfmError(.budget, "input needs more than \(maxChunks) chunks, max is \(maxChunks)")
        }
    }
    return pieces
}
