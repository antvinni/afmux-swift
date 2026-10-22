import Foundation
import FoundationModels

/// A scripted stand-in for the model, selected with AFMUX_FAKE. Mirrors afmux's tests/fakefm/fm.
public struct FakeScript: Codable, Sendable {
    public struct Count: Codable, Sendable {
        public var fixed: Int?
        public var extraIfContains: String?
        public var delay: Double?
        public var error: String?
        public var schemaTokens: Int?
        public init() {}
    }

    public struct ToolCall: Codable, Sendable {
        public var name: String
        public var arguments: String
    }

    public struct Respond: Codable, Sendable {
        public var text: String?
        public var texts: [String]?
        public var mode: String?
        public var delay: Double?
        public var error: String?
        public var failOnCall: Int?
        public var toolCalls: [ToolCall]?
        public init() {}
    }

    public var log: String?
    public var availability: String?
    public var contextSize: Int?
    public var count: Count?
    public var respond: Respond?

    public init() {}
}

public func fakeError(_ spec: String) -> Error {
    switch spec {
    case "sandbox":
        return NSError(domain: "ModelManagerServices.ModelManagerError", code: 1008, userInfo: [
            NSLocalizedDescriptionKey: "The operation couldn\u{2019}t be completed. (ModelManagerServices.ModelManagerError error 1008.)",
        ])
    case "guardrail": return LanguageModelError.guardrailViolation(.init(debugDescription: "fake guardrail"))
    case "refusal": return LanguageModelError.refusal(.init(explanation: "fake refusal", debugDescription: "fake refusal"))
    case "timeout": return LanguageModelError.timeout(.init(debugDescription: "fake timeout"))
    case "context": return LanguageModelError.contextSizeExceeded(.init(contextSize: 8192, tokenCount: 9000, debugDescription: "fake overflow"))
    case "rateLimited": return LanguageModelError.rateLimited(.init(resetDate: nil, debugDescription: "fake rate limit"))
    case "guide": return LanguageModelError.unsupportedGenerationGuide(.init(schemaName: "T", debugDescription: "fake guide"))
    case "assets": return SystemLanguageModel.Error.assetsUnavailable(.init(debugDescription: "fake assets"))
    default:
        let message = spec.hasPrefix("other:") ? String(spec.dropFirst(6)) : spec
        return NSError(domain: "Fake", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}

/// Per-backend state, looked up by id from the executor (its configuration must be Hashable).
public final class FakeState: @unchecked Sendable {
    private static let registryLock = NSLock()
    nonisolated(unsafe) private static var registry: [Int: FakeState] = [:]
    nonisolated(unsafe) private static var nextID = 0

    public let id: Int
    public let script: FakeScript
    private let lock = NSLock()
    private var respondCalls = 0
    private var currentCall = 0

    init(script: FakeScript) {
        self.script = script
        id = FakeState.registryLock.withLock {
            FakeState.nextID += 1
            return FakeState.nextID
        }
        FakeState.registryLock.withLock { FakeState.registry[id] = self }
    }

    static func lookup(_ id: Int) -> FakeState {
        registryLock.withLock { registry[id]! }
    }

    func startCall() -> Int {
        lock.withLock {
            respondCalls += 1
            currentCall = respondCalls
            return respondCalls
        }
    }

    var call: Int { lock.withLock { currentCall } }

    func log(_ record: [String: Any]) {
        guard let path = script.log,
              let data = try? JSONSerialization.data(withJSONObject: record, options: [.sortedKeys]) else { return }
        lock.withLock {
            if !FileManager.default.fileExists(atPath: path) {
                FileManager.default.createFile(atPath: path, contents: nil)
            }
            guard let handle = FileHandle(forWritingAtPath: path) else { return }
            handle.seekToEndOfFile()
            handle.write(data + Data("\n".utf8))
            try? handle.close()
        }
    }
}

public struct FakeTokenCounter: TokenCounter {
    let state: FakeState
    private var spec: FakeScript.Count { state.script.count ?? .init() }

    public var contextSize: Int { state.script.contextSize ?? 8192 }

    private func prelude() async throws {
        if let delay = spec.delay, delay > 0 { try await Task.sleep(nanoseconds: UInt64(delay * 1e9)) }
        if let error = spec.error { throw fakeError(error) }
    }

    public func count(prompt: String, instructions: Transcript.Instructions?) async throws -> Int {
        let instr = instructions.map { text(of: $0.segments) } ?? ""
        let defs = instructions?.toolDefinitions.map { $0.name + " " + $0.description }.joined() ?? ""
        state.log(["kind": "count", "what": "prompt", "prompt": prompt, "instructions": instr])
        try await prelude()
        if let fixed = spec.fixed { return fixed }
        var n = (prompt.utf8.count + instr.utf8.count + defs.utf8.count + 3) / 4
        if let extra = spec.extraIfContains, let colon = extra.lastIndex(of: ":"),
           prompt.contains(extra[..<colon]), let k = Int(extra[extra.index(after: colon)...]) {
            n += k
        }
        return n
    }

    public func count(schema: GenerationSchema) async throws -> Int {
        state.log(["kind": "count", "what": "schema"])
        try await prelude()
        return spec.schemaTokens ?? (SchemaLoader.jsonText(schema).utf8.count + 3) / 4
    }

    public func count(entries: [Transcript.Entry]) async throws -> Int {
        state.log(["kind": "count", "what": "entries", "n": entries.count])
        try await prelude()
        return entries.reduce(0) { $0 + (entryText($1).utf8.count + 3) / 4 }
    }
}

public struct FakeModel: LanguageModel {
    public typealias Executor = FakeExecutor
    let stateID: Int
    let guardrails: String
    let useCase: String

    public var capabilities: LanguageModelCapabilities { .init([.toolCalling, .guidedGeneration]) }
    public var executorConfiguration: FakeExecutor.Configuration {
        .init(stateID: stateID, guardrails: guardrails, useCase: useCase)
    }
}

public struct FakeExecutor: LanguageModelExecutor {
    public struct Configuration: Hashable, Sendable {
        var stateID: Int
        var guardrails: String
        var useCase: String
    }

    public typealias Model = FakeModel
    let config: Configuration

    public init(configuration: Configuration) throws {
        config = configuration
    }

    public func respond(to request: LanguageModelExecutorGenerationRequest, model: FakeModel,
                        streamingInto channel: LanguageModelExecutorGenerationChannel) async throws {
        let state = FakeState.lookup(config.stateID)
        let spec = state.script.respond ?? .init()
        let entries = Array(request.transcript)
        let lastPrompt = entries.lastIndex { if case .prompt = $0 { return true } else { return false } } ?? 0
        let outputs = entries[lastPrompt...].compactMap { entry -> String? in
            if case .toolOutput(let o) = entry { return text(of: o.segments) } else { return nil }
        }
        var promptText = ""
        if case .prompt(let p) = entries[lastPrompt] { promptText = text(of: p.segments) }
        var instructionsText = ""
        if case .instructions(let i)? = entries.first { instructionsText = text(of: i.segments) }

        if outputs.isEmpty {
            let n = state.startCall()
            state.log([
                "kind": "respond", "call": n, "instructions": instructionsText, "prompt": promptText,
                "schema": request.schema.map { SchemaLoader.jsonText($0) } ?? NSNull(),
                "tools": request.enabledToolDefinitions.map(\.name),
                "sampling": request.generationOptions.samplingMode?.kind == .greedy ? "greedy" : "other",
                "maxTokens": request.generationOptions.maximumResponseTokens ?? NSNull(),
                "guardrails": config.guardrails, "useCase": config.useCase,
                "history": max(0, lastPrompt - 1),
            ])
            if let delay = spec.delay, delay > 0 { try await Task.sleep(nanoseconds: UInt64(delay * 1e9)) }
            if let error = spec.error, spec.failOnCall == nil || spec.failOnCall == n { throw fakeError(error) }
        }
        let calls = spec.toolCalls ?? []
        if outputs.count < calls.count, !request.enabledToolDefinitions.isEmpty {
            let c = calls[outputs.count]
            await channel.send(.toolCalls(action: .toolCall(id: "call\(outputs.count)", name: c.name,
                                                             action: .appendArguments(c.arguments, tokenCount: 1))))
            return
        }
        if !outputs.isEmpty { state.log(["kind": "toolOutputs", "outputs": outputs]) }
        let n = state.call
        let answer: String
        if let texts = spec.texts, !texts.isEmpty {
            answer = texts[min(n, texts.count) - 1]
        } else if spec.mode == "first-line" {
            answer = String(promptText.split(separator: "\n", omittingEmptySubsequences: false).first ?? "")
        } else if spec.mode == "echo" {
            answer = promptText
        } else {
            answer = spec.text ?? (request.schema == nil ? "OK" : "{}")
        }
        await channel.send(.response(action: .appendText(answer, tokenCount: max(1, answer.utf8.count / 4))))
    }
}

public struct FakeBackend: Backend {
    let state: FakeState

    public init(script: FakeScript) {
        state = FakeState(script: script)
    }

    public init(scriptPath: String) throws {
        let data = try Data(contentsOf: URL(fileURLWithPath: scriptPath))
        self.init(script: try JSONDecoder().decode(FakeScript.self, from: data))
    }

    public var counter: any TokenCounter { FakeTokenCounter(state: state) }

    public func model(guardrails: String, useCase: String) -> any LanguageModel {
        FakeModel(stateID: state.id, guardrails: guardrails, useCase: useCase)
    }

    public func isAvailable() -> Bool {
        state.script.availability != "unavailable"
    }
}
