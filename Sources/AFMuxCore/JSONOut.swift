import Foundation
import FoundationModels

/// JSON as afmux prints it: json.dumps(obj, separators=(",", ":"), ensure_ascii=False).
/// Top-level keys follow topOrder (the schema's x-order) first, then the content's own order.
public func compactJSON(_ c: GeneratedContent, topOrder: [String] = []) -> String {
    switch c.kind {
    case .null:
        return "null"
    case .bool(let b):
        return b ? "true" : "false"
    case .number(let d):
        return formatNumber(d)
    case .string(let s):
        return quoteJSON(s)
    case .array(let items):
        return "[" + items.map { compactJSON($0) }.joined(separator: ",") + "]"
    case .structure(let props, let keys):
        let order = topOrder.filter { props[$0] != nil } + keys.filter { !topOrder.contains($0) }
        return "{" + order.map { quoteJSON($0) + ":" + compactJSON(props[$0]!) }.joined(separator: ",") + "}"
    @unknown default:
        return c.jsonString
    }
}

func formatNumber(_ d: Double) -> String {
    if d.isNaN { return "NaN" }
    if d.isInfinite { return d > 0 ? "Infinity" : "-Infinity" }
    if d == d.rounded(), abs(d) < 9_007_199_254_740_992 { return String(Int64(d)) }
    if d == d.rounded(), abs(d) < 1e21 { return String(format: "%.0f", d) }
    return "\(d)"
}

func quoteJSON(_ s: String) -> String {
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
            if u.value < 0x20 { out += String(format: "\\u%04x", u.value) } else { out.unicodeScalars.append(u) }
        }
    }
    return out + "\""
}
