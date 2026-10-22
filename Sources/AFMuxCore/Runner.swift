import Foundation
import FoundationModels

public struct ModelCall: Sendable {
    public var instructions: Transcript.Instructions
    public var history: [Transcript.Entry]
    public var prompt: String
    public var schema: GenerationSchema?
    public var tools: [any Tool]
    public var maxResponseTokens: Int?

    public init(instructions: Transcript.Instructions, history: [Transcript.Entry] = [], prompt: String,
                schema: GenerationSchema? = nil, tools: [any Tool] = [], maxResponseTokens: Int? = nil) {
        self.instructions = instructions
        self.history = history
        self.prompt = prompt
        self.schema = schema
        self.tools = tools
        self.maxResponseTokens = maxResponseTokens
    }
}

public struct ModelAnswer: Sendable {
    public var text: String
    public var content: GeneratedContent?
    public var transcript: Transcript
}

/// One greedy model call on a fresh session built from instructions + history.
public func runModel(_ call: ModelCall, model: any LanguageModel) async throws -> ModelAnswer {
    let transcript = Transcript(entries: [.instructions(call.instructions)] + call.history)
    let session = makeSession(model, tools: call.tools, transcript: transcript)
    let options = GenerationOptions(samplingMode: .greedy, maximumResponseTokens: call.maxResponseTokens)
    if let schema = call.schema {
        let r = try await session.respond(to: call.prompt, schema: schema, options: options)
        return ModelAnswer(text: compactJSON(r.content, topOrder: SchemaLoader.order(schema)), content: r.content, transcript: session.transcript)
    }
    let r = try await session.respond(to: call.prompt, options: options)
    return ModelAnswer(text: r.content, content: nil, transcript: session.transcript)
}

private func makeSession(_ model: some LanguageModel, tools: [any Tool], transcript: Transcript) -> LanguageModelSession {
    LanguageModelSession(model: model, tools: tools, transcript: transcript)
}
