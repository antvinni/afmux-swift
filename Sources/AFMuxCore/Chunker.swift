import Foundation

public struct Unit: Equatable, Sendable {
    public var text: String
    public var sep: String
    public var line: Int
}

private let blankLines = try! NSRegularExpression(pattern: "\n[ \t]*\n+")

/// Non-blank paragraphs separated by blank lines, each with its first line number (afmux split_units).
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

func joinUnits(_ units: [Unit]) -> String {
    units.enumerated().map { ($0.offset > 0 ? $0.element.sep : "") + $0.element.text }.joined()
}

public struct Chunk: Equatable, Sendable {
    public var text: String
    public var firstLine: Int
    public var lastLine: Int
}

/// afmux chunk_document: pack paragraphs into chunks of about chunkTokens by the file's measured
/// tokens-per-byte ratio. Unlike the reference, a paragraph larger than one chunk (a log with no
/// blank lines) is first split into its lines, so no chunk is the whole file.
public func chunkDocument(_ text: String, chunkTokens: Int, totalTokens: Int) -> [Chunk] {
    let ratio = Double(max(1, totalTokens)) / Double(max(1, text.utf8.count))
    var units: [Unit] = []
    for u in splitUnits(text) {
        if Double(u.text.utf8.count + 2) * ratio <= Double(chunkTokens) || !u.text.contains("\n") {
            units.append(u)
            continue
        }
        for (i, ln) in u.text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            units.append(Unit(text: String(ln), sep: i == 0 ? u.sep : "\n", line: u.line + i))
        }
    }
    var chunks: [Chunk] = []
    var current: [Unit] = []
    var bytes = 0
    func close() {
        let last = current.last!
        chunks.append(Chunk(text: joinUnits(current), firstLine: current[0].line,
                            lastLine: last.line + last.text.filter { $0 == "\n" }.count))
    }
    for u in units {
        let b = u.text.utf8.count + 2
        if !current.isEmpty && Double(bytes + b) * ratio > Double(chunkTokens) {
            close()
            current = []
            bytes = 0
        }
        // A chunk starts at its first unit: its separator belongs to the boundary, not the chunk.
        current.append(current.isEmpty ? Unit(text: u.text, sep: "", line: u.line) : u)
        bytes += b
    }
    if !current.isEmpty { close() }
    return chunks
}
