import Foundation
import Testing
@testable import AFMuxCore

private func plan(_ text: String, budget: Int, maxChunks: Int = 8, script: String = "{}") async throws -> [String] {
    let b = FakeBackend(script: try JSONDecoder().decode(FakeScript.self, from: Data(script.utf8)))
    let instr = instructionsEntry("S.", tools: [])
    let total = try await b.counter.count(prompt: text, instructions: instr)
    return try await planChunks(text: text, instructions: instr, schemaTokens: 0, budget: budget, maxChunks: maxChunks, totalTokens: total, counter: b.counter)
}

private let a = String(repeating: "A", count: 100), b = String(repeating: "B", count: 100), c = String(repeating: "C", count: 100)

@Test func unitsSkipBlankAndLeadingLines() {
    let units = splitUnits("\n\n" + a + "\n\n \n\n" + b + "\n")
    #expect(units.map(\.text) == [a, b])
    #expect(units.map(\.line) == [3, 7])
    #expect(units.map(\.sep) == ["", "\n\n"])
}

@Test func splitsAtBlankLinesKeepingOrder() async throws {
    #expect(try await plan([a, b, c].joined(separator: "\n\n"), budget: 60) == [a + "\n\n" + b, c])
}

@Test func longParagraphSplitsAtLines() async throws {
    let text = (0..<4).map { "L\($0)" + String(repeating: "x", count: 98) }.joined(separator: "\n")
    let pieces = try await plan(text, budget: 60)
    #expect(pieces.count == 2)
    #expect(pieces[0].filter { $0 == "\n" }.count == 1)
}

@Test func singleLineOverBudget() async {
    await #expect(throws: AfmError(.budget, "line 3 is 250 tokens plus 1 for instructions and schema, budget is 60")) {
        _ = try await plan("short\n\n" + String(repeating: "y", count: 1000), budget: 60)
    }
}

@Test func tooManyChunks() async {
    await #expect(throws: AfmError(.budget, "input needs more than 3 chunks, max is 3")) {
        _ = try await plan(Array(repeating: String(repeating: "P", count: 100), count: 5).joined(separator: "\n\n"), budget: 30, maxChunks: 3)
    }
}

@Test func popsWhenEstimateUnderpredicts() async throws {
    #expect(try await plan([a, b, c].joined(separator: "\n\n"), budget: 70, script: #"{"count":{"extraIfContains":"B:20"}}"#) == [a, b, c])
}
