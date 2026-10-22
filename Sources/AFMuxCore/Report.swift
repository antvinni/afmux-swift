import Foundation

/// JSON with ordered keys, printed as Python's json.dumps(obj, indent=1[, ensure_ascii]).
indirect enum JSONValue {
    case object([(String, JSONValue)])
    case array([JSONValue])
    case string(String)
    case int(Int)
    case double(Double)
    case bool(Bool)
    case null

    func dumps(asciiOnly: Bool = true, level: Int = 0) -> String {
        let pad = String(repeating: " ", count: level + 1)
        let close = String(repeating: " ", count: level)
        switch self {
        case .object(let pairs):
            if pairs.isEmpty { return "{}" }
            return "{\n" + pairs.map { pad + quote($0.0, asciiOnly) + ": " + $0.1.dumps(asciiOnly: asciiOnly, level: level + 1) }
                .joined(separator: ",\n") + "\n" + close + "}"
        case .array(let items):
            if items.isEmpty { return "[]" }
            return "[\n" + items.map { pad + $0.dumps(asciiOnly: asciiOnly, level: level + 1) }.joined(separator: ",\n") + "\n" + close + "]"
        case .string(let s): return quote(s, asciiOnly)
        case .int(let n): return String(n)
        case .double(let d): return "\(d)"
        case .bool(let b): return b ? "true" : "false"
        case .null: return "null"
        }
    }

    private func quote(_ s: String, _ asciiOnly: Bool) -> String {
        var out = "\""
        for u in s.unicodeScalars {
            switch u {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            case "\u{8}": out += "\\b"
            case "\u{c}": out += "\\f"
            default:
                if u.value < 0x20 || (asciiOnly && u.value > 0x7f) {
                    if u.value > 0xffff {
                        let v = u.value - 0x10000
                        out += String(format: "\\u%04x\\u%04x", 0xd800 + (v >> 10), 0xdc00 + (v & 0x3ff))
                    } else {
                        out += String(format: "\\u%04x", u.value)
                    }
                } else {
                    out.unicodeScalars.append(u)
                }
            }
        }
        return out + "\""
    }
}

/// Python "%-*s": left-justify to width.
func ljust(_ s: String, _ width: Int) -> String {
    s.count >= width ? s : s + String(repeating: " ", count: width - s.count)
}

/// afmux head_tail: the first and last lines of a long test output.
func headTail(_ text: String, head: Int = 25, tail: Int = 25) -> String {
    let lines = text.stripped().components(separatedBy: "\n")
    if lines.count <= head + tail { return lines.joined(separator: "\n") }
    return (Array(lines[..<head]) + ["... \(lines.count - head - tail) lines omitted, full output in the .afm-failed.log file ..."]
        + Array(lines[(lines.count - tail)...])).joined(separator: "\n")
}

func roundedSeconds(_ s: Double) -> Double { (s * 10).rounded() / 10 }

/// afmux report_text.
func reportText(_ rows: [StepRow], _ failed: StepFailure?) -> String {
    let wID = max("step".count, rows.map(\.id.count).max() ?? 0)
    let wFile = max("file".count, rows.map(\.file.count).max() ?? 0)
    var lines = [ljust("step", wID) + "  " + ljust("file", wFile) + "  " + ljust("result", 7) + "  " + ljust("attempts", 8) + "  seconds"]
    for r in rows {
        let extra = r.attempts == 0 && !r.notes.isEmpty ? "  (\(r.notes[0]))" : ""
        let att = r.result != "skipped" ? String(r.attempts) : "-"
        let secs = r.result != "skipped" ? String(format: "%.1f", roundedSeconds(r.seconds)) : "-"
        lines.append(ljust(r.id, wID) + "  " + ljust(r.file, wFile) + "  " + ljust(r.result, 7) + "  " + ljust(att, 8) + "  " + secs + extra)
    }
    let noted = rows.filter { r in r.attempts > 0 && r.notes.contains { !$0.hasPrefix("tests run:") } }
    if !noted.isEmpty {
        lines.append("")
        for r in noted {
            for n in r.notes where !n.hasPrefix("tests run:") { lines.append("\(r.id): \(n)") }
        }
    }
    if let failed {
        lines += ["", "step \(failed.id) failed after \(failed.attempts) attempt\(failed.attempts == 1 ? "" : "s")",
                  "test: \(failed.test)", headTail(failed.output),
                  "attempt saved at \(failed.saved), test output at \(failed.log); \(failed.restored)"]
    } else {
        let done = rows.filter { $0.result == "pass" }
        var tests = 0
        for r in done {
            for n in r.notes where n.hasPrefix("tests run: ") {
                if let k = Int(n.dropFirst(11)) { tests += k }
            }
        }
        let retries = done.reduce(0) { $0 + max(0, $1.attempts - 1) }
        let warnings = rows.reduce(0) { $0 + $1.notes.filter { $0.hasPrefix("warning") }.count }
        lines += ["", "\(done.count)/\(rows.count) steps passed, \(tests) tests, \(retries) retries, \(warnings) warnings"]
    }
    return lines.joined(separator: "\n") + "\n"
}

/// afmux report_json.
func reportJSON(_ rows: [StepRow], _ failed: StepFailure?) -> String {
    let steps = rows.map { r -> JSONValue in
        .object([("id", .string(r.id)), ("file", .string(r.file)), ("result", .string(r.result)), ("attempts", .int(r.attempts)),
                 ("seconds", r.result == "skipped" ? .int(0) : .double(roundedSeconds(r.seconds))),
                 ("notes", .array(r.notes.map { .string($0) }))])
    }
    let f: JSONValue = failed.map {
        .object([("id", .string($0.id)), ("test", .string($0.test)), ("output", .string($0.output)),
                 ("saved", .string($0.saved)), ("log", .string($0.log))])
    } ?? .null
    return JSONValue.object([("steps", .array(steps)), ("failed", f)]).dumps() + "\n"
}
