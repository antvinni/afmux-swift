import Foundation
import FoundationModels
import Testing
@testable import AFMuxCore

private func backend(_ json: String) throws -> FakeBackend {
    FakeBackend(script: try JSONDecoder().decode(FakeScript.self, from: Data(json.utf8)))
}

@Test func fakeCounterUsesShimFormula() async throws {
    let b = try backend("{}")
    let instr = instructionsEntry("S.", tools: [])
    #expect(try await b.counter.count(prompt: String(repeating: "x", count: 100), instructions: instr) == 26)
    #expect(try await b.counter.count(prompt: "", instructions: instr) == 1)
    let extra = try backend(#"{"count":{"extraIfContains":"B:20"}}"#)
    #expect(try await extra.counter.count(prompt: "BBBB", instructions: nil) == 21)
}

@Test func fakeModelAnswersText() async throws {
    let b = try backend(#"{"respond":{"text":"A summary.  \n"}}"#)
    let call = ModelCall(instructions: instructionsEntry("Summarise.", tools: []), prompt: "hello")
    let a = try await runModel(call, model: b.model(guardrails: "default", useCase: "general"))
    #expect(a.text == "A summary.  \n")
    #expect(a.content == nil)
    #expect(a.transcript.count == 3)
}

@Test func fakeModelAnswersWithSchema() async throws {
    let b = try backend(#"{"respond":{"text":"{ \"label\" : \"feature\" }"}}"#)
    let call = ModelCall(instructions: instructionsEntry("Classify.", tools: []), prompt: "x",
                         schema: SchemaLoader.classify(labels: ["bug", "feature"]))
    let a = try await runModel(call, model: b.model(guardrails: "default", useCase: "general"))
    #expect(a.text == #"{"label":"feature"}"#)
}

@Test func fakeErrorsAreThrown() async throws {
    let b = try backend(#"{"respond":{"error":"guardrail"}}"#)
    let call = ModelCall(instructions: instructionsEntry("x", tools: []), prompt: "x")
    await #expect(throws: LanguageModelError.self) {
        _ = try await runModel(call, model: b.model(guardrails: "default", useCase: "general"))
    }
}

@Test func timeoutThrowsPinnedMessage() async {
    await #expect(throws: AfmError(.model, "timed out after 0.2 s")) {
        try await withTimeout(0.2) { try await Task.sleep(nanoseconds: 5_000_000_000) }
    }
}

@Test func timedCounterAppliesTimeout() async throws {
    let b = try backend(#"{"count":{"delay":5}}"#)
    let counter = TimedCounter(base: b.counter, timeout: 0.2)
    await #expect(throws: AfmError(.model, "timed out after 0.2 s")) {
        _ = try await counter.count(prompt: "x", instructions: nil)
    }
}
