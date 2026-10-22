import Foundation
import FoundationModels

public protocol TokenCounter: Sendable {
    var contextSize: Int { get }
    /// An instructions entry (text and tool definitions) plus a prompt; either may be empty.
    func count(prompt: String, instructions: Transcript.Instructions?) async throws -> Int
    func count(schema: GenerationSchema) async throws -> Int
    func count(entries: [Transcript.Entry]) async throws -> Int
}

public struct SystemTokenCounter: TokenCounter {
    public init() {}

    public var contextSize: Int { SystemLanguageModel.default.contextSize }

    public func count(prompt: String, instructions: Transcript.Instructions?) async throws -> Int {
        let model = SystemLanguageModel.default
        var n = 0
        if let instructions { n += try await model.tokenCount(for: [Transcript.Entry.instructions(instructions)]) }
        if !prompt.isEmpty { n += try await model.tokenCount(for: prompt) }
        return n
    }

    public func count(schema: GenerationSchema) async throws -> Int {
        try await SystemLanguageModel.default.tokenCount(for: schema)
    }

    public func count(entries: [Transcript.Entry]) async throws -> Int {
        entries.isEmpty ? 0 : try await SystemLanguageModel.default.tokenCount(for: entries)
    }
}

/// Applies --timeout to every count, as afmux's run_fm does for count-tokens.
public struct TimedCounter: TokenCounter {
    public let base: any TokenCounter
    public let timeout: Double

    public init(base: any TokenCounter, timeout: Double) {
        self.base = base
        self.timeout = timeout
    }

    public var contextSize: Int { base.contextSize }

    public func count(prompt: String, instructions: Transcript.Instructions?) async throws -> Int {
        let base = self.base
        return try await withTimeout(timeout) { try await base.count(prompt: prompt, instructions: instructions) }
    }

    public func count(schema: GenerationSchema) async throws -> Int {
        let base = self.base
        return try await withTimeout(timeout) { try await base.count(schema: schema) }
    }

    public func count(entries: [Transcript.Entry]) async throws -> Int {
        let base = self.base
        return try await withTimeout(timeout) { try await base.count(entries: entries) }
    }
}
