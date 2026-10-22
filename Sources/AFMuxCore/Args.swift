import Foundation

public struct Options: Equatable, Sendable {
    public var job: String?
    public var instructions: String?
    public var labels: String?
    public var schema: String?
    public var guardrails = "permissive-content-transformations"
    public var guardrailsGiven = false
    public var useCase = "general"
    public var useCaseGiven = false
    public var timeout: Double = 120
    public var budget = 7168
    public var chunk = false
    public var maxChunks = 8
    public var list = false
    public var help = false
    public var toolsFS = false
    public var toolsFile: String?
    public var maxToolCalls = 8
    public var toolOutputBudget = 600
    public var toolTimeout: Double = 30
    public var session: String?

    public init() {}

    public var toolsOn: Bool { toolsFS || toolsFile != nil }
}

public let helpText = usageLine + """


options:
  --labels a,b,c            classify only: the allowed labels
  --schema FILE             JSON schema for structured output (fm format or plain JSON Schema)
  --guardrails LEVEL        default | permissive-content-transformations (default)
  --use-case CASE           general (default) | content-tagging
  --timeout SECONDS         per model call (default 120)
  --budget TOKENS           instructions + input + schema per call (default 7168)
  --chunk                   split over-budget input into pieces
  --max-chunks N            with --chunk (default 8)
  --tools fs                built-in tools: read_file, grep, list_dir
  --tools-file FILE         caller-defined command tools
  --max-tool-calls N        per model call (default 8)
  --tool-output-budget N    tokens per tool result (default 600)
  --tool-timeout SECONDS    per tool call (default 30)
  --session NAME            keep a transcript across calls
  --list                    list presets
  -h, --help                show this help

  afm sessions              list sessions
  afm sessions rm NAME      delete a session

"""

private let valueOptions: Set<String> = [
    "--labels", "--schema", "--guardrails", "--use-case", "--timeout", "--budget", "--max-chunks",
    "--tools", "--tools-file", "--max-tool-calls", "--tool-output-budget", "--tool-timeout", "--session",
]
private let flagOptions: Set<String> = ["--chunk", "--list", "--help"]

/// An argparse-style error: the message, then the usage line.
public func usageError(_ message: String) -> AfmError {
    AfmError(.usage, message + "\n" + usageLine)
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
            case "--chunk": o.chunk = true
            case "--list": o.list = true
            default: o.help = true
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
    if positionals.count > 0 { o.job = positionals[0].1 }
    if positionals.count > 1 { o.instructions = positionals[1].1 }
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
    case "--labels": o.labels = v
    case "--schema": o.schema = v
    case "--guardrails": o.guardrails = v; o.guardrailsGiven = true
    case "--use-case": o.useCase = v; o.useCaseGiven = true
    case "--timeout": o.timeout = try float(name, v)
    case "--budget": o.budget = try int(name, v)
    case "--max-chunks": o.maxChunks = try int(name, v)
    case "--tools":
        guard v == "fs" else { throw AfmError(.usage, "--tools accepts only fs") }
        o.toolsFS = true
    case "--tools-file": o.toolsFile = v
    case "--max-tool-calls": o.maxToolCalls = try int(name, v)
    case "--tool-output-budget": o.toolOutputBudget = try int(name, v)
    case "--tool-timeout": o.toolTimeout = try float(name, v)
    case "--session": o.session = v
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

private func validate(_ o: Options) throws {
    func positive(_ x: Double) -> Bool { x > 0 && !x.isInfinite }
    if !positive(o.timeout) { throw AfmError(.usage, "--timeout must be a positive number of seconds") }
    if o.budget < 1 { throw AfmError(.usage, "--budget must be at least 1") }
    if o.maxChunks < 1 { throw AfmError(.usage, "--max-chunks must be at least 1") }
    if !["default", "permissive-content-transformations"].contains(o.guardrails) {
        throw AfmError(.usage, "--guardrails must be default or permissive-content-transformations")
    }
    if !["general", "content-tagging"].contains(o.useCase) {
        throw AfmError(.usage, "--use-case must be general or content-tagging")
    }
    if o.maxToolCalls < 1 { throw AfmError(.usage, "--max-tool-calls must be at least 1") }
    if o.toolOutputBudget < 1 { throw AfmError(.usage, "--tool-output-budget must be at least 1") }
    if !positive(o.toolTimeout) { throw AfmError(.usage, "--tool-timeout must be a positive number of seconds") }
}
