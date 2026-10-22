import Foundation

/// Python's repr() of a str ("None" for nil), so messages match afmux byte for byte.
public func pyRepr(_ s: String?) -> String {
    guard let s else { return "None" }
    let quote: Unicode.Scalar = (s.contains("'") && !s.contains("\"")) ? "\"" : "'"
    var out = String(quote)
    for u in s.unicodeScalars {
        switch u {
        case "\\": out += "\\\\"
        case "\n": out += "\\n"
        case "\r": out += "\\r"
        case "\t": out += "\\t"
        case quote: out += "\\" + String(quote)
        default:
            if isPrintable(u) { out.unicodeScalars.append(u) } else { out += hexEscape(u) }
        }
    }
    out.unicodeScalars.append(quote)
    return out
}

/// Python's "%g" formatting.
public func pyG(_ x: Double) -> String {
    String(format: "%g", x)
}

private func isPrintable(_ u: Unicode.Scalar) -> Bool {
    if u == " " { return true }
    switch u.properties.generalCategory {
    case .control, .format, .surrogate, .privateUse, .unassigned,
         .lineSeparator, .paragraphSeparator, .spaceSeparator:
        return false
    default:
        return true
    }
}

private func hexEscape(_ u: Unicode.Scalar) -> String {
    let v = u.value
    if v <= 0xff { return String(format: "\\x%02x", v) }
    if v <= 0xffff { return String(format: "\\u%04x", v) }
    return String(format: "\\U%08x", v)
}
