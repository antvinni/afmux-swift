import Foundation

public enum Exit: Int32, Sendable {
    case ok = 0
    case model = 1
    case usage = 2
    case json = 3
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

public let usageLine = "usage: afm <preset> [options] < input | afm ask \"<instructions>\" [options] < input | afm --list"

extension String {
    /// Python's str.rstrip() with no argument.
    public func rstripped() -> String {
        var s = Substring(self)
        while let last = s.last, last.isWhitespace { s.removeLast() }
        return String(s)
    }
}
