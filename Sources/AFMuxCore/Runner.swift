import Foundation
import FoundationModels

/// How one generation samples. afmux's first attempt is greedy and its retries use fm's
/// default sampling; `--samples` adds seeded samples.
public enum Sampling: Sendable, Equatable {
    case greedy
    case standard
    case seeded(UInt64)

    var mode: GenerationOptions.SamplingMode? {
        switch self {
        case .greedy: return .greedy
        case .standard: return nil
        case .seeded(let seed): return .random(probabilityThreshold: 0.95, seed: seed)
        }
    }
}

public struct ModelAnswer: Sendable {
    public var text: String
    public var content: GeneratedContent?
}

/// One model call on a fresh session: instructions, then the prompt, optionally with a schema.
public func runModel(instructions: String, prompt: String, sampling: Sampling, schema: GenerationSchema? = nil,
                     model: any LanguageModel) async throws -> ModelAnswer {
    let transcript = Transcript(entries: [.instructions(instructionsEntry(instructions, tools: []))])
    let session = makeSession(model, transcript: transcript)
    let options = GenerationOptions(samplingMode: sampling.mode)
    if let schema {
        let r = try await session.respond(to: prompt, schema: schema, options: options)
        return ModelAnswer(text: compactJSON(r.content, topOrder: SchemaLoader.order(schema)), content: r.content)
    }
    let r = try await session.respond(to: prompt, options: options)
    return ModelAnswer(text: r.content, content: nil)
}

private func makeSession(_ model: some LanguageModel, transcript: Transcript) -> LanguageModelSession {
    LanguageModelSession(model: model, tools: [], transcript: transcript)
}
