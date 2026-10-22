import Foundation

public protocol InputSource: Sendable {
    var isTerminal: Bool { get }
    func readAll() -> Data
}

public struct StandardInput: InputSource {
    public init() {}
    public var isTerminal: Bool { isatty(0) == 1 }
    public func readAll() -> Data { FileHandle.standardInput.readDataToEndOfFile() }
}

/// UTF-8 with invalid bytes replaced, line endings normalised, as afmux's read_input.
public func decodeInput(_ data: Data) -> String {
    String(decoding: data, as: UTF8.self)
        .replacingOccurrences(of: "\r\n", with: "\n")
        .replacingOccurrences(of: "\r", with: "\n")
}

/// afmux's read_input. With optional: true a terminal or blank input gives nil instead of an error.
public func readInput(_ src: any InputSource, optional: Bool = false) throws -> String? {
    if src.isTerminal {
        if optional { return nil }
        throw AfmError(.usage, "afm reads its input from stdin; pipe or redirect it")
    }
    let text = decodeInput(src.readAll())
    if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        if optional { return nil }
        throw AfmError(.usage, "input is empty")
    }
    return text
}
