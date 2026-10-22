import Foundation
import FoundationModels

/// One turn of a named session (spec: Sessions and compaction).
func runSessionTurn(_ given: Options, name: String, io: IO, backend: any Backend) async throws -> Int32 {
    try SessionStore.validate(name)
    var o = given
    try checkNewCombos(o)
    let store = SessionStore(env: io.env)
    let fd = try store.lock(name, timeout: o.timeout)
    defer { store.unlock(fd) }
    let existing = try store.load(name)
    if let s = existing {
        if let job = o.job, job != s.job { throw AfmError(.usage, "session \(name) is a \(s.job) session") }
        if let labels = o.labels {
            if try parseLabels(labels) != (s.labels ?? []) {
                throw AfmError(.usage, "session \(name) was created with --labels \((s.labels ?? []).joined(separator: ","))")
            }
        } else if let labels = s.labels {
            o.labels = labels.joined(separator: ",")
        }
        if o.guardrailsGiven && o.guardrails != s.guardrails {
            throw AfmError(.usage, "session \(name) was created with --guardrails \(s.guardrails)")
        }
        if o.useCaseGiven && o.useCase != s.useCase {
            throw AfmError(.usage, "session \(name) was created with --use-case \(s.useCase)")
        }
        o.guardrails = s.guardrails
        o.useCase = s.useCase
    }
    let job = try resolveJob(o)
    let counter = TimedCounter(base: backend.counter, timeout: o.timeout)
    let toolset = try Toolset.make(o, counter: counter)
    let input = try readInput(io.input, optional: job.name == "ask" && (existing != nil || o.toolsOn))

    let instructionsText: String
    let prompt: String
    var history: [Transcript.Entry] = []
    if let s = existing {
        guard case .instructions(let stored)? = s.transcript.first else {
            throw AfmError(.model, "session \(name) has no instructions entry")
        }
        instructionsText = text(of: stored.segments)
        prompt = job.name == "ask" ? job.instructions + (input.map { "\n\n" + $0 } ?? "") : input!
        history = Array(s.transcript.dropFirst())
    } else {
        let shape = callShape(job: job, input: input)
        instructionsText = shape.instructions
        prompt = shape.prompt
    }
    let instructions = instructionsEntry(instructionsText, tools: toolset.tools)
    let schema = try jobSchema(job)
    var schemaTokens = 0
    if let schema { schemaTokens = try await counter.count(schema: schema) }
    let fixed = try await counter.count(prompt: prompt, instructions: instructions) + schemaTokens
    var total = fixed + (try await counter.count(entries: history))
    let model = backend.model(guardrails: o.guardrails, useCase: o.useCase)
    if total > o.budget {
        let compaction = Compaction(name: name, budget: o.budget, maxChunks: o.maxChunks, timeout: o.timeout,
                                    counter: counter, model: model, backend: backend, err: io.err)
        history = try await compaction.compact(history, fixed: fixed)
        total = fixed + (try await counter.count(entries: history))
    }
    toolset.context?.start(used: total)
    let result: ModelAnswer
    do {
        let call = ModelCall(instructions: instructions, history: history, prompt: prompt, schema: schema, tools: toolset.tools)
        result = try await withTimeout(o.timeout) { try await runModel(call, model: model) }
    } catch {
        throw mapError(error, backend: backend, duringTools: o.toolsOn)
    }
    let reply = try checkedAnswer(result, job: job)
    let tokens = try await counter.count(entries: Array(result.transcript))
    try store.save(name, SessionFile(job: job.name, labels: job.labels, guardrails: o.guardrails, useCase: o.useCase,
                                     turns: (existing?.turns ?? 0) + 1, tokens: tokens,
                                     modified: ISO8601DateFormatter().string(from: Date()), transcript: result.transcript))
    io.out(reply + "\n")
    return 0
}
