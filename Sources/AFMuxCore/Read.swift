import Foundation
import FoundationModels

let readInstructions = "You are given one chunk of a longer document and a question. If this chunk contains a passage that "
    + "answers the question, set found to true and copy that passage into quote exactly as written, one to "
    + "three sentences. If the chunk does not answer the question, set found to false and leave quote empty. "
    + "Never write anything that is not in the chunk. Question: %@"

let readSchemaJSON = #"{"title":"Extract","type":"object","properties":{"found":{"type":"boolean"},"quote":{"type":"string"}},"required":["found","quote"],"x-order":["found","quote"],"additionalProperties":false}"#

private let whitespaceRun = try! NSRegularExpression(pattern: "\\s+")

/// afmux _norm: collapse whitespace, trim, lowercase.
func normalized(_ text: String) -> String {
    let ns = text as NSString
    return whitespaceRun.stringByReplacingMatches(in: text, range: NSRange(location: 0, length: ns.length), withTemplate: " ")
        .stripped().lowercased()
}

public struct ReadAnswer: Sendable {
    public var lines: String
    public var quote: String
}

public struct QuestionResult: Sendable {
    public var question: String
    public var dropped = 0
    public var failed = 0
    public var firstFailure: String?
    public var answers: [ReadAnswer] = []
}

/// The lines of the chunk the quote spans, or the whole chunk if it cannot be placed.
func quoteLines(_ quote: String, in chunk: Chunk) -> String {
    let lines = chunk.text.components(separatedBy: "\n").map(normalized)
    let q = normalized(quote)
    var best: (Int, Int)?
    for start in lines.indices {
        var joined = ""
        for end in start..<lines.count {
            joined += (joined.isEmpty || lines[end].isEmpty ? "" : " ") + lines[end]
            if joined.contains(q) {
                if best == nil || end - start < best!.1 - best!.0 { best = (start, end) }
                break
            }
            if let b = best, end - start >= b.1 - b.0 { break }
        }
    }
    guard let (start, end) = best else { return "\(chunk.firstLine)-\(chunk.lastLine)" }
    return "\(chunk.firstLine + start)-\(chunk.firstLine + end)"
}

struct Reader {
    let options: Options
    let backend: any Backend
    let counter: any TokenCounter

    func read(_ path: String) async throws -> (chunks: Int, tokens: Int, results: [QuestionResult]) {
        var text = readText(path).replacingOccurrences(of: "\r\n", with: "\n")
        if text.stripped().isEmpty { throw AfmError(.usage, "\(path) is empty") }
        var offset = 0
        if let range = options.lines {
            let all = text.components(separatedBy: "\n")
            guard range.lowerBound <= all.count else { throw AfmError(.usage, "\(path) has \(all.count) lines; --lines starts at \(range.lowerBound)") }
            text = all[(range.lowerBound - 1)..<min(range.upperBound, all.count)].joined(separator: "\n")
            offset = range.lowerBound - 1
        }
        let total: Int
        do {
            total = try await counter.count(prompt: text, instructions: nil)
        } catch {
            throw mapError(error, backend: backend)
        }
        let chunks = chunkDocument(text, chunkTokens: options.chunkTokens, totalTokens: total).map {
            Chunk(text: $0.text, firstLine: $0.firstLine + offset, lastLine: $0.lastLine + offset)
        }
        let schema = try SchemaLoader.load(Data(readSchemaJSON.utf8))
        let name = (path as NSString).lastPathComponent
        let model = backend.model()
        var results: [QuestionResult] = []
        for question in options.asks {
            var result = QuestionResult(question: question)
            let instructions = readInstructions.replacingOccurrences(of: "%@", with: question.stripped())
            for chunk in chunks {
                let prompt = "Chunk lines \(chunk.firstLine)-\(chunk.lastLine) of \(name)\n---\n\(chunk.text)"
                let answer: ModelAnswer
                do {
                    answer = try await withTimeout(options.timeout) {
                        try await runModel(instructions: instructions, prompt: prompt, sampling: .greedy, schema: schema, model: model)
                    }
                } catch is GeneratedContent.ParsingError {
                    result.dropped += 1
                    continue
                } catch {
                    let e = mapError(error, backend: backend)
                    if e.code != .fail { throw e }
                    // Unlike the reference, one refused or failed chunk does not end the read.
                    result.failed += 1
                    if result.firstFailure == nil { result.firstFailure = "chunk lines \(chunk.firstLine)-\(chunk.lastLine): \(e.message)" }
                    continue
                }
                guard case .structure(let props, _)? = answer.content?.kind,
                      case .bool(true)? = props["found"]?.kind else { continue }
                var quote = ""
                if case .string(let s)? = props["quote"]?.kind { quote = s }
                if quote.stripped().isEmpty || !normalized(chunk.text).contains(normalized(quote)) {
                    result.dropped += 1
                    continue
                }
                result.answers.append(ReadAnswer(lines: quoteLines(quote, in: chunk), quote: quote.stripped()))
            }
            if result.failed == chunks.count, let message = result.firstFailure {
                throw AfmError(.fail, message)
            }
            results.append(result)
        }
        return (chunks.count, total, results)
    }
}

private func summaryTail(_ r: QuestionResult) -> String {
    (r.dropped > 0 ? ", \(r.dropped) dropped: quote not in text" : "")
        + (r.failed > 0 ? ", \(r.failed) failed: \(r.firstFailure ?? "")" : "")
}

private func questionLines(_ r: QuestionResult, chunks: Int, tokens: Int) -> [String] {
    if r.answers.isEmpty {
        return ["no chunk matched the question (\(chunks) chunks, \(tokens) tokens read locally\(summaryTail(r)))"]
    }
    return ["\(r.answers.count) of \(chunks) chunks matched (\(tokens) tokens read locally\(summaryTail(r)))"]
        + r.answers.map { "[lines \($0.lines)] \"\($0.quote)\"" }
}

/// afmux report_read; several questions print one block each.
func reportRead(path: String, chunks: Int, tokens: Int, results: [QuestionResult], json: Bool) -> String {
    func answers(_ r: QuestionResult) -> JSONValue {
        .array(r.answers.map { .object([("lines", .string($0.lines)), ("quote", .string($0.quote))]) })
    }
    func failedField(_ r: QuestionResult) -> [(String, JSONValue)] {
        r.failed > 0 ? [("failed", .int(r.failed)), ("first_failure", .string(r.firstFailure ?? ""))] : []
    }
    if json {
        if results.count == 1, let r = results.first {
            return JSONValue.object([("file", .string(path)), ("question", .string(r.question)), ("chunks", .int(chunks)),
                                     ("tokens", .int(tokens)), ("dropped", .int(r.dropped))] + failedField(r) + [("answers", answers(r))])
                .dumps(asciiOnly: false) + "\n"
        }
        let qs = results.map { r -> JSONValue in
            .object([("question", .string(r.question)), ("dropped", .int(r.dropped))] + failedField(r) + [("answers", answers(r))])
        }
        return JSONValue.object([("file", .string(path)), ("chunks", .int(chunks)), ("tokens", .int(tokens)), ("questions", .array(qs))])
            .dumps(asciiOnly: false) + "\n"
    }
    if results.count == 1 { return questionLines(results[0], chunks: chunks, tokens: tokens).joined(separator: "\n") + "\n" }
    var lines: [String] = []
    for (k, r) in results.enumerated() {
        if k > 0 { lines.append("") }
        lines.append("Q\(k + 1): \(r.question)")
        lines += questionLines(r, chunks: chunks, tokens: tokens)
    }
    return lines.joined(separator: "\n") + "\n"
}
