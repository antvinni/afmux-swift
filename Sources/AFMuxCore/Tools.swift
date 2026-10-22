import Foundation
import FoundationModels

public let nearlyFull = "Context nearly full. Answer now with what you have."

/// Shared by the tools of one afm call: the running context count and the call cap.
public final class ToolContext: @unchecked Sendable {
    public let counter: any TokenCounter
    public let maxCalls: Int
    public let outputBudget: Int
    public let toolTimeout: Double
    private let lock = NSLock()
    private var used = 0
    private var calls = 0

    public init(counter: any TokenCounter, maxCalls: Int, outputBudget: Int, toolTimeout: Double) {
        self.counter = counter
        self.maxCalls = maxCalls
        self.outputBudget = outputBudget
        self.toolTimeout = toolTimeout
    }

    /// Reset for a model call whose pre-call total is used.
    public func start(used: Int) {
        lock.withLock {
            self.used = used
            calls = 0
        }
    }

    /// Tokens left before contextSize minus the 1024-token output reserve.
    public var room: Int { lock.withLock { counter.contextSize - 1024 - used } }

    func add(_ n: Int) { lock.withLock { used += n } }

    func beginCall() throws {
        try lock.withLock {
            calls += 1
            if calls > maxCalls { throw ToolCapExceeded(max: maxCalls) }
        }
    }

    /// Cut text at a line boundary to fit cap tokens; marker(omitted, kept) ends a cut result.
    func fit(_ text: String, cap: Int, marker: (Int, Int) -> String) async throws -> String {
        let total = try await counter.count(prompt: text, instructions: nil)
        if total <= cap { return text }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        var keep = min(lines.count - 1, lines.count * cap / max(1, total))
        while keep > 0 {
            let candidate = lines[..<keep].joined(separator: "\n") + "\n" + marker(lines.count - keep, keep)
            if try await counter.count(prompt: candidate, instructions: nil) <= cap { return candidate }
            keep = min(keep - 1, keep * 9 / 10)
        }
        // Not even the first line fits: cut it by characters rather than return only a marker.
        let first = lines[0]
        let rest = lines.count > 1 ? "\n" + marker(lines.count - 1, 1) : ""
        var chars = first.count * cap / max(1, total)
        while chars > 0 {
            let candidate = String(first.prefix(chars)) + " [line truncated]" + rest
            if try await counter.count(prompt: candidate, instructions: nil) <= cap { return candidate }
            chars = min(chars - 1, chars * 9 / 10)
        }
        return marker(lines.count, 0)
    }
}

public struct ToolOutput: Sendable {
    public var text: String
    public var marker: @Sendable (Int, Int) -> String

    public init(_ text: String, marker: @escaping @Sendable (Int, Int) -> String = { omitted, _ in "[truncated: \(omitted) more lines]" }) {
        self.text = text
        self.marker = marker
    }
}

/// Every afm tool: dynamic arguments, a running context count, a cap, truncated output.
public struct AfmTool: Tool {
    public typealias Arguments = GeneratedContent
    public typealias Output = String

    public let name: String
    public let description: String
    public let parameters: GenerationSchema
    let context: ToolContext
    let body: @Sendable (GeneratedContent) async -> ToolOutput

    public init(name: String, description: String, parameters: GenerationSchema, context: ToolContext,
                body: @escaping @Sendable (GeneratedContent) async -> ToolOutput) {
        self.name = name
        self.description = description
        self.parameters = parameters
        self.context = context
        self.body = body
    }

    public func call(arguments: GeneratedContent) async throws -> String {
        try context.beginCall()
        context.add(try await context.counter.count(prompt: compactJSON(arguments), instructions: nil))
        if context.room < 100 { return nearlyFull }
        let result = await body(arguments)
        let out = try await context.fit(result.text, cap: min(context.outputBudget, context.room), marker: result.marker)
        context.add(try await context.counter.count(prompt: out, instructions: nil))
        return out
    }
}

func stringArg(_ args: GeneratedContent, _ key: String) -> String? {
    (try? args.value(String?.self, forProperty: key)) ?? nil
}

func intArg(_ args: GeneratedContent, _ key: String) -> Int? {
    (try? args.value(Int?.self, forProperty: key)) ?? nil
}

/// The tools enabled for one afm call and their shared context.
public struct Toolset: Sendable {
    public var tools: [any Tool] = []
    public var context: ToolContext?

    public static func make(_ o: Options, counter: any TokenCounter) throws -> Toolset {
        guard o.toolsOn else { return Toolset() }
        let ctx = ToolContext(counter: counter, maxCalls: o.maxToolCalls, outputBudget: o.toolOutputBudget, toolTimeout: o.toolTimeout)
        var tools: [any Tool] = o.toolsFS ? builtinTools(context: ctx) : []
        if let path = o.toolsFile {
            tools += try loadToolsFile(path).map { commandTool($0, context: ctx) }
        }
        return Toolset(tools: tools, context: ctx)
    }
}
