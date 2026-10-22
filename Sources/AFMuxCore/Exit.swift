import Foundation

/// afmux's exit codes: 0 all passed, 1 a step failed or the model failed, 2 usage,
/// 4 model unavailable, 5 sandbox, 6 a step's prompt over budget.
public enum Exit: Int32, Sendable {
    case ok = 0
    case fail = 1
    case usage = 2
    case unavailable = 4
    case sandbox = 5
    case budget = 6
}

public struct AfmError: Error, Equatable, Sendable {
    public var code: Exit
    public var message: String

    public init(_ code: Exit, _ message: String) {
        self.code = code
        self.message = message
    }
}

extension String {
    /// Python's str.rstrip() with no argument.
    public func rstripped() -> String {
        var s = Substring(self)
        while let last = s.last, last.isWhitespace { s.removeLast() }
        return String(s)
    }
}

extension StringProtocol {
    /// Python's str.strip() with no argument.
    public func stripped() -> String {
        trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
