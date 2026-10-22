import Foundation

public let usageText = "afm run <steps-dir> [--retries N] [--timeout S] [--budget T] [--json] | afm step <step-file> [options] | afm read <file> --ask \"question\" [--chunk-tokens N] [--json]"

public struct Options: Equatable, Sendable {
    public var command: String?
    public var target: String?
    public var asks: [String] = []
    public var chunkTokens = 600
    public var retries = 1
    public var timeout: Double = 120
    public var budget = 7168
    public var json = false
    public var help = false
    // afmux-swift additions (MinionS ideas); defaults keep afmux's behaviour
    public var samples = 1
    public var split = false
    public var lines: ClosedRange<Int>?

    public init() {}
}

public let helpText = """
usage: \(usageText)

Implement agent-written, test-gated steps on the on-device Apple Foundation Model.

positional arguments:
  {run,step,read}       run: every step in a directory in filename order; step: one step file; read: answer a question about a file chunk by chunk
  target                the steps directory (run), the step file (step), or the document (read)

options:
  -h, --help            show this help message and exit
  --ask ASK             read: the question to answer from the file (repeat to ask several)
  --chunk-tokens CHUNK_TOKENS
                        read: target size of each chunk the model sees (default 600)
  --retries RETRIES     retries per step, each shown the failing test output (default 1)
  --timeout TIMEOUT     seconds per model call (default 120)
  --budget BUDGET       maximum prompt tokens per call (default 7168)
  --json                machine-readable report on stdout
  --samples K           run/step: after a failing greedy attempt, test up to K-1 seeded samples before retrying (default 1)
  --split               run/step: generate a new module one function at a time, then test it whole
  --lines A-B           read: read only lines A to B (citations keep the file's line numbers)

step file (steps/01-name.md), header then --- then the spec:
  file: src/util.py                          the one file this step writes (relative to the current directory)
  test: python3 -m unittest tests.test_util  run from the current directory; exit 0 means the step passed
  context: src/types.py, src/errors.py       optional, comma-separated read-only files shown to the model
  ---
  Write a Python function ...

A step whose test already passes against the current file is reported as done and not regenerated,
so reruns skip finished steps and leave hand-written ones alone. On a final failure the original file
is restored (or a new one removed) and the attempt is kept at <file>.afm-failed with the test output
at <file>.afm-failed.log. Exit codes: 0 all passed, 1 a step failed, 2 usage, 4 fm unavailable,
5 sandbox, 6 a step's prompt over budget.

"""

private let valueOptions: Set<String> = ["--ask", "--chunk-tokens", "--retries", "--timeout", "--budget", "--samples", "--lines"]
private let flagOptions: Set<String> = ["--json", "--help", "--split"]
private let commands = ["run", "step", "read"]

/// An argparse-style error: the message, then the usage line (afmux's _Parser.error).
func usageError(_ message: String) -> AfmError {
    AfmError(.usage, message + "\nusage: " + usageText)
}

/// argparse treats "-x..." as an option unless it is a negative number or contains a space.
private func looksLikeOption(_ a: String) -> Bool {
    guard a.hasPrefix("-"), a != "-" else { return false }
    if a.contains(" ") { return false }
    if Double(a) != nil { return false }
    return true
}

public func parseArgs(_ argv: [String]) throws -> Options {
    var o = Options()
    // (argv index, text), so leftovers are reported in argv order as argparse does
    var positionals: [(Int, String)] = []
    var unrecognized: [(Int, String)] = []
    var afterDashDash = false
    var i = 0
    while i < argv.count {
        let arg = argv[i]
        let at = i
        i += 1
        if afterDashDash || (arg != "--" && !looksLikeOption(arg)) {
            positionals.append((at, arg))
            continue
        }
        if arg == "--" {
            afterDashDash = true
            continue
        }
        var name = arg
        var inline: String?
        if let eq = arg.firstIndex(of: "=") {
            name = String(arg[..<eq])
            inline = String(arg[arg.index(after: eq)...])
        }
        if name == "-h" { name = "--help" }
        if flagOptions.contains(name) {
            if let inline { throw usageError("argument \(name): ignored explicit argument \(pyRepr(inline))") }
            switch name {
            case "--json": o.json = true
            case "--split": o.split = true
            default:
                // argparse prints help as soon as it reaches -h, before checking what follows.
                o.help = true
                return o
            }
            continue
        }
        guard valueOptions.contains(name) else {
            unrecognized.append((at, arg))
            continue
        }
        let value: String
        if let inline {
            value = inline
        } else if i < argv.count, !looksLikeOption(argv[i]) {
            value = argv[i]
            i += 1
        } else {
            throw usageError("argument \(name): expected one argument")
        }
        try apply(name, value, to: &o)
    }
    if let (_, command) = positionals.first {
        guard commands.contains(command) else {
            throw usageError("argument command: invalid choice: \(pyRepr(command)) (choose from 'run', 'step', 'read')")
        }
        o.command = command
    }
    if positionals.count > 1 { o.target = positionals[1].1 }
    unrecognized += positionals.dropFirst(2)
    if !unrecognized.isEmpty {
        let leftovers = unrecognized.sorted { $0.0 < $1.0 }.map(\.1)
        throw usageError("unrecognized arguments: " + leftovers.joined(separator: " "))
    }
    try validate(o)
    return o
}

private func apply(_ name: String, _ v: String, to o: inout Options) throws {
    switch name {
    case "--ask": o.asks.append(v)
    case "--chunk-tokens": o.chunkTokens = try int(name, v)
    case "--retries": o.retries = try int(name, v)
    case "--timeout": o.timeout = try float(name, v)
    case "--budget": o.budget = try int(name, v)
    case "--samples": o.samples = try int(name, v)
    case "--lines":
        let parts = v.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 2, let a = Int(parts[0]), let b = Int(parts[1]), a >= 1, a <= b else {
            throw AfmError(.usage, "--lines must be A-B with 1 <= A <= B")
        }
        o.lines = a...b
    default: break
    }
}

private func int(_ name: String, _ v: String) throws -> Int {
    guard let n = Int(v.trimmingCharacters(in: .whitespaces)) else {
        throw usageError("argument \(name): invalid int value: \(pyRepr(v))")
    }
    return n
}

private func float(_ name: String, _ v: String) throws -> Double {
    guard let x = Double(v.trimmingCharacters(in: .whitespaces)) else {
        throw usageError("argument \(name): invalid float value: \(pyRepr(v))")
    }
    return x
}

/// afmux's parse_args checks, in its order.
private func validate(_ o: Options) throws {
    guard let command = o.command, let target = o.target, !target.isEmpty else {
        throw AfmError(.usage, "usage: " + usageText)
    }
    if o.retries < 0 { throw AfmError(.usage, "--retries must be 0 or more") }
    if !(o.timeout > 0) || o.timeout.isInfinite { throw AfmError(.usage, "--timeout must be a positive number of seconds") }
    if o.budget < 1 { throw AfmError(.usage, "--budget must be at least 1") }
    if command == "read" {
        if o.asks.isEmpty || o.asks.contains(where: { $0.stripped().isEmpty }) {
            throw AfmError(.usage, "read needs --ask \"question\"")
        }
        if o.chunkTokens < 50 { throw AfmError(.usage, "--chunk-tokens must be at least 50") }
    }
    if o.samples < 1 { throw AfmError(.usage, "--samples must be at least 1") }
}
