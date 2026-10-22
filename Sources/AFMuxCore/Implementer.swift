import Foundation

let implementerInstructions = "You are a code implementer. Reply with source code only: no explanation, no markdown fences, "
    + "no tests, no example usage. Use only the standard library unless the spec says otherwise. "
    + "The code will be saved as %@ and imported."

let testTimeout: Double = 120

private let fence = try! NSRegularExpression(pattern: "^\\s*```[A-Za-z0-9_+-]*[ \\t]*\\n(.*?)\\n```\\s*$", options: [.dotMatchesLineSeparators])
private let testCount = try! NSRegularExpression(pattern: "Ran (\\d+) tests?|(\\d+) passed|collected (\\d+) items?")
private let failLine = try! NSRegularExpression(pattern: "^(FAIL|ERROR): ")
private let exceptionLine = try! NSRegularExpression(pattern: "^[A-Za-z_.]*(Error|Exception|Warning)\\b")
private let topLevelDef = try! NSRegularExpression(pattern: "^(?:def|class) ([A-Za-z_]\\w*)", options: [.anchorsMatchLines])

func matches(_ re: NSRegularExpression, _ s: String) -> Bool {
    re.firstMatch(in: s, range: NSRange(location: 0, length: (s as NSString).length)) != nil
}

func readText(_ path: String) -> String {
    let data = FileManager.default.contents(atPath: path) ?? Data()
    return String(decoding: data, as: UTF8.self)
}

/// Write a file, creating directories; for .py also delete its bytecode, since a same-size rewrite
/// within one second would otherwise load the stale .pyc.
func writeText(_ path: String, _ content: String) {
    let dir = (path as NSString).deletingLastPathComponent
    if !dir.isEmpty { try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true) }
    FileManager.default.createFile(atPath: path, contents: Data(content.utf8))
    guard path.hasSuffix(".py") else { return }
    let cache = ((dir.isEmpty ? "." : dir) as NSString).appendingPathComponent("__pycache__")
    let stem = ((path as NSString).lastPathComponent as NSString).deletingPathExtension + "."
    for name in (try? FileManager.default.contentsOfDirectory(atPath: cache)) ?? [] where name.hasPrefix(stem) && name.hasSuffix(".pyc") {
        try? FileManager.default.removeItem(atPath: (cache as NSString).appendingPathComponent(name))
    }
}

/// afmux strip_fence: drop one markdown fence around the whole reply.
func stripFence(_ text: String) -> String {
    var t = text
    let ns = text as NSString
    if let m = fence.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)) {
        t = ns.substring(with: m.range(at: 1))
    }
    return t.rstripped() + "\n"
}

func buildPrompt(_ step: Step, current: String?, previous: String? = nil, testOutput: String? = nil) throws -> String {
    var parts = [step.spec]
    if let current {
        parts.append("Current contents of \(step.file). Output the complete modified file:\n\n\(current)")
    }
    for path in step.context {
        guard isFile(path) else { throw AfmError(.usage, "step \(step.id): context file not found: \(path)") }
        parts.append("Reference only, do not modify: \(path)\n\n\(readText(path))")
    }
    if let previous {
        parts.append("Your previous implementation:\n\n\(previous)")
        parts.append("It failed these tests. Output the complete corrected file:\n\n" + String((testOutput ?? "").suffix(1800)))
    }
    return parts.map { $0.rstripped() }.joined(separator: "\n\n") + "\n"
}

/// How many tests the command reported running, or nil if it didn't say.
func testsRun(_ output: String) -> Int? {
    let ns = output as NSString
    var total: Int?
    for m in testCount.matches(in: output, range: NSRange(location: 0, length: ns.length)) {
        for g in 1...3 where m.range(at: g).location != NSNotFound {
            total = (total ?? 0) + (Int(ns.substring(with: m.range(at: g))) ?? 0)
            break
        }
    }
    return total
}

func runTests(_ command: String) async -> (ok: Bool, output: String) {
    let r = await runProcess(["/bin/sh", "-c", command], timeout: testTimeout)
    if r.timedOut { return (false, "test command timed out after \(Int(testTimeout)) s") }
    return (r.status == 0, r.stdout + r.stderr)
}

/// One line that says why a test run failed: the first failing test and the exception line.
func failureSummary(_ output: String) -> String {
    let lines = output.components(separatedBy: "\n").map { $0.stripped() }.filter { !$0.isEmpty }
    var test: String?
    var exc: String?
    for ln in lines {
        if test == nil && matches(failLine, ln) { test = ln }
        if matches(exceptionLine, ln) && !ln.hasPrefix("Traceback") {
            exc = ln
            if test != nil { break }
        }
    }
    let parts = [test, exc].compactMap { $0 }
    if !parts.isEmpty { return String(parts.joined(separator: " | ").prefix(240)) }
    for ln in lines.reversed() where ln.contains("Error") || ln.hasPrefix("Traceback") {
        return String(ln.prefix(240))
    }
    return lines.last.map { String($0.prefix(240)) } ?? "no output"
}

func duplicateDefinitions(_ code: String) -> [String] {
    let ns = code as NSString
    let names = topLevelDef.matches(in: code, range: NSRange(location: 0, length: ns.length)).map { ns.substring(with: $0.range(at: 1)) }
    return Set(names.filter { n in names.filter { $0 == n }.count > 1 }).sorted()
}

func clearFailed(_ step: Step) {
    for suffix in [".afm-failed", ".afm-failed.log"] { try? FileManager.default.removeItem(atPath: step.file + suffix) }
}

/// An error that must end the run rather than count as a failed attempt.
struct Fatal: Error {
    let error: AfmError
}

public struct StepFailure: Sendable {
    public var id: String
    public var test: String
    public var output: String
    public var saved: String
    public var log: String
    public var restored: String
    public var attempts: Int
}

public struct StepRow: Sendable {
    public var id: String
    public var file: String
    public var result: String
    public var attempts: Int
    public var seconds: Double
    public var notes: [String]
}

struct Implementer {
    let options: Options
    let backend: any Backend
    let counter: any TokenCounter

    /// One model call: text with any fence removed, or AfmError(.fail) with the model's message.
    func generate(_ instructions: String, _ prompt: String, _ sampling: Sampling) async throws -> String {
        let model = backend.model()
        let answer: ModelAnswer
        do {
            answer = try await withTimeout(options.timeout) {
                try await runModel(instructions: instructions, prompt: prompt, sampling: sampling, model: model)
            }
        } catch {
            throw mapError(error, backend: backend)
        }
        let text = stripFence(answer.text)
        if text.stripped().isEmpty { throw AfmError(.fail, "model returned no output") }
        return text
    }

    func checkBudget(_ step: Step, _ prompt: String, _ instructions: String) async throws {
        let used: Int
        do {
            used = try await counter.count(prompt: prompt, instructions: instructionsEntry(instructions, tools: []))
        } catch {
            // afmux counts outside the attempt: a failed count ends the run, it is not a failed attempt
            throw Fatal(error: mapError(error, backend: backend))
        }
        if used > options.budget {
            throw AfmError(.budget, "step \(step.id): prompt is \(used) tokens, budget is \(options.budget); split the step or trim its context")
        }
    }

    private enum Kind { case first, sample(UInt64), retry }

    /// afmux run_step. earlier: steps that passed before this one; their tests are rerun after this
    /// step passes its own, so a whole-file rewrite cannot silently break them.
    func run(_ step: Step, earlier: [Step]) async throws -> (StepRow, StepFailure?) {
        let t0 = Date()
        let existed = isFile(step.file)
        let original = existed ? readText(step.file) : nil
        var notes: [String] = []
        func row(_ result: String, _ attempts: Int) -> StepRow {
            StepRow(id: step.id, file: step.file, result: result, attempts: attempts, seconds: Date().timeIntervalSince(t0), notes: notes)
        }
        func testsNote(_ output: String) {
            let n = testsRun(output)
            if n == 0 { notes.append("warning: the test command ran 0 tests") }
            notes.append("tests run: \(n.map(String.init) ?? "unknown")")
        }
        if existed {
            let (ok, out0) = await runTests(step.test)
            if ok {
                clearFailed(step)
                notes.append("already passing, not regenerated")
                testsNote(out0)
                return (row("pass", 0), nil)
            }
            notes.append("existing \(step.file) failed its test; regenerating it (it is restored if every attempt fails)")
        }
        let instructions = implementerInstructions.replacingOccurrences(of: "%@", with: step.file)
        var previous: String?
        var output: String?
        var attempts = 0
        var code = ""
        var tried = Set<String>()
        let plan: [Kind] = [.first] + (1..<max(1, options.samples)).map { .sample(UInt64($0)) }
            + Array(repeating: .retry, count: options.retries)
        for kind in plan {
            attempts += 1
            var newCode: String
            do {
                switch kind {
                case .first:
                    if options.split, !existed, let jobs = splitJobs(step) {
                        newCode = try await generateSplit(step, jobs: jobs)
                        notes.append("attempt 1 generated \(jobs.functions.count) functions one at a time (--split)")
                    } else {
                        let prompt = try buildPrompt(step, current: original)
                        try await checkBudget(step, prompt, instructions)
                        newCode = try await generate(instructions, prompt, .greedy)
                    }
                case .sample(let seed):
                    let prompt = try buildPrompt(step, current: original)
                    try await checkBudget(step, prompt, instructions)
                    newCode = try await generate(instructions, prompt, .seeded(seed))
                case .retry:
                    let prompt = try buildPrompt(step, current: original, previous: previous, testOutput: output)
                    try await checkBudget(step, prompt, instructions)
                    newCode = try await generate(instructions, prompt, .standard)
                }
            } catch let e as AfmError where e.code == .fail {
                output = "fm: " + e.message
                previous = code.isEmpty ? "(no code produced)" : code
                notes.append("attempt \(attempts) failed: \(e.message.prefix(160))")
                continue
            }
            if tried.contains(newCode) || (previous != nil && newCode == previous) {
                notes.append("attempt \(attempts) produced identical code; not retested")
                if case .retry = kind { break }
                continue
            }
            tried.insert(newCode)
            code = newCode
            writeText(step.file, code)
            var (ok, out) = await runTests(step.test)
            output = out
            if ok {
                var broken: (Step, String)?
                for e in earlier {
                    let (eok, eout) = await runTests(e.test)
                    if !eok {
                        broken = (e, eout)
                        break
                    }
                }
                if let (e, eout) = broken {
                    ok = false
                    output = "regression: this step's rewrite of \(step.file) broke step \(e.id) (test: \(e.test)). Keep every existing "
                        + "function unchanged.\n\n\(eout)"
                } else {
                    clearFailed(step)
                    let dups = step.file.hasSuffix(".py") ? duplicateDefinitions(code) : []
                    if !dups.isEmpty {
                        notes.append("warning: duplicate top-level definition of \(dups.joined(separator: ", ")); the last one wins")
                    }
                    testsNote(out)
                    return (row("pass", attempts), nil)
                }
            }
            notes.append("attempt \(attempts) failed: \(failureSummary(output ?? ""))")
            previous = code
        }
        let saved = step.file + ".afm-failed"
        writeText(saved, code.isEmpty ? "(no code produced)\n" : code)
        writeText(saved + ".log", "test: \(step.test)\n\n\(output ?? "")")
        let restored: String
        if existed {
            writeText(step.file, original!)
            restored = "\(step.file) restored"
        } else {
            try? FileManager.default.removeItem(atPath: step.file)
            restored = "\(step.file) removed (did not exist before)"
        }
        let failure = StepFailure(id: step.id, test: step.test, output: output ?? "", saved: saved, log: saved + ".log",
                                  restored: restored, attempts: attempts)
        return (row("FAIL", attempts), failure)
    }
}
