import Foundation
import FoundationModels
import Testing
@testable import AFMuxCore

private struct StubBackend: Backend {
    var available = true
    var counter: any TokenCounter { SystemTokenCounter() }
    func model(guardrails: String, useCase: String) -> any LanguageModel { SystemLanguageModel.default }
    func isAvailable() -> Bool { available }
}

private struct DummyTool: Tool {
    typealias Arguments = GeneratedContent
    typealias Output = String
    let name = "dummy"
    let description = "d"
    var parameters: GenerationSchema { SchemaLoader.classify(labels: ["a"]) }
    func call(arguments: GeneratedContent) async throws -> String { "" }
}

@Test func mapping() {
    let ok = StubBackend()
    #expect(mapError(AfmError(.usage, "u"), backend: ok) == AfmError(.usage, "u"))
    #expect(mapError(fakeError("sandbox"), backend: ok).code == .sandbox)
    #expect(mapError(fakeError("sandbox"), backend: StubBackend(available: false)).code == .sandbox)
    #expect(mapError(fakeError("guardrail"), backend: ok) == AfmError(.model, "The model's safety guardrails were triggered."))
    #expect(mapError(fakeError("guardrail"), backend: StubBackend(available: false)) == AfmError(.unavailable, "model not available"))
    #expect(mapError(fakeError("guide"), backend: ok).code == .usage)
    #expect(mapError(fakeError("assets"), backend: ok).code == .unavailable)
    #expect(mapError(fakeError("context"), backend: ok, duringTools: true) == AfmError(.model, "context exceeded during tool calls"))
    #expect(mapError(fakeError("other:boom"), backend: ok) == AfmError(.model, "boom"))
    #expect(mapError(GeneratedContent.ParsingError(rawContent: "not json {  ", debugDescription: "x"), backend: ok) == AfmError(.json, "model output is not valid JSON:\nnot json {"))
}

@Test func toolCallErrorIsUnwrapped() {
    let wrapped = LanguageModelSession.ToolCallError(tool: DummyTool(), underlyingError: ToolCapExceeded(max: 2))
    #expect(mapError(wrapped, backend: StubBackend()) == AfmError(.model, "more than 2 tool calls"))
    let sandbox = LanguageModelSession.ToolCallError(tool: DummyTool(), underlyingError: fakeError("sandbox"))
    #expect(mapError(sandbox, backend: StubBackend()).code == .sandbox)
}

@Test func sandboxDetectedInUnderlyingErrorAndText() {
    let inner = fakeError("sandbox") as NSError
    let outer = NSError(domain: "Outer", code: 7, userInfo: [NSUnderlyingErrorKey: inner])
    #expect(isSandboxError(outer))
    let textual = NSError(domain: "X", code: 1, userInfo: [NSLocalizedDescriptionKey: "ModelManagerServices.ModelManagerError error 1008."])
    #expect(isSandboxError(textual))
    #expect(!isSandboxError(fakeError("guardrail")))
}
