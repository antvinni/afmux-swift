import Foundation
import FoundationModels

public struct IO: Sendable {
    public var input: any InputSource
    public var out: @Sendable (String) -> Void
    public var err: @Sendable (String) -> Void
    public var env: [String: String]

    public init(input: any InputSource, out: @escaping @Sendable (String) -> Void,
                err: @escaping @Sendable (String) -> Void, env: [String: String]) {
        self.input = input
        self.out = out
        self.err = err
        self.env = env
    }

    public static func standard() -> IO {
        IO(input: StandardInput(),
           out: { FileHandle.standardOutput.write(Data($0.utf8)) },
           err: { FileHandle.standardError.write(Data($0.utf8)) },
           env: ProcessInfo.processInfo.environment)
    }
}

public func runAfm(_ argv: [String], io: IO, backend: any Backend) async -> Int32 {
    do {
        if argv.first == "sessions" { return try sessionsCommand(Array(argv.dropFirst()), io: io) }
        let o = try parseArgs(argv)
        if o.help {
            io.out(helpText)
            return 0
        }
        if o.list {
            io.out(Presets.listing())
            return 0
        }
        if let name = o.session { return try await runSessionTurn(o, name: name, io: io, backend: backend) }
        return try await runOnce(o, io: io, backend: backend)
    } catch {
        let e = mapError(error, backend: backend)
        io.err("afm: \(e.message)\n")
        return e.code.rawValue
    }
}

func runOnce(_ o: Options, io: IO, backend: any Backend) async throws -> Int32 {
    let job = try resolveJob(o)
    try checkNewCombos(o)
    let counter = TimedCounter(base: backend.counter, timeout: o.timeout)
    let toolset = try Toolset.make(o, counter: counter)
    let tools = toolset.tools
    let input = try readInput(io.input, optional: job.name == "ask" && o.toolsOn)
    let shape = callShape(job: job, input: input)
    let schema = try jobSchema(job)
    let instructions = instructionsEntry(shape.instructions, tools: tools)
    var schemaTokens = 0
    if let schema { schemaTokens = try await counter.count(schema: schema) }
    let total = try await counter.count(prompt: shape.prompt, instructions: instructions) + schemaTokens
    try checkBudget(total: total, budget: o.budget, chunk: o.chunk, job: job)
    let model = backend.model(guardrails: o.guardrails, useCase: o.useCase)
    if o.chunk {
        let pieces = try await planChunks(text: shape.prompt, instructions: instructions, schemaTokens: schemaTokens,
                                          budget: o.budget, maxChunks: o.maxChunks, totalTokens: total - schemaTokens, counter: counter)
        var out = ""
        for (k, piece) in pieces.enumerated() {
            do {
                let a = try await answer(ModelCall(instructions: instructions, prompt: piece, schema: schema), job: job, model: model, timeout: o.timeout)
                out += schema == nil ? "[\(k + 1)/\(pieces.count)]\n\(a)\n" : a + "\n"
            } catch {
                let e = mapError(error, backend: backend)
                throw AfmError(e.code, "chunk \(k + 1)/\(pieces.count): \(e.message)")
            }
        }
        io.out(out)
        return 0
    }
    toolset.context?.start(used: total)
    do {
        let a = try await answer(ModelCall(instructions: instructions, prompt: shape.prompt, schema: schema, tools: tools),
                                 job: job, model: model, timeout: o.timeout)
        io.out(a + "\n")
    } catch {
        throw mapError(error, backend: backend, duringTools: o.toolsOn)
    }
    return 0
}

/// One model call under --timeout, checked as afmux's respond and parse_answer do.
func answer(_ call: ModelCall, job: Job, model: any LanguageModel, timeout: Double) async throws -> String {
    let result = try await withTimeout(timeout) { try await runModel(call, model: model) }
    return try checkedAnswer(result, job: job)
}

func checkedAnswer(_ result: ModelAnswer, job: Job) throws -> String {
    if let labels = job.labels {
        var label: String?
        if case .structure(let props, _)? = result.content?.kind, case .string(let s)? = props["label"]?.kind {
            label = s
        }
        guard let label, labels.contains(label) else {
            throw AfmError(.json, "label \(pyRepr(label)) is not one of \(labels.joined(separator: ", "))")
        }
    }
    let text = result.text.rstripped()
    if result.content == nil && text.isEmpty { throw AfmError(.model, "model returned no output") }
    return text
}

func jobSchema(_ job: Job) throws -> GenerationSchema? {
    if let labels = job.labels { return SchemaLoader.classify(labels: labels) }
    guard let path = job.schemaPath, !path.isEmpty else { return nil }
    do {
        return try SchemaLoader.load(try Data(contentsOf: URL(fileURLWithPath: path)))
    } catch let p as SchemaProblem {
        throw AfmError(.usage, "schema file \(path) is not supported: \(p.message)")
    }
}

/// afmux's check_budget.
func checkBudget(total: Int, budget: Int, chunk: Bool, job: Job) throws {
    if total <= budget || chunk { return }
    let advice = job.name == "commit-msg"
        ? "pipe a smaller diff, for example { git diff --cached --stat; git diff --cached -U1; }"
        : "rerun with --chunk"
    throw AfmError(.budget, "input is \(total) tokens, budget is \(budget); \(advice)")
}
