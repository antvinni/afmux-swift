# afmux-swift v1 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A Swift `afm` binary that is a drop-in replacement for afmux's Python `afm` (afmux commit `e814b9e`), calling FoundationModels in-process, plus built-in and caller-defined tools and persistent sessions with automatic compaction.

**Architecture:** SwiftPM package, library `AFMuxCore` (all logic) and a thin executable `afm`. One process per call; sessions are JSON files. The framework is isolated behind a `Backend` protocol (model factory, `TokenCounter`, availability) with a system implementation and a scripted fake, so every path is testable without the model.

**Tech Stack:** Swift 6.4 toolchain (Command Line Tools), Swift language mode 5, FoundationModels (macOS 27), Swift Testing, no third-party dependencies.

**Spec:** `docs/superpowers/specs/2026-10-22-afmux-swift-design.md`. Reference implementation: afmux `e814b9e` (`scripts/afm`, `presets/`, `tests/test_afm.py`); read it with `git -C ../afmux show e814b9e:scripts/afm`.

## Global Constraints

- Platform `macOS("27.0")`; `swift-tools-version: 6.0`; every target uses `.swiftLanguageMode(.v5)`.
- No dependencies outside the SDK.
- Exit codes: 0 ok, 1 model failed, 2 usage, 3 bad JSON or label, 4 unavailable, 5 sandbox, 6 over budget.
- Every error goes to stderr as `afm: <message>\n`; nothing on stdout on a non-zero exit.
- Messages that afmux `e814b9e` emits are reproduced word for word (spec, "Pinned stderr messages").
- Defaults: `--guardrails permissive-content-transformations`, `--use-case general`, `--timeout 120` (per model call and per count), `--budget 7168`, `--max-chunks 8`, `--max-tool-calls 8`, `--tool-output-budget 600`, `--tool-timeout 30`.
- Greedy decoding: `GenerationOptions(samplingMode: .greedy, maximumResponseTokens: …)` (`sampling:` is deprecated).
- Hidden test hooks: `AFMUX_FAKE=<script.json>` selects the fake backend; `AFMUX_SESSIONS_DIR` overrides the session directory.
- Build and test with `swift build && swift test` from the repo root (CLI tests run `.build/debug/afm`).
- Commits end with `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`. Never name analysed repositories or other accounts in commits or files.

## Step 0 results (done, see spec)

Builds without entitlements, about 270 ms per one-word call (approach B not needed); FakeModel drives the tool loop; transcripts round-trip; `fm`-format schemas decode, plain JSON Schema needs the converter; `GeneratedContent.jsonString` is not compact; tools are counted through the instructions entry; cancellation is immediate; Swift Testing runs under the CLT; a fake answer outside an enum passes through (so the label check is still needed); non-JSON output throws `GeneratedContent.ParsingError` with `rawContent`; `orderedKeys` does not follow the source text for keys outside the schema.

## File map

| File | Responsibility |
|---|---|
| `Package.swift` | targets and settings |
| `presets/*.md` | preset texts, copied from afmux `e814b9e` |
| `Sources/AFMuxCore/Exit.swift` | `Exit`, `AfmError`, `usageLine`, `String.rstripped()` |
| `Sources/AFMuxCore/PythonRepr.swift` | `pyRepr`, `pyG` |
| `Sources/AFMuxCore/Presets.swift` | preset constants, `--list` text |
| `Sources/AFMuxCore/Args.swift` | `Options`, `parseArgs`, `helpText` |
| `Sources/AFMuxCore/Job.swift` | `Job`, `parseLabels`, `resolveJob`, `checkSchemaFile`, `checkNewCombos`, `callShape` |
| `Sources/AFMuxCore/Input.swift` | `InputSource`, `StandardInput`, `decodeInput`, `readInput` |
| `Sources/AFMuxCore/JSONOut.swift` | `compactJSON` |
| `Sources/AFMuxCore/Schema.swift` | `SchemaLoader` (decode, converter, classify, order, jsonText), `SchemaProblem` |
| `Sources/AFMuxCore/Transcripts.swift` | `instructionsEntry`, `text(of:)`, `entryText` |
| `Sources/AFMuxCore/TokenCounter.swift` | `TokenCounter`, `SystemTokenCounter`, `TimedCounter` |
| `Sources/AFMuxCore/Timeout.swift` | `withTimeout` |
| `Sources/AFMuxCore/Backend.swift` | `Backend`, `SystemBackend` |
| `Sources/AFMuxCore/Fake.swift` | `FakeScript`, `FakeState`, `FakeTokenCounter`, `FakeModel`, `FakeExecutor`, `FakeBackend`, `fakeError` |
| `Sources/AFMuxCore/Runner.swift` | `ModelCall`, `ModelAnswer`, `runModel` |
| `Sources/AFMuxCore/Errors.swift` | `ToolCapExceeded`, `isSandboxError`, `mapError` |
| `Sources/AFMuxCore/Chunker.swift` | `splitUnits`, `planChunks` |
| `Sources/AFMuxCore/App.swift` | `IO`, `runAfm`, `runOnce`, `answer`, `checkedAnswer`, `jobSchema`, `checkBudget` |
| `Sources/AFMuxCore/Proc.swift` | `runProcess`, `ProcResult`, `ProcessGroups` |
| `Sources/AFMuxCore/Tools.swift` | `ToolContext`, `ToolOutput`, `AfmTool`, `Toolset` |
| `Sources/AFMuxCore/BuiltinTools.swift` | `read_file`, `grep`, `list_dir` |
| `Sources/AFMuxCore/CommandTools.swift` | `ToolSpec`, `loadToolsFile`, `substitute`, `commandTool` |
| `Sources/AFMuxCore/Cleanup.swift` | `TempFiles` |
| `Sources/AFMuxCore/Session.swift` | `SessionFile`, `SessionStore`, `sessionsCommand` |
| `Sources/AFMuxCore/SessionTurn.swift` | `runSessionTurn` |
| `Sources/AFMuxCore/Compaction.swift` | `Compaction`, `render`, `summaryEntries`, `compactionInstructions` |
| `Sources/AFMuxCore/Signals.swift` | `Signals.install` |
| `Sources/afm/main.swift` | backend selection, signals, `runAfm` |
| `Tests/AFMuxCoreTests/*` | unit tests |
| `Tests/CLITests/Harness.swift` | runs the built binary in fake mode |
| `Tests/CLITests/*` | ported afmux tests and new-feature CLI tests |
| `Tests/IntegrationTests/*` | real-model tests, skipped when unusable |

---

### Task 1: Package skeleton, exit codes, Python repr

**Files:**
- Create: `Package.swift`, `.gitignore`, `Sources/AFMuxCore/Exit.swift`, `Sources/AFMuxCore/PythonRepr.swift`, `Sources/afm/main.swift`
- Test: `Tests/AFMuxCoreTests/PythonReprTests.swift`

**Interfaces:**
- Produces: `enum Exit: Int32 { ok, model, usage, json, unavailable, sandbox, budget }`, `struct AfmError: Error, Equatable { code: Exit; message: String; init(_:_:) }`, `let usageLine: String`, `extension String { func rstripped() -> String }`, `func pyRepr(_ s: String?) -> String`, `func pyG(_ x: Double) -> String`.

- [ ] **Step 1: Write the package and the failing test**

`Package.swift`:

```swift
// swift-tools-version: 6.0
import PackageDescription

let v5: [SwiftSetting] = [.swiftLanguageMode(.v5)]

let package = Package(
    name: "afmux-swift",
    platforms: [.macOS("27.0")],
    products: [.executable(name: "afm", targets: ["afm"])],
    targets: [
        .target(name: "AFMuxCore", swiftSettings: v5),
        .executableTarget(name: "afm", dependencies: ["AFMuxCore"], swiftSettings: v5),
        .testTarget(name: "AFMuxCoreTests", dependencies: ["AFMuxCore"], swiftSettings: v5),
    ]
)
```

`.gitignore`:

```
.build/
.swiftpm/
```

`Sources/afm/main.swift` (placeholder until Task 8):

```swift
import AFMuxCore

print(usageLine)
```

`Tests/AFMuxCoreTests/PythonReprTests.swift`:

```swift
import Testing
@testable import AFMuxCore

@Test(arguments: [
    ("abc", "'abc'"),
    ("it's", "\"it's\""),
    ("say \"hi\"", "'say \"hi\"'"),
    ("both ' and \"", "'both \\' and \"'"),
    ("a\\b", "'a\\\\b'"),
    ("tab\there\nnl\r", "'tab\\there\\nnl\\r'"),
    ("caf\u{e9}", "'caf\u{e9}'"),
    ("\u{7}", "'\\x07'"),
    ("\u{200b}", "'\\u200b'"),
    ("\u{1F600}", "'\u{1F600}'"),
])
func reprMatchesPython(input: String, expected: String) {
    #expect(pyRepr(input) == expected)
}

@Test func reprOfNilIsNone() {
    #expect(pyRepr(nil) == "None")
}

@Test func percentGMatchesPython() {
    #expect(pyG(120) == "120")
    #expect(pyG(0.5) == "0.5")
    #expect(pyG(1e-7) == "1e-07")
}

@Test func rstrippedRemovesTrailingWhitespaceOnly() {
    #expect("  a b \n\n\t".rstripped() == "  a b")
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `swift test --filter PythonReprTests`
Expected: compile failure, `cannot find 'pyRepr' in scope`.

- [ ] **Step 3: Implement**

`Sources/AFMuxCore/Exit.swift`:

```swift
import Foundation

public enum Exit: Int32, Sendable {
    case ok = 0
    case model = 1
    case usage = 2
    case json = 3
    case unavailable = 4
    case sandbox = 5
    case budget = 6
}

public struct AfmError: Error, Equatable, Sendable {
    public var code: Exit
    public var message: String

    public init(_ code: Exit, _ message: String) {
        self.code = code
        self.message = message
    }
}

public let usageLine = "usage: afm <preset> [options] < input | afm ask \"<instructions>\" [options] < input | afm --list"

extension String {
    /// Python's str.rstrip() with no argument.
    public func rstripped() -> String {
        var s = Substring(self)
        while let last = s.last, last.isWhitespace { s.removeLast() }
        return String(s)
    }
}
```

`Sources/AFMuxCore/PythonRepr.swift`:

```swift
import Foundation

/// Python's repr() of a str ("None" for nil), so messages match afmux byte for byte.
public func pyRepr(_ s: String?) -> String {
    guard let s else { return "None" }
    let quote: Unicode.Scalar = (s.contains("'") && !s.contains("\"")) ? "\"" : "'"
    var out = String(quote)
    for u in s.unicodeScalars {
        switch u {
        case "\\": out += "\\\\"
        case "\n": out += "\\n"
        case "\r": out += "\\r"
        case "\t": out += "\\t"
        case quote: out += "\\" + String(quote)
        default:
            if isPrintable(u) { out.unicodeScalars.append(u) } else { out += hexEscape(u) }
        }
    }
    out.unicodeScalars.append(quote)
    return out
}

/// Python's "%g" formatting.
public func pyG(_ x: Double) -> String {
    String(format: "%g", x)
}

private func isPrintable(_ u: Unicode.Scalar) -> Bool {
    if u == " " { return true }
    switch u.properties.generalCategory {
    case .control, .format, .surrogate, .privateUse, .unassigned,
         .lineSeparator, .paragraphSeparator, .spaceSeparator:
        return false
    default:
        return true
    }
}

private func hexEscape(_ u: Unicode.Scalar) -> String {
    let v = u.value
    if v <= 0xff { return String(format: "\\x%02x", v) }
    if v <= 0xffff { return String(format: "\\u%04x", v) }
    return String(format: "\\U%08x", v)
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `swift test --filter PythonReprTests`
Expected: all tests pass.

- [ ] **Step 5: Commit**

```bash
git add Package.swift .gitignore Sources Tests
git commit -m "Add package skeleton, exit codes and Python repr"
```

---

### Task 2: Presets and argument parsing

**Files:**
- Create: `presets/summarise.md`, `presets/classify.md`, `presets/extract.md`, `presets/commit-msg.md` (copies), `Sources/AFMuxCore/Presets.swift`, `Sources/AFMuxCore/Args.swift`
- Test: `Tests/AFMuxCoreTests/PresetsTests.swift`, `Tests/AFMuxCoreTests/ArgsTests.swift`

**Interfaces:**
- Consumes: `AfmError`, `usageLine`, `pyRepr` (Task 1).
- Produces: `enum Presets { static let names: [String]; static let texts: [String: String]; static func listing() -> String }`; `struct Options` (fields below); `func parseArgs(_ argv: [String]) throws -> Options`; `let helpText: String`; `func usageError(_ message: String) -> AfmError`.

- [ ] **Step 1: Copy the presets**

```bash
for p in summarise classify extract commit-msg; do git -C ../afmux show e814b9e:presets/$p.md > presets/$p.md; done
```

- [ ] **Step 2: Write the failing tests**

`Tests/AFMuxCoreTests/PresetsTests.swift`:

```swift
import Foundation
import Testing
@testable import AFMuxCore

let packageRoot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

@Test func presetConstantsMatchFiles() throws {
    for name in Presets.names {
        let file = try String(contentsOf: packageRoot.appendingPathComponent("presets/\(name).md"), encoding: .utf8)
        #expect(Presets.texts[name] == file.trimmingCharacters(in: .whitespacesAndNewlines), "\(name)")
    }
}

@Test func listingIsSortedAndPadded() {
    let lines = Presets.listing().split(separator: "\n").map(String.init)
    #expect(lines.map { $0.split(separator: " ")[0] } == ["classify", "commit-msg", "extract", "summarise"])
    #expect(lines[3].hasPrefix("summarise    Summarise the input"))
    #expect(Presets.listing().hasSuffix("\n"))
}
```

`Tests/AFMuxCoreTests/ArgsTests.swift`:

```swift
import Testing
@testable import AFMuxCore

private func usageMessage(_ argv: [String]) -> String? {
    do { _ = try parseArgs(argv); return nil } catch let e as AfmError {
        #expect(e.code == .usage)
        return e.message
    } catch { return "\(error)" }
}

@Test func defaults() throws {
    let o = try parseArgs(["summarise"])
    #expect(o.job == "summarise")
    #expect(o.guardrails == "permissive-content-transformations" && !o.guardrailsGiven)
    #expect(o.useCase == "general" && o.timeout == 120 && o.budget == 7168 && o.maxChunks == 8)
    #expect(o.maxToolCalls == 8 && o.toolOutputBudget == 600 && o.toolTimeout == 30 && !o.toolsOn)
}

@Test func equalsFormAndOptionsAfterPositionals() throws {
    let o = try parseArgs(["ask", "Extract.", "--schema=s.json", "--budget", "100", "--chunk"])
    #expect(o.job == "ask" && o.instructions == "Extract." && o.schema == "s.json" && o.budget == 100 && o.chunk)
}

@Test func dashDashEndsOptions() throws {
    let o = try parseArgs(["ask", "--", "--list"])
    #expect(o.instructions == "--list" && !o.list)
}

@Test func dashWithSpaceIsPositional() throws {
    #expect(try parseArgs(["ask", "-v: reply ok"]).instructions == "-v: reply ok")
}

@Test func negativeNumberIsAValue() {
    #expect(usageMessage(["summarise", "--timeout", "-1"]) == "--timeout must be a positive number of seconds")
}

@Test func argparseMessages() {
    #expect(usageMessage(["summarise", "--budget", "x"]) == "argument --budget: invalid int value: 'x'\n" + usageLine)
    #expect(usageMessage(["summarise", "--timeout", "soon"]) == "argument --timeout: invalid float value: 'soon'\n" + usageLine)
    #expect(usageMessage(["extract", "--schema"]) == "argument --schema: expected one argument\n" + usageLine)
    #expect(usageMessage(["ask", "a", "b", "--nope", "c"]) == "unrecognized arguments: b --nope c\n" + usageLine)
    #expect(usageMessage(["summarise", "--chunk=yes"]) == "argument --chunk: ignored explicit argument 'yes'\n" + usageLine)
    #expect(usageMessage(["summarise", "--help=x"]) == "argument --help: ignored explicit argument 'x'\n" + usageLine)
}

@Test func afmuxValidation() {
    #expect(usageMessage(["summarise", "--timeout", "0"]) == "--timeout must be a positive number of seconds")
    #expect(usageMessage(["summarise", "--timeout", "nan"]) == "--timeout must be a positive number of seconds")
    #expect(usageMessage(["summarise", "--timeout", "inf"]) == "--timeout must be a positive number of seconds")
    #expect(usageMessage(["summarise", "--budget", "0"]) == "--budget must be at least 1")
    #expect(usageMessage(["summarise", "--max-chunks", "0"]) == "--max-chunks must be at least 1")
}

@Test func newOptionValidation() {
    #expect(usageMessage(["summarise", "--guardrails", "loose"]) == "--guardrails must be default or permissive-content-transformations")
    #expect(usageMessage(["summarise", "--use-case", "x"]) == "--use-case must be general or content-tagging")
    #expect(usageMessage(["ask", "x", "--tools", "net"]) == "--tools accepts only fs")
    #expect(usageMessage(["ask", "x", "--max-tool-calls", "0"]) == "--max-tool-calls must be at least 1")
    #expect(usageMessage(["ask", "x", "--tool-output-budget", "0"]) == "--tool-output-budget must be at least 1")
    #expect(usageMessage(["ask", "x", "--tool-timeout", "0"]) == "--tool-timeout must be a positive number of seconds")
}

@Test func helpAndList() throws {
    #expect(try parseArgs(["-h"]).help)
    #expect(try parseArgs(["--list"]).list)
    #expect(helpText.hasPrefix(usageLine))
}

@Test func newOptionsParse() throws {
    let o = try parseArgs(["ask", "q", "--tools", "fs", "--tools-file", "t.json", "--session", "s1",
                           "--max-tool-calls", "3", "--tool-output-budget", "50", "--tool-timeout", "2.5",
                           "--guardrails", "default", "--use-case", "content-tagging"])
    #expect(o.toolsFS && o.toolsFile == "t.json" && o.session == "s1" && o.toolsOn)
    #expect(o.maxToolCalls == 3 && o.toolOutputBudget == 50 && o.toolTimeout == 2.5)
    #expect(o.guardrails == "default" && o.guardrailsGiven && o.useCase == "content-tagging" && o.useCaseGiven)
}
```

- [ ] **Step 3: Run the tests to verify they fail**

Run: `swift test --filter "PresetsTests|ArgsTests"`
Expected: compile failure, `cannot find 'Presets' in scope`.

- [ ] **Step 4: Implement**

`Sources/AFMuxCore/Presets.swift` (texts copied verbatim from the files):

```swift
import Foundation

public enum Presets {
    public static let names = ["summarise", "classify", "extract", "commit-msg"]

    /// afmux e814b9e presets/*.md, stripped. PresetsTests keeps these equal to the files.
    public static let texts: [String: String] = [
        "summarise": "Summarise the input in three to five plain sentences. State what it is about and the main points. Do not add opinions, headings or bullet points.",
        "classify": "Classify the input into exactly one of these labels: {labels}. Choose the label that fits best overall. Answer with the label only.",
        "extract": "Extract the requested fields from the input. Use only information present in the input. If a field is not present, use an empty string for text or 0 for numbers.",
        "commit-msg": #"Write a git commit message for this diff. The first line is a subject like "fix(parser): handle empty input" or "docs: explain exit codes": a type (feat, fix, docs, test, refactor, chore), an optional scope in parentheses, a colon, then a short imperative summary, all under 72 characters. If the change needs explanation, add a blank line and one short paragraph saying why. Output only the commit message, with no quotes, markdown or commentary."#,
    ]

    /// `afm --list`: afmux's "%-12s %s" of each name and its first line, sorted by name.
    public static func listing() -> String {
        texts.keys.sorted().map { name in
            let first = texts[name]!.split(separator: "\n", omittingEmptySubsequences: false).first.map(String.init) ?? ""
            let padded = name.count >= 12 ? name : name + String(repeating: " ", count: 12 - name.count)
            return padded + " " + first.trimmingCharacters(in: .whitespaces) + "\n"
        }.joined()
    }
}
```

`Sources/AFMuxCore/Args.swift`:

```swift
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
    var positionals: [String] = []
    var unrecognized: [String] = []
    var afterDashDash = false
    var i = 0
    while i < argv.count {
        let arg = argv[i]
        i += 1
        if afterDashDash || (arg != "--" && !looksLikeOption(arg)) {
            positionals.append(arg)
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
            unrecognized.append(arg)
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
    if positionals.count > 0 { o.job = positionals[0] }
    if positionals.count > 1 { o.instructions = positionals[1] }
    unrecognized += positionals.dropFirst(2)
    if !unrecognized.isEmpty {
        throw usageError("unrecognized arguments: " + unrecognized.joined(separator: " "))
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
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `swift test --filter "PresetsTests|ArgsTests"`
Expected: all pass.

- [ ] **Step 6: Commit**

```bash
git add presets Sources/AFMuxCore/Presets.swift Sources/AFMuxCore/Args.swift Tests/AFMuxCoreTests
git commit -m "Add presets and afmux-compatible argument parsing"
```

---

### Task 3: Job resolution and input

**Files:**
- Create: `Sources/AFMuxCore/Job.swift`, `Sources/AFMuxCore/Input.swift`
- Test: `Tests/AFMuxCoreTests/JobTests.swift`

**Interfaces:**
- Consumes: `Options`, `parseArgs`, `Presets`, `AfmError`, `usageLine`, `pyRepr`.
- Produces: `struct Job { name: String; instructions: String; labels: [String]?; schemaPath: String? }`; `func parseLabels(_:) throws -> [String]`; `func resolveJob(_: Options) throws -> Job`; `func checkSchemaFile(_ path: String) throws`; `func checkNewCombos(_: Options) throws`; `let toolUseInstructions: String`; `func callShape(job: Job, input: String?) -> (instructions: String, prompt: String)`; `protocol InputSource: Sendable { var isTerminal: Bool { get }; func readAll() -> Data }`; `struct StandardInput: InputSource`; `func decodeInput(_ data: Data) -> String`; `func readInput(_ src: any InputSource, optional: Bool = false) throws -> String?`.

- [ ] **Step 1: Write the failing tests**

`Tests/AFMuxCoreTests/JobTests.swift`:

```swift
import Foundation
import Testing
@testable import AFMuxCore

struct StubInput: InputSource {
    var isTerminal = false
    var data = Data()
    func readAll() -> Data { data }
}

private func jobError(_ argv: [String]) -> String? {
    do { _ = try resolveJob(try parseArgs(argv)); return nil } catch let e as AfmError {
        #expect(e.code == .usage)
        return e.message
    } catch { return "\(error)" }
}

@Test func usageMessagesMatchAfmux() {
    #expect(jobError([]) == usageLine)
    #expect(jobError(["ask"]) == "ask needs instructions as its argument")
    #expect(jobError(["summarise", "extra"]) == "unexpected argument 'extra' (only ask takes instructions)")
    #expect(jobError(["nosuch"]) == "unknown preset 'nosuch'; run afm --list")
    #expect(jobError(["classify"]) == "classify needs --labels a,b,c")
    #expect(jobError(["classify", "--labels", "a,b", "--schema", "x.json"]) == "--schema is not allowed with classify (its schema is generated)")
    #expect(jobError(["summarise", "--labels", "a"]) == "--labels is only for classify")
    #expect(jobError(["extract"]) == "extract needs --schema FILE")
    #expect(jobError(["commit-msg", "--chunk"]) == "--chunk is not allowed with commit-msg; pipe a smaller diff")
    #expect(jobError(["extract", "--schema", "/nonexistent.json"]) == "schema file not found: /nonexistent.json")
}

@Test func labelRules() throws {
    #expect(try parseLabels("bug, feature ,question") == ["bug", "feature", "question"])
    #expect(throws: AfmError(.usage, "empty label in --labels (labels are comma-separated and cannot contain commas)")) { try parseLabels("a,,b") }
    #expect(throws: AfmError(.usage, "duplicate label in --labels")) { try parseLabels("a,b,a") }
    #expect(throws: AfmError(.usage, "label 'b\"c': quotes and backslashes are not allowed in labels")) { try parseLabels("a,b\"c") }
}

@Test func classifySubstitutesLabels() throws {
    let job = try resolveJob(try parseArgs(["classify", "--labels", "bug,feature"]))
    #expect(job.instructions.contains("labels: bug, feature."))
    #expect(job.labels == ["bug", "feature"])
}

@Test func schemaFileMustBeJSONObject() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let bad = dir.appendingPathComponent("bad.json")
    try "{not json".write(to: bad, atomically: true, encoding: .utf8)
    #expect(jobError(["extract", "--schema", bad.path])?.hasPrefix("schema file \(bad.path) is not valid JSON (") == true)
    let list = dir.appendingPathComponent("list.json")
    try "[1]".write(to: list, atomically: true, encoding: .utf8)
    #expect(jobError(["extract", "--schema", list.path]) == "schema file \(list.path) must be a JSON object")
}

@Test func newCombos() throws {
    #expect(throws: AfmError(.usage, "--chunk is not allowed with --session")) { try checkNewCombos(try parseArgs(["ask", "x", "--chunk", "--session", "s"])) }
    #expect(throws: AfmError(.usage, "--chunk is not allowed with tools")) { try checkNewCombos(try parseArgs(["ask", "x", "--chunk", "--tools", "fs"])) }
}

@Test func inputRules() throws {
    #expect(throws: AfmError(.usage, "afm reads its input from stdin; pipe or redirect it")) { try readInput(StubInput(isTerminal: true)) }
    #expect(throws: AfmError(.usage, "input is empty")) { try readInput(StubInput(data: Data("  \n\n".utf8))) }
    #expect(try readInput(StubInput(isTerminal: true), optional: true) == nil)
    #expect(try readInput(StubInput(data: Data()), optional: true) == nil)
    #expect(try readInput(StubInput(data: Data("a\r\nb\rc".utf8))) == "a\nb\nc")
    #expect(try readInput(StubInput(data: Data([0x63, 0x61, 0x66, 0xe9]))) == "caf\u{FFFD}")
}

@Test func callShapes() {
    let job = Job(name: "ask", instructions: "find it", labels: nil, schemaPath: nil)
    #expect(callShape(job: job, input: "text") == ("find it", "text"))
    #expect(callShape(job: job, input: nil) == (toolUseInstructions, "find it"))
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --filter JobTests`
Expected: compile failure, `cannot find 'resolveJob' in scope`.

- [ ] **Step 3: Implement**

`Sources/AFMuxCore/Job.swift`:

```swift
import Foundation

public struct Job: Equatable, Sendable {
    public var name: String
    public var instructions: String
    public var labels: [String]?
    public var schemaPath: String?

    public init(name: String, instructions: String, labels: [String]?, schemaPath: String?) {
        self.name = name
        self.instructions = instructions
        self.labels = labels
        self.schemaPath = schemaPath
    }
}

public let toolUseInstructions = "Answer the request. Use the tools to find the information you need. Reply with only the answer."

/// afmux's parse_labels.
public func parseLabels(_ text: String) throws -> [String] {
    let labels = text.split(separator: ",", omittingEmptySubsequences: false)
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
    if labels.contains(where: \.isEmpty) {
        throw AfmError(.usage, "empty label in --labels (labels are comma-separated and cannot contain commas)")
    }
    if Set(labels).count != labels.count {
        throw AfmError(.usage, "duplicate label in --labels")
    }
    for label in labels where label.contains(where: { "\"'\\".contains($0) }) {
        throw AfmError(.usage, "label \(pyRepr(label)): quotes and backslashes are not allowed in labels")
    }
    return labels
}

/// afmux's check_schema_file, minus the x-order requirement (plain JSON Schema is converted).
public func checkSchemaFile(_ path: String) throws {
    var isDir: ObjCBool = false
    guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir), !isDir.boolValue else {
        throw AfmError(.usage, "schema file not found: \(path)")
    }
    let obj: Any
    do {
        obj = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: path)))
    } catch {
        throw AfmError(.usage, "schema file \(path) is not valid JSON (\(error.localizedDescription))")
    }
    guard obj is [String: Any] else {
        throw AfmError(.usage, "schema file \(path) must be a JSON object")
    }
}

/// afmux's resolve_job.
public func resolveJob(_ o: Options) throws -> Job {
    guard let name = o.job, !name.isEmpty else { throw AfmError(.usage, usageLine) }
    var instructions: String
    if name == "ask" {
        guard let text = o.instructions, !text.isEmpty else {
            throw AfmError(.usage, "ask needs instructions as its argument")
        }
        instructions = text
    } else if let text = Presets.texts[name] {
        if let extra = o.instructions, !extra.isEmpty {
            throw AfmError(.usage, "unexpected argument \(pyRepr(extra)) (only ask takes instructions)")
        }
        instructions = text
    } else {
        throw AfmError(.usage, "unknown preset \(pyRepr(name)); run afm --list")
    }
    var labels: [String]?
    if name == "classify" {
        guard let raw = o.labels, !raw.isEmpty else { throw AfmError(.usage, "classify needs --labels a,b,c") }
        if let schema = o.schema, !schema.isEmpty {
            throw AfmError(.usage, "--schema is not allowed with classify (its schema is generated)")
        }
        labels = try parseLabels(raw)
        instructions = instructions.replacingOccurrences(of: "{labels}", with: labels!.joined(separator: ", "))
    } else if let raw = o.labels, !raw.isEmpty {
        throw AfmError(.usage, "--labels is only for classify")
    }
    if name == "extract" && (o.schema ?? "").isEmpty {
        throw AfmError(.usage, "extract needs --schema FILE")
    }
    if name == "commit-msg" && o.chunk {
        throw AfmError(.usage, "--chunk is not allowed with commit-msg; pipe a smaller diff")
    }
    if let schema = o.schema, !schema.isEmpty {
        try checkSchemaFile(schema)
    }
    return Job(name: name, instructions: instructions, labels: labels, schemaPath: o.schema)
}

/// Usage rules afmux-swift adds on top of afmux's.
public func checkNewCombos(_ o: Options) throws {
    if o.chunk && o.session != nil { throw AfmError(.usage, "--chunk is not allowed with --session") }
    if o.chunk && o.toolsOn { throw AfmError(.usage, "--chunk is not allowed with tools") }
}

/// Instructions and prompt for one call (spec: "Instructions and prompt for each call shape").
public func callShape(job: Job, input: String?) -> (instructions: String, prompt: String) {
    if let input { return (job.instructions, input) }
    return (toolUseInstructions, job.instructions)
}
```

`Sources/AFMuxCore/Input.swift`:

```swift
import Foundation

public protocol InputSource: Sendable {
    var isTerminal: Bool { get }
    func readAll() -> Data
}

public struct StandardInput: InputSource {
    public init() {}
    public var isTerminal: Bool { isatty(0) == 1 }
    public func readAll() -> Data { FileHandle.standardInput.readDataToEndOfFile() }
}

/// UTF-8 with invalid bytes replaced, line endings normalised, as afmux's read_input.
public func decodeInput(_ data: Data) -> String {
    String(decoding: data, as: UTF8.self)
        .replacingOccurrences(of: "\r\n", with: "\n")
        .replacingOccurrences(of: "\r", with: "\n")
}

/// afmux's read_input. With optional: true a terminal or blank input gives nil instead of an error.
public func readInput(_ src: any InputSource, optional: Bool = false) throws -> String? {
    if src.isTerminal {
        if optional { return nil }
        throw AfmError(.usage, "afm reads its input from stdin; pipe or redirect it")
    }
    let text = decodeInput(src.readAll())
    if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        if optional { return nil }
        throw AfmError(.usage, "input is empty")
    }
    return text
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `swift test --filter JobTests`
Expected: all pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/AFMuxCore/Job.swift Sources/AFMuxCore/Input.swift Tests/AFMuxCoreTests/JobTests.swift
git commit -m "Add job resolution and input rules"
```

---

### Task 4: Compact JSON output and schema loading

**Files:**
- Create: `Sources/AFMuxCore/JSONOut.swift`, `Sources/AFMuxCore/Schema.swift`
- Test: `Tests/AFMuxCoreTests/SchemaTests.swift`

**Interfaces:**
- Produces: `func compactJSON(_ c: GeneratedContent, topOrder: [String] = []) -> String`; `struct SchemaProblem: Error { message: String }`; `enum SchemaLoader { static func load(_ data: Data) throws -> GenerationSchema; static func convert(_ root: [String: Any]) throws -> GenerationSchema; static func classify(labels: [String]) -> GenerationSchema; static func order(_: GenerationSchema) -> [String]; static func jsonText(_: GenerationSchema) -> String }`.

- [ ] **Step 1: Write the failing tests**

`Tests/AFMuxCoreTests/SchemaTests.swift`:

```swift
import Foundation
import FoundationModels
import Testing
@testable import AFMuxCore

private func json(_ s: String) throws -> GeneratedContent { try GeneratedContent(json: s) }

@Test func compactFormatting() throws {
    #expect(compactJSON(try json(#"{"a": 1, "b": "two"}"#), topOrder: ["a", "b"]) == #"{"a":1,"b":"two"}"#)
    #expect(compactJSON(try json(#"{"ratio": 0.25, "n": 12, "big": 1e20}"#), topOrder: ["n", "ratio", "big"]) == #"{"n":12,"ratio":0.25,"big":100000000000000000000}"#)
    #expect(compactJSON(try json(#"{"s": "caf\u00e9 / \"q\" \n"}"#), topOrder: ["s"]) == "{\"s\":\"caf\u{e9} / \\\"q\\\" \\n\"}")
    #expect(compactJSON(try json(#"{"k": true, "l": [1, null, "x"]}"#), topOrder: ["k", "l"]) == #"{"k":true,"l":[1,null,"x"]}"#)
}

@Test func schemaOrderThenOthers() throws {
    let c = try json("{\"b\": \"two\", \"a\": 1}")
    #expect(compactJSON(c, topOrder: ["a"]).hasPrefix(#"{"a":1,"#))
}

@Test func fmFormatDecodes() throws {
    let text = #"{"title":"T","type":"object","properties":{"a":{"type":"integer"}},"required":["a"],"x-order":["a"],"additionalProperties":false}"#
    let s = try SchemaLoader.load(Data(text.utf8))
    #expect(s.name == "T")
    #expect(SchemaLoader.order(s) == ["a"])
}

@Test func plainSchemaConverts() throws {
    let text = #"{"type":"object","properties":{"z":{"type":"string"},"b":{"type":"number"},"a":{"type":"boolean","description":"flag"},"tags":{"type":"array","items":{"type":"string"},"maxItems":3},"kind":{"type":"string","enum":["x","y"]},"inner":{"type":"object","properties":{"q":{"type":"integer"}},"required":["q"]}},"required":["z"]}"#
    let s = try SchemaLoader.load(Data(text.utf8))
    #expect(SchemaLoader.order(s) == ["z", "a", "b", "inner", "kind", "tags"])
    #expect(SchemaLoader.jsonText(s).contains(#""enum":["x","y"]"#))
}

@Test func converterProblems() {
    func problem(_ text: String) -> String? {
        do { _ = try SchemaLoader.load(Data(text.utf8)); return nil } catch let p as SchemaProblem { return p.message } catch { return "\(error)" }
    }
    #expect(problem(#"{"type":"object","anyOf":[]}"#) == "unsupported keyword 'anyOf'")
    #expect(problem(#"{"type":"string"}"#) == #"the top level must have "type": "object""#)
    #expect(problem(#"{"type":"object","properties":{"a":{"type":"date"}}}"#) == "unsupported type 'date' at a")
    #expect(problem(#"{"type":"object","properties":{"a":{"type":"array"}}}"#) == #"array needs "items" at a"#)
    #expect(problem("[1]") == "not a JSON object")
}

@Test func classifySchemaHasEnum() {
    let text = SchemaLoader.jsonText(SchemaLoader.classify(labels: ["bug", "feature", "question"]))
    let obj = try! JSONSerialization.jsonObject(with: Data(text.utf8)) as! [String: Any]
    let label = (obj["properties"] as! [String: Any])["label"] as! [String: Any]
    #expect(label["enum"] as? [String] == ["bug", "feature", "question"])
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --filter SchemaTests`
Expected: compile failure, `cannot find 'compactJSON' in scope`.

- [ ] **Step 3: Implement**

`Sources/AFMuxCore/JSONOut.swift`:

```swift
import Foundation
import FoundationModels

/// JSON as afmux prints it: json.dumps(obj, separators=(",", ":"), ensure_ascii=False).
/// Top-level keys follow topOrder (the schema's x-order) first, then the content's own order.
public func compactJSON(_ c: GeneratedContent, topOrder: [String] = []) -> String {
    switch c.kind {
    case .null:
        return "null"
    case .bool(let b):
        return b ? "true" : "false"
    case .number(let d):
        return formatNumber(d)
    case .string(let s):
        return quoteJSON(s)
    case .array(let items):
        return "[" + items.map { compactJSON($0) }.joined(separator: ",") + "]"
    case .structure(let props, let keys):
        let order = topOrder.filter { props[$0] != nil } + keys.filter { !topOrder.contains($0) }
        return "{" + order.map { quoteJSON($0) + ":" + compactJSON(props[$0]!) }.joined(separator: ",") + "}"
    @unknown default:
        return c.jsonString
    }
}

func formatNumber(_ d: Double) -> String {
    if d.isNaN { return "NaN" }
    if d.isInfinite { return d > 0 ? "Infinity" : "-Infinity" }
    if d == d.rounded(), abs(d) < 9_007_199_254_740_992 { return String(Int64(d)) }
    if d == d.rounded(), abs(d) < 1e21 { return String(format: "%.0f", d) }
    return "\(d)"
}

func quoteJSON(_ s: String) -> String {
    var out = "\""
    for u in s.unicodeScalars {
        switch u {
        case "\"": out += "\\\""
        case "\\": out += "\\\\"
        case "\n": out += "\\n"
        case "\r": out += "\\r"
        case "\t": out += "\\t"
        case "\u{8}": out += "\\b"
        case "\u{c}": out += "\\f"
        default:
            if u.value < 0x20 { out += String(format: "\\u%04x", u.value) } else { out.unicodeScalars.append(u) }
        }
    }
    return out + "\""
}
```

`Sources/AFMuxCore/Schema.swift`:

```swift
import Foundation
import FoundationModels

public struct SchemaProblem: Error, Equatable {
    public var message: String
}

private let allowedKeys: Set<String> = [
    "type", "properties", "required", "items", "minItems", "maxItems", "enum",
    "description", "title", "additionalProperties", "x-order",
]

public enum SchemaLoader {
    /// fm's own format first (it needs x-order), then plain JSON Schema through the converter.
    public static func load(_ data: Data) throws -> GenerationSchema {
        if let schema = try? JSONDecoder().decode(GenerationSchema.self, from: data) { return schema }
        guard let obj = try? JSONSerialization.jsonObject(with: data), let dict = obj as? [String: Any] else {
            throw SchemaProblem(message: "not a JSON object")
        }
        return try convert(dict)
    }

    public static func convert(_ root: [String: Any]) throws -> GenerationSchema {
        guard root["type"] as? String == "object" else {
            throw SchemaProblem(message: #"the top level must have "type": "object""#)
        }
        var names = Set<String>()
        let dynamic = try node(root, name: (root["title"] as? String) ?? "Output", path: "", names: &names)
        do {
            return try GenerationSchema(root: dynamic, dependencies: [])
        } catch {
            throw SchemaProblem(message: (error as? LocalizedError)?.errorDescription ?? "\(error)")
        }
    }

    public static func classify(labels: [String]) -> GenerationSchema {
        let root = DynamicGenerationSchema(name: "Classification", properties: [
            .init(name: "label", schema: DynamicGenerationSchema(name: "Label", anyOf: labels)),
        ])
        return try! GenerationSchema(root: root, dependencies: [])
    }

    /// The schema's top-level x-order, for output key order.
    public static func order(_ schema: GenerationSchema) -> [String] {
        guard let data = try? JSONEncoder().encode(schema),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let order = obj["x-order"] as? [String] else { return [] }
        return order
    }

    /// Stable JSON text of a schema, for the fake backend's log and counter.
    public static func jsonText(_ schema: GenerationSchema) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return String(decoding: (try? encoder.encode(schema)) ?? Data(), as: UTF8.self)
    }

    private static func node(_ obj: [String: Any], name: String, path: String, names: inout Set<String>) throws -> DynamicGenerationSchema {
        let at = path.isEmpty ? "" : " at \(path)"
        if let key = obj.keys.sorted().first(where: { !allowedKeys.contains($0) }) {
            throw SchemaProblem(message: "unsupported keyword \(pyRepr(key))\(at)")
        }
        let description = obj["description"] as? String
        if let values = obj["enum"] {
            guard let strings = values as? [String], !strings.isEmpty else {
                throw SchemaProblem(message: "enum must be a non-empty list of strings\(at)")
            }
            return DynamicGenerationSchema(name: unique(name, &names), description: description, anyOf: strings)
        }
        guard let type = obj["type"] as? String else { throw SchemaProblem(message: #"missing "type""# + at) }
        switch type {
        case "string": return DynamicGenerationSchema(type: String.self)
        case "integer": return DynamicGenerationSchema(type: Int.self)
        case "number": return DynamicGenerationSchema(type: Double.self)
        case "boolean": return DynamicGenerationSchema(type: Bool.self)
        case "array":
            guard let items = obj["items"] as? [String: Any] else { throw SchemaProblem(message: #"array needs "items""# + at) }
            let child = try node(items, name: name + "Item", path: path + "[]", names: &names)
            return DynamicGenerationSchema(arrayOf: child, minimumElements: obj["minItems"] as? Int, maximumElements: obj["maxItems"] as? Int)
        case "object":
            let props = obj["properties"] as? [String: Any] ?? [:]
            let required = obj["required"] as? [String] ?? []
            let order = (obj["x-order"] as? [String])
                ?? (required.filter { props[$0] != nil } + props.keys.filter { !required.contains($0) }.sorted())
            var properties: [DynamicGenerationSchema.Property] = []
            for key in order {
                let childPath = path.isEmpty ? key : path + "." + key
                guard let child = props[key] as? [String: Any] else {
                    throw SchemaProblem(message: "property \(pyRepr(key)) must be an object\(at)")
                }
                let schema = try node(child, name: name + "_" + key, path: childPath, names: &names)
                properties.append(.init(name: key, description: child["description"] as? String, schema: schema, isOptional: !required.contains(key)))
            }
            return DynamicGenerationSchema(name: unique(name, &names), description: description, properties: properties)
        default:
            throw SchemaProblem(message: "unsupported type \(pyRepr(type))\(at)")
        }
    }

    private static func unique(_ name: String, _ names: inout Set<String>) -> String {
        var candidate = name
        var k = 2
        while names.contains(candidate) {
            candidate = "\(name)\(k)"
            k += 1
        }
        names.insert(candidate)
        return candidate
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `swift test --filter SchemaTests`
Expected: all pass. If `fmFormatDecodes` reports a different `name`, print `SchemaLoader.jsonText(s)` and fix the expectation to the decoded title, not the loader.

- [ ] **Step 5: Commit**

```bash
git add Sources/AFMuxCore/JSONOut.swift Sources/AFMuxCore/Schema.swift Tests/AFMuxCoreTests/SchemaTests.swift
git commit -m "Add compact JSON output and schema loading"
```

---

### Task 5: Token counting, backends, fake model, model runner

**Files:**
- Create: `Sources/AFMuxCore/Transcripts.swift`, `Sources/AFMuxCore/TokenCounter.swift`, `Sources/AFMuxCore/Timeout.swift`, `Sources/AFMuxCore/Backend.swift`, `Sources/AFMuxCore/Fake.swift`, `Sources/AFMuxCore/Runner.swift`
- Test: `Tests/AFMuxCoreTests/RunnerTests.swift`

**Interfaces:**
- Consumes: `compactJSON`, `SchemaLoader`, `AfmError`, `pyG`.
- Produces:
  - `func instructionsEntry(_ text: String, tools: [any Tool]) -> Transcript.Instructions`, `func text(of: [Transcript.Segment]) -> String`, `func entryText(_: Transcript.Entry) -> String`.
  - `protocol TokenCounter: Sendable { var contextSize: Int; func count(prompt: String, instructions: Transcript.Instructions?) async throws -> Int; func count(schema: GenerationSchema) async throws -> Int; func count(entries: [Transcript.Entry]) async throws -> Int }`, `SystemTokenCounter`, `TimedCounter(base:timeout:)`.
  - `func withTimeout<T: Sendable>(_ seconds: Double, _ body: @escaping @Sendable () async throws -> T) async throws -> T`.
  - `protocol Backend: Sendable { var counter: any TokenCounter { get }; func model(guardrails: String, useCase: String) -> any LanguageModel; func isAvailable() -> Bool }`, `SystemBackend`, `FakeBackend(scriptPath:)`, `FakeBackend(script:)`.
  - `struct FakeScript: Codable` (fields below), `func fakeError(_ spec: String) -> Error`.
  - `struct ModelCall { instructions; history; prompt; schema; tools; maxResponseTokens }`, `struct ModelAnswer { text: String; content: GeneratedContent?; transcript: Transcript }`, `func runModel(_: ModelCall, model: any LanguageModel) async throws -> ModelAnswer`.

The fake script (`AFMUX_FAKE`) mirrors afmux's `tests/fakefm/fm`:

```json
{
  "log": "/tmp/x/log.jsonl",
  "availability": "available | unavailable",
  "contextSize": 8192,
  "count":   {"fixed": 10, "extraIfContains": "B:20", "delay": 5, "error": "sandbox | other:<message>", "schemaTokens": 38},
  "respond": {"text": "OK", "texts": ["first call", "second call"], "mode": "first-line | echo",
              "delay": 5, "error": "guardrail | refusal | timeout | context | rateLimited | assets | guide | sandbox | other:<message>",
              "failOnCall": 2, "toolCalls": [{"name": "read_file", "arguments": "{\"path\":\"a.txt\"}"}]}
}
```

Log records (one JSON object per line): `{"kind":"count","what":"prompt|schema|entries",...}`, `{"kind":"respond","call":N,"instructions":...,"prompt":...,"schema":...,"tools":[...],"sampling":"greedy","maxTokens":N,"guardrails":...,"useCase":...,"history":N}`, `{"kind":"toolOutputs","outputs":[...]}`.

- [ ] **Step 1: Write the failing tests**

`Tests/AFMuxCoreTests/RunnerTests.swift`:

```swift
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
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --filter RunnerTests`
Expected: compile failure, `cannot find 'FakeBackend' in scope`.

- [ ] **Step 3: Implement**

`Sources/AFMuxCore/Transcripts.swift`:

```swift
import Foundation
import FoundationModels

/// The instructions entry for a call; tools are carried as its tool definitions.
public func instructionsEntry(_ text: String, tools: [any Tool]) -> Transcript.Instructions {
    Transcript.Instructions(segments: [.text(.init(content: text))], toolDefinitions: tools.map { definition(of: $0) })
}

private func definition(of tool: some Tool) -> Transcript.ToolDefinition {
    Transcript.ToolDefinition(tool: tool)
}

/// Plain text of transcript segments; structured segments as compact JSON.
public func text(of segments: [Transcript.Segment]) -> String {
    segments.compactMap { segment -> String? in
        switch segment {
        case .text(let t): return t.content
        case .structure(let s): return compactJSON(s.content)
        default: return nil
        }
    }.joined(separator: "\n")
}

public func entryText(_ entry: Transcript.Entry) -> String {
    switch entry {
    case .instructions(let i):
        return text(of: i.segments) + i.toolDefinitions.map { " " + $0.name + " " + $0.description }.joined()
    case .prompt(let p):
        return text(of: p.segments)
    case .response(let r):
        return text(of: r.segments)
    case .toolCalls(let calls):
        return calls.map { $0.toolName + compactJSON($0.arguments) }.joined(separator: "\n")
    case .toolOutput(let o):
        return text(of: o.segments)
    default:
        return ""
    }
}
```

`Sources/AFMuxCore/Timeout.swift`:

```swift
import Foundation

/// Run body, failing with afmux's "timed out after N s" if it takes longer than seconds.
public func withTimeout<T: Sendable>(_ seconds: Double, _ body: @escaping @Sendable () async throws -> T) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await body() }
        group.addTask {
            try await Task.sleep(nanoseconds: UInt64(min(seconds, 1e9) * 1_000_000_000))
            throw AfmError(.model, "timed out after \(pyG(seconds)) s")
        }
        defer { group.cancelAll() }
        return try await group.next()!
    }
}
```

`Sources/AFMuxCore/TokenCounter.swift`:

```swift
import Foundation
import FoundationModels

public protocol TokenCounter: Sendable {
    var contextSize: Int { get }
    /// An instructions entry (text and tool definitions) plus a prompt; either may be empty.
    func count(prompt: String, instructions: Transcript.Instructions?) async throws -> Int
    func count(schema: GenerationSchema) async throws -> Int
    func count(entries: [Transcript.Entry]) async throws -> Int
}

public struct SystemTokenCounter: TokenCounter {
    public init() {}

    public var contextSize: Int { SystemLanguageModel.default.contextSize }

    public func count(prompt: String, instructions: Transcript.Instructions?) async throws -> Int {
        let model = SystemLanguageModel.default
        var n = 0
        if let instructions { n += try await model.tokenCount(for: [Transcript.Entry.instructions(instructions)]) }
        if !prompt.isEmpty { n += try await model.tokenCount(for: prompt) }
        return n
    }

    public func count(schema: GenerationSchema) async throws -> Int {
        try await SystemLanguageModel.default.tokenCount(for: schema)
    }

    public func count(entries: [Transcript.Entry]) async throws -> Int {
        entries.isEmpty ? 0 : try await SystemLanguageModel.default.tokenCount(for: entries)
    }
}

/// Applies --timeout to every count, as afmux's run_fm does for count-tokens.
public struct TimedCounter: TokenCounter {
    public let base: any TokenCounter
    public let timeout: Double

    public init(base: any TokenCounter, timeout: Double) {
        self.base = base
        self.timeout = timeout
    }

    public var contextSize: Int { base.contextSize }

    public func count(prompt: String, instructions: Transcript.Instructions?) async throws -> Int {
        let base = self.base
        return try await withTimeout(timeout) { try await base.count(prompt: prompt, instructions: instructions) }
    }

    public func count(schema: GenerationSchema) async throws -> Int {
        let base = self.base
        return try await withTimeout(timeout) { try await base.count(schema: schema) }
    }

    public func count(entries: [Transcript.Entry]) async throws -> Int {
        let base = self.base
        return try await withTimeout(timeout) { try await base.count(entries: entries) }
    }
}
```

`Sources/AFMuxCore/Backend.swift`:

```swift
import Foundation
import FoundationModels

public protocol Backend: Sendable {
    var counter: any TokenCounter { get }
    func model(guardrails: String, useCase: String) -> any LanguageModel
    func isAvailable() -> Bool
}

public struct SystemBackend: Backend {
    public init() {}

    public var counter: any TokenCounter { SystemTokenCounter() }

    public func model(guardrails: String, useCase: String) -> any LanguageModel {
        SystemLanguageModel(
            useCase: useCase == "content-tagging" ? .contentTagging : .general,
            guardrails: guardrails == "default" ? .default : .permissiveContentTransformations)
    }

    public func isAvailable() -> Bool {
        SystemLanguageModel.default.availability == .available
    }
}
```

`Sources/AFMuxCore/Fake.swift`:

```swift
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
```

Note: `FakeState.init` takes a fresh `id` under the registry lock, then registers `self` once every stored property is set.

`Sources/AFMuxCore/Runner.swift`:

```swift
import Foundation
import FoundationModels

public struct ModelCall: Sendable {
    public var instructions: Transcript.Instructions
    public var history: [Transcript.Entry]
    public var prompt: String
    public var schema: GenerationSchema?
    public var tools: [any Tool]
    public var maxResponseTokens: Int?

    public init(instructions: Transcript.Instructions, history: [Transcript.Entry] = [], prompt: String,
                schema: GenerationSchema? = nil, tools: [any Tool] = [], maxResponseTokens: Int? = nil) {
        self.instructions = instructions
        self.history = history
        self.prompt = prompt
        self.schema = schema
        self.tools = tools
        self.maxResponseTokens = maxResponseTokens
    }
}

public struct ModelAnswer: Sendable {
    public var text: String
    public var content: GeneratedContent?
    public var transcript: Transcript
}

/// One greedy model call on a fresh session built from instructions + history.
public func runModel(_ call: ModelCall, model: any LanguageModel) async throws -> ModelAnswer {
    let transcript = Transcript(entries: [.instructions(call.instructions)] + call.history)
    let session = makeSession(model, tools: call.tools, transcript: transcript)
    let options = GenerationOptions(samplingMode: .greedy, maximumResponseTokens: call.maxResponseTokens)
    if let schema = call.schema {
        let r = try await session.respond(to: call.prompt, schema: schema, options: options)
        return ModelAnswer(text: compactJSON(r.content, topOrder: SchemaLoader.order(schema)), content: r.content, transcript: session.transcript)
    }
    let r = try await session.respond(to: call.prompt, options: options)
    return ModelAnswer(text: r.content, content: nil, transcript: session.transcript)
}

private func makeSession(_ model: some LanguageModel, tools: [any Tool], transcript: Transcript) -> LanguageModelSession {
    LanguageModelSession(model: model, tools: tools, transcript: transcript)
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `swift test --filter RunnerTests`
Expected: all pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/AFMuxCore Tests/AFMuxCoreTests/RunnerTests.swift
git commit -m "Add token counting, backends, fake model and model runner"
```

---

### Task 6: Error mapping

**Files:**
- Create: `Sources/AFMuxCore/Errors.swift`
- Test: `Tests/AFMuxCoreTests/ErrorTests.swift`

**Interfaces:**
- Consumes: `Backend`, `fakeError`, `AfmError`.
- Produces: `struct ToolCapExceeded: Error { max: Int }`, `func isSandboxError(_: Error) -> Bool`, `func mapError(_: Error, backend: any Backend, duringTools: Bool = false) -> AfmError`.

- [ ] **Step 1: Write the failing tests**

`Tests/AFMuxCoreTests/ErrorTests.swift`:

```swift
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
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --filter ErrorTests`
Expected: compile failure, `cannot find 'mapError' in scope`.

- [ ] **Step 3: Implement**

`Sources/AFMuxCore/Errors.swift`:

```swift
import Foundation
import FoundationModels

public struct ToolCapExceeded: Error, Equatable {
    public var max: Int
}

/// ModelManager error 1008 (the agent's sandbox), by domain and code, or by its text.
public func isSandboxError(_ error: Error) -> Bool {
    var current: NSError? = error as NSError
    var depth = 0
    while let ns = current, depth < 8 {
        if ns.domain.contains("ModelManager") && ns.code == 1008 { return true }
        current = ns.userInfo[NSUnderlyingErrorKey] as? NSError
        depth += 1
    }
    let text = String(describing: error) + " " + error.localizedDescription
    return text.contains("ModelManager") && text.contains("1008")
}

func describe(_ error: Error) -> String {
    (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
}

/// One place that turns any failure into an exit code and message (spec: Error handling).
public func mapError(_ error: Error, backend: any Backend, duringTools: Bool = false) -> AfmError {
    if let e = error as? AfmError { return e }
    if let e = error as? LanguageModelSession.ToolCallError {
        return mapError(e.underlyingError, backend: backend, duringTools: duringTools)
    }
    if let e = error as? ToolCapExceeded { return AfmError(.model, "more than \(e.max) tool calls") }
    if isSandboxError(error) { return AfmError(.sandbox, "fm is blocked by a sandbox; run afm outside it") }
    if let e = error as? GeneratedContent.ParsingError {
        return AfmError(.json, "model output is not valid JSON:\n" + e.rawContent.rstripped())
    }
    if !backend.isAvailable() { return AfmError(.unavailable, "model not available") }
    if error is CancellationError { return AfmError(.model, "cancelled") }
    if let e = error as? GenerationSchema.SchemaError { return AfmError(.usage, describe(e)) }
    if let e = error as? LanguageModelError {
        switch e {
        case .unsupportedGenerationGuide: return AfmError(.usage, describe(e))
        case .contextSizeExceeded where duringTools: return AfmError(.model, "context exceeded during tool calls")
        default: return AfmError(.model, describe(e))
        }
    }
    if let e = error as? LanguageModelSession.GenerationError {
        switch e {
        case .unsupportedGuide: return AfmError(.usage, describe(e))
        case .assetsUnavailable: return AfmError(.unavailable, describe(e))
        case .exceededContextWindowSize where duringTools: return AfmError(.model, "context exceeded during tool calls")
        default: return AfmError(.model, describe(e))
        }
    }
    if let e = error as? SystemLanguageModel.Error, case .assetsUnavailable = e {
        return AfmError(.unavailable, describe(e))
    }
    return AfmError(.model, describe(error))
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `swift test --filter ErrorTests`
Expected: all pass. If the guardrail message differs, use the framework's actual `errorDescription` in the expectation (it was `The model's safety guardrails were triggered.` in Step 0).

- [ ] **Step 5: Commit**

```bash
git add Sources/AFMuxCore/Errors.swift Tests/AFMuxCoreTests/ErrorTests.swift
git commit -m "Add error mapping"
```

---

### Task 7: Chunking

**Files:**
- Create: `Sources/AFMuxCore/Chunker.swift`
- Test: `Tests/AFMuxCoreTests/ChunkerTests.swift`

**Interfaces:**
- Consumes: `TokenCounter`, `AfmError`, `FakeBackend`, `instructionsEntry`.
- Produces: `struct Unit { text: String; sep: String; line: Int }`, `func splitUnits(_ text: String) -> [Unit]`, `func planChunks(text: String, instructions: Transcript.Instructions, schemaTokens: Int, budget: Int, maxChunks: Int, totalTokens: Int, counter: any TokenCounter) async throws -> [String]`.

- [ ] **Step 1: Write the failing tests**

`Tests/AFMuxCoreTests/ChunkerTests.swift`:

```swift
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
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --filter ChunkerTests`
Expected: compile failure, `cannot find 'planChunks' in scope`.

- [ ] **Step 3: Implement** (a line-for-line port of afmux `split_units`, `_add_unit`, `_explode_lines`, `_join`, `plan_chunks`)

`Sources/AFMuxCore/Chunker.swift`:

```swift
import Foundation
import FoundationModels

public struct Unit: Equatable, Sendable {
    public var text: String
    public var sep: String
    public var line: Int
}

private let blankLines = try! NSRegularExpression(pattern: "\n[ \t]*\n+")

/// Non-blank paragraphs separated by blank lines, each with its first line number.
public func splitUnits(_ text: String) -> [Unit] {
    var units: [Unit] = []
    let ns = text as NSString
    var line = 1
    var pos = 0
    for m in blankLines.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
        addUnit(&units, ns.substring(with: NSRange(location: pos, length: m.range.location - pos)), line)
        line += ns.substring(with: NSRange(location: pos, length: NSMaxRange(m.range) - pos)).filter { $0 == "\n" }.count
        pos = NSMaxRange(m.range)
    }
    addUnit(&units, ns.substring(from: pos), line)
    return units
}

private func addUnit(_ units: inout [Unit], _ chunk: String, _ line: Int) {
    if chunk.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return }
    let stripped = chunk.drop { $0 == "\n" }
    let leading = chunk.count - stripped.count
    var body = String(stripped)
    while body.hasSuffix("\n") { body.removeLast() }
    units.append(Unit(text: body, sep: units.isEmpty ? "" : "\n\n", line: line + leading))
}

private func explodeLines(_ unit: Unit) -> [Unit] {
    var out: [Unit] = []
    for (i, ln) in unit.text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
        if ln.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { continue }
        out.append(Unit(text: String(ln), sep: out.isEmpty ? unit.sep : "\n", line: unit.line + i))
    }
    return out
}

private func join(_ units: [Unit]) -> String {
    units.enumerated().map { ($0.offset > 0 ? $0.element.sep : "") + $0.element.text }.joined()
}

/// Pack units greedily by a byte ratio, confirming each piece with the counter (afmux plan_chunks).
public func planChunks(text: String, instructions: Transcript.Instructions, schemaTokens: Int, budget: Int,
                       maxChunks: Int, totalTokens: Int, counter: any TokenCounter) async throws -> [String] {
    let instrTokens = try await counter.count(prompt: "", instructions: instructions)
    let fixed = schemaTokens + instrTokens
    let ratio = Double(max(1, totalTokens - instrTokens)) / Double(max(1, text.utf8.count))
    var units = splitUnits(text)
    var pieces: [String] = []
    var i = 0
    while i < units.count {
        var piece: [Unit] = []
        var nbytes = 0
        while i < units.count {
            let b = units[i].text.utf8.count + units[i].sep.utf8.count
            if !piece.isEmpty && Double(nbytes + b) * ratio + Double(fixed) > Double(budget) { break }
            piece.append(units[i])
            nbytes += b
            i += 1
        }
        var candidate = ""
        while true {
            candidate = join(piece)
            if try await counter.count(prompt: candidate, instructions: instructions) + schemaTokens <= budget { break }
            if piece.count > 1 {
                piece.removeLast()
                i -= 1
                continue
            }
            let u = piece[0]
            if u.text.contains("\n") {
                units.replaceSubrange((i - 1)..<i, with: explodeLines(u))
                i -= 1
                piece = []
                break
            }
            let n = try await counter.count(prompt: u.text, instructions: nil)
            throw AfmError(.budget, "line \(u.line) is \(n) tokens plus \(fixed) for instructions and schema, budget is \(budget)")
        }
        if piece.isEmpty { continue }
        pieces.append(candidate)
        if pieces.count > maxChunks {
            throw AfmError(.budget, "input needs more than \(maxChunks) chunks, max is \(maxChunks)")
        }
    }
    return pieces
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `swift test --filter ChunkerTests`
Expected: all pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/AFMuxCore/Chunker.swift Tests/AFMuxCoreTests/ChunkerTests.swift
git commit -m "Port afmux chunk planning"
```

---

### Task 8: The afm command, CLI harness and the ported afmux suite

**Files:**
- Create: `Sources/AFMuxCore/App.swift`, `Tests/CLITests/Harness.swift`, `Tests/CLITests/AfmuxPortTests.swift`
- Modify: `Sources/afm/main.swift` (replace), `Package.swift` (add CLITests target)

**Interfaces:**
- Consumes: everything above.
- Produces: `struct IO { input: any InputSource; out: @Sendable (String) -> Void; err: @Sendable (String) -> Void; env: [String: String]; static func standard() -> IO }`; `func runAfm(_ argv: [String], io: IO, backend: any Backend) async -> Int32`; `func answer(_: ModelCall, job: Job, model: any LanguageModel, timeout: Double) async throws -> String`; `func checkedAnswer(_: ModelAnswer, job: Job) throws -> String`; `func jobSchema(_: Job) throws -> GenerationSchema?`; `func checkBudget(total: Int, budget: Int, chunk: Bool, job: Job) throws`. In this task `runOnce` uses no tools; Task 10 adds `Toolset`.

- [ ] **Step 1: Add the CLITests target**

In `Package.swift` add to `targets`:

```swift
        .testTarget(name: "CLITests", dependencies: ["afm"], swiftSettings: v5),
```

- [ ] **Step 2: Write the harness and the failing ported tests**

`Tests/CLITests/Harness.swift`:

```swift
import Foundation
import Testing

let packageRoot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
let afmPath = packageRoot.appendingPathComponent(".build/debug/afm").path

struct Run {
    var code: Int32
    var out: String
    var err: String
    var tmp: URL

    var log: [[String: Any]] {
        guard let text = try? String(contentsOf: tmp.appendingPathComponent("log.jsonl"), encoding: .utf8) else { return [] }
        return text.split(separator: "\n").compactMap {
            try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any]
        }
    }

    func records(_ kind: String) -> [[String: Any]] { log.filter { $0["kind"] as? String == kind } }
    var kinds: [String] { log.compactMap { $0["kind"] as? String } }
}

func makeTmp() -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("afm-test-" + UUID().uuidString)
    try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

/// Run the built afm in fake mode. fake is the AFMUX_FAKE script; "log" is filled in.
@discardableResult
func afm(_ args: [String], stdin: String = "", stdinData: Data? = nil, tty: Bool = false,
         fake: [String: Any] = [:], env: [String: String] = [:], tmp: URL? = nil) throws -> Run {
    precondition(FileManager.default.isExecutableFile(atPath: afmPath), "run swift build first")
    let dir = tmp ?? makeTmp()
    var script = fake
    script["log"] = dir.appendingPathComponent("log.jsonl").path
    let scriptURL = dir.appendingPathComponent("fake.json")
    try JSONSerialization.data(withJSONObject: script).write(to: scriptURL)
    let p = Process()
    p.executableURL = URL(fileURLWithPath: afmPath)
    p.arguments = args
    var e = ProcessInfo.processInfo.environment
    e["AFMUX_FAKE"] = scriptURL.path
    e["AFMUX_SESSIONS_DIR"] = dir.appendingPathComponent("sessions").path
    e.merge(env) { $1 }
    p.environment = e
    p.currentDirectoryURL = dir
    let outPipe = Pipe(), errPipe = Pipe(), inPipe = Pipe()
    p.standardOutput = outPipe
    p.standardError = errPipe
    var master: Int32 = -1, slave: Int32 = -1
    if tty {
        openpty(&master, &slave, nil, nil, nil)
        p.standardInput = FileHandle(fileDescriptor: slave, closeOnDealloc: false)
    } else {
        p.standardInput = inPipe
    }
    try p.run()
    if tty {
        close(slave)
    } else {
        inPipe.fileHandleForWriting.write(stdinData ?? Data(stdin.utf8))
        try inPipe.fileHandleForWriting.close()
    }
    let out = outPipe.fileHandleForReading.readDataToEndOfFile()
    let err = errPipe.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    if tty { close(master) }
    return Run(code: p.terminationStatus, out: String(decoding: out, as: UTF8.self),
               err: String(decoding: err, as: UTF8.self), tmp: dir)
}

func goodSchema(_ dir: URL, name: String = "s.json") throws -> String {
    let path = dir.appendingPathComponent(name).path
    let obj: [String: Any] = ["title": "T", "type": "object", "properties": ["a": ["type": "integer"]],
                              "required": ["a"], "x-order": ["a"], "additionalProperties": false]
    try JSONSerialization.data(withJSONObject: obj).write(to: URL(fileURLWithPath: path))
    return path
}

let p100 = String(repeating: "P", count: 100)
```

`Tests/CLITests/AfmuxPortTests.swift` (afmux `tests/test_afm.py` at `e814b9e`, one Swift test per Python test, same names in camelCase):

```swift
import Foundation
import Testing

@Suite struct ListTests {
    @Test func listPrintsPresetsAndFirstLines() throws {
        let r = try afm(["--list"])
        #expect(r.code == 0, "\(r.err)")
        #expect(r.out.split(separator: "\n").map { String($0.split(separator: " ")[0]) } == ["classify", "commit-msg", "extract", "summarise"])
        #expect(r.out.contains("Summarise the input"))
    }

    @Test func listMakesNoModelCalls() throws {
        #expect(try afm(["--list"]).log.isEmpty)
    }
}

@Suite struct UsageTests {
    func usage(_ args: [String], stdin: String = "hello", tty: Bool = false, needle: String) throws {
        let r = try afm(args, stdin: stdin, tty: tty)
        #expect(r.code == 2, "\(r.err)")
        #expect(r.out == "")
        #expect(r.err.contains(needle), "\(r.err)")
    }

    @Test func unknownPreset() throws { try usage(["nosuch"], needle: "unknown preset") }
    @Test func noJob() throws { try usage([], needle: "usage") }
    @Test func askNeedsInstructions() throws { try usage(["ask"], needle: "instructions") }
    @Test func ttyStdin() throws { try usage(["summarise"], tty: true, needle: "reads its input from stdin") }
    @Test func emptyStdin() throws { try usage(["summarise"], stdin: "", needle: "empty") }
    @Test func whitespaceOnlyStdin() throws { try usage(["summarise"], stdin: "  \n\n", needle: "empty") }
    @Test func classifyNeedsLabels() throws { try usage(["classify"], needle: "--labels") }
    @Test func labelsEmptyItem() throws { try usage(["classify", "--labels", "a,,b"], needle: "empty label") }
    @Test func labelsDuplicate() throws { try usage(["classify", "--labels", "a,b,a"], needle: "duplicate") }
    @Test func labelsOnOtherPreset() throws { try usage(["summarise", "--labels", "a,b"], needle: "--labels") }
    @Test func classifyRejectsSchema() throws { try usage(["classify", "--labels", "a,b", "--schema", "x.json"], needle: "--schema") }
    @Test func extractNeedsSchema() throws { try usage(["extract"], needle: "--schema") }
    @Test func schemaFileMissing() throws { try usage(["extract", "--schema", "/nonexistent.json"], needle: "schema") }
    @Test func chunkWithCommitMsg() throws { try usage(["commit-msg", "--chunk"], needle: "--chunk") }
    @Test func usageErrorsMakeNoModelCalls() throws { #expect(try afm(["classify"], stdin: "x").log.isEmpty) }
}

@Suite struct BackendTests {
    @Test func unavailableAfterCountFailureIsExit4() throws {
        let r = try afm(["summarise"], stdin: "hello", fake: ["count": ["error": "other:x"], "availability": "unavailable"])
        #expect(r.code == 4, "\(r.err)")
        #expect(r.out == "")
        #expect(r.err.contains("model not available"))
    }

    @Test func sandboxOnCountIsExit5BeforeRespond() throws {
        let r = try afm(["summarise"], stdin: "hello", fake: ["count": ["error": "sandbox"]])
        #expect(r.code == 5, "\(r.err)")
        #expect(r.err.contains("blocked by a sandbox"))
        #expect(r.kinds == ["count"])
    }

    @Test func otherCountFailureIsExit1WithStderr() throws {
        let r = try afm(["summarise"], stdin: "hello", fake: ["count": ["error": "other:Error: something else"]])
        #expect(r.code == 1, "\(r.err)")
        #expect(r.err.contains("something else"))
    }

    @Test func countIncludesInstructions() throws {
        let r = try afm(["summarise"], stdin: "hello")
        let count = r.records("count")[0]
        #expect((count["instructions"] as? String)?.contains("Summarise the input") == true)
        #expect(count["prompt"] as? String == "hello")
    }
}

@Suite struct BudgetTests {
    @Test func overBudgetIsExit6WithNumbers() throws {
        let r = try afm(["summarise", "--budget", "100"], stdin: String(repeating: "x", count: 1000))
        #expect(r.code == 6, "\(r.err)")
        #expect(r.out == "")
        #expect(r.err.contains("budget is 100") && r.err.contains("rerun with --chunk"))
        #expect(r.kinds == ["count"])
    }

    @Test func schemaCountsTowardBudget() throws {
        let dir = makeTmp()
        let schema = try goodSchema(dir)
        let r = try afm(["extract", "--schema", schema, "--budget", "120"], stdin: String(repeating: "x", count: 100),
                        fake: ["count": ["schemaTokens": 110]], tmp: dir)
        #expect(r.code == 6, "\(r.err)")
        #expect(r.records("count").count == 2)
    }
}

@Suite struct RespondTests {
    @Test func successPrintsAnswerOnly() throws {
        let r = try afm(["summarise"], stdin: "hello world", fake: ["respond": ["text": "A summary.  \n\n"]])
        #expect(r.code == 0, "\(r.err)")
        #expect(r.out == "A summary.\n")
        #expect(r.err == "")
    }

    @Test func respondArguments() throws {
        let r = try afm(["summarise", "--guardrails", "default", "--use-case", "content-tagging"], stdin: "hello")
        let rec = r.records("respond")[0]
        #expect(rec["sampling"] as? String == "greedy")
        #expect(rec["guardrails"] as? String == "default")
        #expect(rec["useCase"] as? String == "content-tagging")
        #expect((rec["instructions"] as? String)?.contains("Summarise the input") == true)
        #expect(rec["schema"] is NSNull)
        #expect(rec["prompt"] as? String == "hello")
    }

    @Test func defaultGuardrailsPermissive() throws {
        let rec = try afm(["summarise"], stdin: "hello").records("respond")[0]
        #expect(rec["guardrails"] as? String == "permissive-content-transformations")
        #expect(rec["useCase"] as? String == "general")
    }

    @Test func refusalIsExit1WithStderr() throws {
        let r = try afm(["summarise"], stdin: "hello", fake: ["respond": ["error": "guardrail"]])
        #expect(r.code == 1)
        #expect(r.out == "")
        #expect(r.err.contains("safety guardrails"))
        #expect(r.kinds == ["count", "respond"])
    }

    @Test func respondFailureWithModelUnavailableIsExit4() throws {
        let r = try afm(["summarise"], stdin: "hello", fake: ["respond": ["error": "other:x"], "availability": "unavailable"])
        #expect(r.code == 4, "\(r.err)")
        #expect(r.err.contains("not available"))
    }

    @Test func sandboxOnRespondIsExit5() throws {
        let r = try afm(["summarise"], stdin: "hello", fake: ["count": ["fixed": 10], "respond": ["error": "sandbox"]])
        #expect(r.code == 5, "\(r.err)")
    }

    @Test func timeoutIsExit1() throws {
        let r = try afm(["summarise", "--timeout", "0.5"], stdin: "hello", fake: ["respond": ["delay": 5]])
        #expect(r.code == 1, "\(r.err)")
        #expect(r.err.contains("timed out after 0.5 s"))
    }
}

@Suite struct SchemaTests {
    @Test func classifySchemaFields() throws {
        let r = try afm(["classify", "--labels", "bug, feature ,question"], stdin: "x", fake: ["respond": ["text": #"{"label": "bug"}"#]])
        let schema = r.records("respond")[0]["schema"] as! String
        let obj = try JSONSerialization.jsonObject(with: Data(schema.utf8)) as! [String: Any]
        let label = (obj["properties"] as! [String: Any])["label"] as! [String: Any]
        #expect(label["enum"] as? [String] == ["bug", "feature", "question"])
        #expect(obj["required"] as? [String] == ["label"])
    }

    @Test func classifyInstructionsHaveLabels() throws {
        let r = try afm(["classify", "--labels", "bug,feature"], stdin: "x", fake: ["respond": ["text": #"{"label": "bug"}"#]])
        #expect((r.records("respond")[0]["instructions"] as? String)?.contains("bug, feature") == true)
    }

    @Test func classifyOutputIsCompactJSON() throws {
        let r = try afm(["classify", "--labels", "bug,feature"], stdin: "x", fake: ["respond": ["text": #"{ "label" : "feature" }"#]])
        #expect(r.code == 0, "\(r.err)")
        #expect(r.out == "{\"label\":\"feature\"}\n")
    }

    @Test func classifyLabelOutsideListIsExit3() throws {
        let r = try afm(["classify", "--labels", "bug,feature"], stdin: "x", fake: ["respond": ["text": #"{"label": "other"}"#]])
        #expect(r.code == 3)
        #expect(r.out == "")
        #expect(r.err.contains("other"))
    }

    @Test func invalidJSONIsExit3WithRawOnStderr() throws {
        let r = try afm(["classify", "--labels", "bug,feature"], stdin: "x", fake: ["respond": ["text": "not json {"]])
        #expect(r.code == 3, "\(r.err)")
        #expect(r.out == "")
        #expect(r.err.contains("not json {"))
    }

    @Test func extractUsesGivenSchemaAndCompacts() throws {
        let dir = makeTmp()
        let schema = try goodSchema(dir)
        let r = try afm(["extract", "--schema", schema], stdin: "x", fake: ["respond": ["text": "{\"a\": 1,\n \"b\": \"two\"}"]], tmp: dir)
        #expect(r.code == 0, "\(r.err)")
        #expect(r.out == "{\"a\":1,\"b\":\"two\"}\n")
        #expect(FileManager.default.fileExists(atPath: schema))
    }

    @Test func askWithSchema() throws {
        let dir = makeTmp()
        let schema = try goodSchema(dir)
        let r = try afm(["ask", "Extract.", "--schema", schema], stdin: "x", fake: ["respond": ["text": #"{"k": true}"#]], tmp: dir)
        #expect(r.out == "{\"k\":true}\n")
    }
}

@Suite struct ChunkTests {
    @Test func fitsInOnePieceStillUsesChunkFormat() throws {
        let r = try afm(["ask", "S.", "--chunk"], stdin: "hello", fake: ["respond": ["text": "ans"]])
        #expect(r.code == 0, "\(r.err)")
        #expect(r.out == "[1/1]\nans\n")
    }

    @Test func splitsAtBlankLinesAndKeepsOrder() throws {
        let a = String(repeating: "A", count: 100), b = String(repeating: "B", count: 100), c = String(repeating: "C", count: 100)
        let r = try afm(["ask", "S.", "--chunk", "--budget", "60"], stdin: [a, b, c].joined(separator: "\n\n"), fake: ["respond": ["mode": "first-line"]])
        #expect(r.code == 0, "\(r.err)")
        #expect(r.out == "[1/2]\n\(a)\n[2/2]\n\(c)\n")
        #expect(r.records("respond").map { $0["prompt"] as! String } == [a + "\n\n" + b, c])
    }

    @Test func longParagraphSplitsAtLines() throws {
        let text = (0..<4).map { "L\($0)" + String(repeating: "x", count: 98) }.joined(separator: "\n")
        let r = try afm(["ask", "S.", "--chunk", "--budget", "60"], stdin: text, fake: ["respond": ["mode": "first-line"]])
        #expect(r.code == 0, "\(r.err)")
        #expect(r.out.hasPrefix("[1/2]\nL0"))
        let prompts = r.records("respond").map { $0["prompt"] as! String }
        #expect(prompts.count == 2)
        #expect(prompts[0].filter { $0 == "\n" }.count == 1)
    }

    @Test func singleLineOverBudgetIsExit6() throws {
        let r = try afm(["ask", "S.", "--chunk", "--budget", "60"], stdin: "short\n\n" + String(repeating: "y", count: 1000))
        #expect(r.code == 6, "\(r.err)")
        #expect(r.out == "")
        #expect(r.err.contains("line 3 is") && r.err.contains("budget is 60"))
        #expect(r.records("respond").isEmpty)
    }

    @Test func tooManyChunksIsExit6BeforeRespond() throws {
        let r = try afm(["ask", "S.", "--chunk", "--budget", "30", "--max-chunks", "3"], stdin: Array(repeating: p100, count: 5).joined(separator: "\n\n"))
        #expect(r.code == 6, "\(r.err)")
        #expect(r.err.contains("input needs more than 3 chunks, max is 3"))
        #expect(r.records("respond").isEmpty)
    }

    @Test func middlePieceFailureStopsWithPrefixAndEmptyStdout() throws {
        let r = try afm(["ask", "S.", "--chunk", "--budget", "30"], stdin: Array(repeating: p100, count: 3).joined(separator: "\n\n"),
                        fake: ["respond": ["error": "guardrail", "failOnCall": 2]])
        #expect(r.code == 1, "\(r.err)")
        #expect(r.out == "")
        #expect(r.err.contains("chunk 2/3: ") && r.err.contains("guardrails"))
        #expect(r.records("respond").count == 2)
    }

    @Test func schemaChunksAreJSONLines() throws {
        let r = try afm(["classify", "--labels", "a,b", "--chunk", "--budget", "115"], stdin: [p100, p100].joined(separator: "\n\n"),
                        fake: ["respond": ["text": #"{"label": "a"}"#], "count": ["schemaTokens": 38]])
        #expect(r.code == 0, "\(r.err)")
        #expect(r.out == "{\"label\":\"a\"}\n{\"label\":\"a\"}\n")
    }

    @Test func overBudgetWithoutChunkStillExit6() throws {
        #expect(try afm(["ask", "S.", "--budget", "10"], stdin: String(repeating: "z", count: 100)).code == 6)
    }
}

@Suite struct ReviewFixTests {
    @Test func leadingBlankLinesDoNotMakeAnEmptyChunk() throws {
        let a = String(repeating: "A", count: 100), b = String(repeating: "B", count: 100)
        let r = try afm(["ask", "S.", "--chunk", "--budget", "60"], stdin: "\n\n\(a)\n\n\(b)\n", fake: ["respond": ["mode": "first-line"]])
        #expect(r.code == 0, "\(r.err)")
        #expect(r.records("respond").map { $0["prompt"] as! String } == [a + "\n\n" + b])
        #expect(r.out == "[1/1]\n\(a)\n")
    }

    @Test func whitespaceOnlyParagraphIsDropped() throws {
        let a = String(repeating: "A", count: 100), b = String(repeating: "B", count: 100)
        let r = try afm(["ask", "S.", "--chunk", "--budget", "60"], stdin: a + "\n\n \n\n" + b, fake: ["respond": ["mode": "first-line"]])
        #expect(r.records("respond").map { $0["prompt"] as! String } == [a + "\n\n" + b])
    }

    @Test func trailingNewlineInLongParagraphDoesNotMakeAnEmptyChunk() throws {
        let text = (0..<4).map { "L\($0)" + String(repeating: "x", count: 98) }.joined(separator: "\n") + "\n"
        let r = try afm(["ask", "S.", "--chunk", "--budget", "60"], stdin: text, fake: ["respond": ["mode": "first-line"]])
        #expect(r.code == 0, "\(r.err)")
        #expect(r.records("respond").allSatisfy { !($0["prompt"] as! String).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })
    }

    @Test func crlfInputSplitsAtParagraphs() throws {
        let a = String(repeating: "A", count: 100), b = String(repeating: "B", count: 100), c = String(repeating: "C", count: 100)
        let r = try afm(["ask", "S.", "--chunk", "--budget", "60"], stdin: a + "\r\n\r\n" + b + "\r\n\r\n" + c + "\r\n", fake: ["respond": ["mode": "first-line"]])
        #expect(r.records("respond").map { $0["prompt"] as! String } == [a + "\n\n" + b, c])
    }

    @Test func nonUTF8StdinIsAccepted() throws {
        #expect(try afm(["summarise"], stdinData: Data([0x63, 0x61, 0x66, 0xe9, 0x20, 0x6f, 0x6b])).code == 0)
    }

    @Test func instructionsStartingWithDash() throws {
        let r = try afm(["ask", "-v: reply ok"], stdin: "hello")
        #expect(r.code == 0, "\(r.err)")
        #expect(r.records("respond")[0]["instructions"] as? String == "-v: reply ok")
    }

    @Test func schemaNotJSONIsUsageError() throws {
        let dir = makeTmp()
        let path = dir.appendingPathComponent("bad.json")
        try "{not json".write(to: path, atomically: true, encoding: .utf8)
        let r = try afm(["extract", "--schema", path.path], stdin: "x", tmp: dir)
        #expect(r.code == 2, "\(r.err)")
        #expect(r.err.contains("not valid JSON"))
        #expect(r.log.isEmpty)
    }

    @Test func schemaWithoutXOrderIsAccepted() throws {
        let dir = makeTmp()
        let path = dir.appendingPathComponent("no-order.json")
        try #"{"type":"object","properties":{"a":{"type":"integer"}}}"#.write(to: path, atomically: true, encoding: .utf8)
        let r = try afm(["extract", "--schema", path.path], stdin: "x", fake: ["respond": ["text": #"{"a": 3}"#]], tmp: dir)
        #expect(r.code == 0, "\(r.err)")
        #expect(r.out == "{\"a\":3}\n")
    }

    @Test func commitMsgOverBudgetAdviceIsNotChunk() throws {
        let r = try afm(["commit-msg", "--budget", "50"], stdin: String(repeating: "x", count: 1000))
        #expect(r.code == 6, "\(r.err)")
        #expect(!r.err.contains("--chunk") && r.err.contains("smaller diff"))
    }

    @Test func singleLineOverBudgetMessageIncludesOverhead() throws {
        let r = try afm(["ask", "S.", "--chunk", "--budget", "20"], stdin: String(repeating: "y", count: 400))
        #expect(r.code == 6, "\(r.err)")
        #expect(r.err.contains("line 1 is 100 tokens plus 1 for instructions and schema, budget is 20"))
    }

    @Test func maxChunksExactlyNIsFine() throws {
        let r = try afm(["ask", "S.", "--chunk", "--budget", "30", "--max-chunks", "3"], stdin: Array(repeating: p100, count: 3).joined(separator: "\n\n"))
        #expect(r.code == 0, "\(r.err)")
        #expect(r.out.filter { $0 == "[" }.count == 3)
    }

    @Test func planningStopsAtMaxChunksPlusOne() throws {
        let r = try afm(["ask", "S.", "--chunk", "--budget", "30", "--max-chunks", "2"], stdin: Array(repeating: p100, count: 50).joined(separator: "\n\n"))
        #expect(r.code == 6, "\(r.err)")
        #expect(r.records("count").count < 10)
    }

    @Test func popBranchWhenEstimateUnderpredicts() throws {
        let a = String(repeating: "A", count: 100), b = String(repeating: "B", count: 100), c = String(repeating: "C", count: 100)
        let r = try afm(["ask", "S.", "--chunk", "--budget", "70"], stdin: [a, b, c].joined(separator: "\n\n"),
                        fake: ["respond": ["mode": "first-line"], "count": ["extraIfContains": "B:20"]])
        #expect(r.code == 0, "\(r.err)")
        #expect(r.records("respond").map { $0["prompt"] as! String } == [a, b, c])
    }

    @Test func timeoutInsideChunk() throws {
        let r = try afm(["ask", "S.", "--chunk", "--budget", "30", "--timeout", "0.5"], stdin: [p100, p100].joined(separator: "\n\n"), fake: ["respond": ["delay": 5]])
        #expect(r.code == 1, "\(r.err)")
        #expect(r.err.contains("chunk 1/2: timed out after 0.5 s"))
        #expect(r.out == "")
    }

    @Test func exit3InsideChunk() throws {
        let r = try afm(["classify", "--labels", "a,b", "--chunk", "--budget", "115"], stdin: [p100, p100].joined(separator: "\n\n"),
                        fake: ["respond": ["text": #"{"label": "zzz"}"#], "count": ["schemaTokens": 38]])
        #expect(r.code == 3, "\(r.err)")
        #expect(r.err.contains("chunk 1/2: label 'zzz'"))
        #expect(r.out == "")
    }

    @Test func sandboxBeatsUnavailable() throws {
        let r = try afm(["summarise"], stdin: "hello", fake: ["respond": ["error": "sandbox"], "availability": "unavailable"])
        #expect(r.code == 5, "\(r.err)")
    }

    @Test func emptyModelOutputIsExit1() throws {
        let r = try afm(["summarise"], stdin: "hello", fake: ["respond": ["text": "   "]])
        #expect(r.code == 1, "\(r.err)")
        #expect(r.err.contains("no output"))
        #expect(r.out == "")
    }

    @Test func badTimeoutAndMaxChunksAreUsageErrors() throws {
        for args in [["summarise", "--timeout", "0"], ["summarise", "--timeout", "-1"], ["summarise", "--timeout", "nan"],
                     ["summarise", "--timeout", "inf"], ["summarise", "--chunk", "--max-chunks", "0"], ["summarise", "--budget", "0"]] {
            #expect(try afm(args, stdin: "hello").code == 2, "\(args)")
        }
    }

    @Test func labelsWithQuotesOrBackslashAreUsageErrors() throws {
        for labels in ["a,b\"c", "a,b'c", "a,x\\y"] {
            #expect(try afm(["classify", "--labels", labels], stdin: "hello").code == 2, "\(labels)")
        }
    }

    @Test func countTokensHonoursTimeout() throws {
        let r = try afm(["summarise", "--timeout", "0.5"], stdin: "hello", fake: ["count": ["delay": 5]])
        #expect(r.code == 1, "\(r.err)")
        #expect(r.err.contains("timed out"))
    }
}
```

- [ ] **Step 3: Run the tests to verify they fail**

Run: `swift build && swift test --filter CLITests`
Expected: most tests fail (the placeholder binary prints the usage line and exits 0).

- [ ] **Step 4: Implement**

`Sources/AFMuxCore/App.swift`:

```swift
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
        let o = try parseArgs(argv)
        if o.help {
            io.out(helpText)
            return 0
        }
        if o.list {
            io.out(Presets.listing())
            return 0
        }
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
    let tools: [any Tool] = []
    let input = try readInput(io.input, optional: job.name == "ask" && o.toolsOn)
    let shape = callShape(job: job, input: input)
    let schema = try jobSchema(job)
    let instructions = instructionsEntry(shape.instructions, tools: tools)
    let schemaTokens = try await schema.map { try await counter.count(schema: $0) } ?? 0
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
```

`Sources/afm/main.swift`:

```swift
import AFMuxCore
import Foundation

let environment = ProcessInfo.processInfo.environment
let backend: any Backend
if let path = environment["AFMUX_FAKE"] {
    do {
        backend = try FakeBackend(scriptPath: path)
    } catch {
        FileHandle.standardError.write(Data("afm: cannot load AFMUX_FAKE script: \(error)\n".utf8))
        exit(2)
    }
} else {
    backend = SystemBackend()
}
exit(await runAfm(Array(CommandLine.arguments.dropFirst()), io: .standard(), backend: backend))
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `swift build && swift test`
Expected: all pass. A failing ported test is a compatibility bug: fix the code, not the expectation, unless the spec's "Accepted differences" covers it.

- [ ] **Step 6: Commit**

```bash
git add Package.swift Sources Tests/CLITests
git commit -m "Add the afm command and port afmux's test suite"
```

---

### Task 9: Processes, tool context and built-in tools

**Files:**
- Create: `Sources/AFMuxCore/Proc.swift`, `Sources/AFMuxCore/Tools.swift`, `Sources/AFMuxCore/BuiltinTools.swift`
- Test: `Tests/AFMuxCoreTests/ToolTests.swift`

**Interfaces:**
- Consumes: `TokenCounter`, `compactJSON`, `SchemaLoader.convert`, `ToolCapExceeded`, `pyG`, `FakeBackend`.
- Produces: `struct ProcResult { status: Int32; stdout: String; stderr: String; timedOut: Bool }`, `func runProcess(_ argv: [String], timeout: Double) async -> ProcResult`, `final class ProcessGroups { static let shared; func killAll() }`; `final class ToolContext(counter:maxCalls:outputBudget:toolTimeout:)` with `start(used:)`, `room`; `struct ToolOutput(_ text:, marker:)`; `struct AfmTool: Tool` (`Arguments = GeneratedContent`, `Output = String`); `let nearlyFull: String`; `func builtinTools(context: ToolContext) -> [AfmTool]`.

- [ ] **Step 1: Write the failing tests**

`Tests/AFMuxCoreTests/ToolTests.swift`:

```swift
import Foundation
import FoundationModels
import Testing
@testable import AFMuxCore

private func context(maxCalls: Int = 8, budget: Int = 600, contextSize: Int = 8192) -> ToolContext {
    var script = FakeScript()
    script.contextSize = contextSize
    return ToolContext(counter: FakeBackend(script: script).counter, maxCalls: maxCalls, outputBudget: budget, toolTimeout: 2)
}

private func tool(_ name: String, _ ctx: ToolContext) -> AfmTool {
    builtinTools(context: ctx).first { $0.name == name }!
}

private func fixture() throws -> URL {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("afm-tools-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: dir.appendingPathComponent("sub"), withIntermediateDirectories: true)
    try (1...10).map { "line \($0)" }.joined(separator: "\n").appending("\n").write(to: dir.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
    try "needle here\n".write(to: dir.appendingPathComponent("sub/b.md"), atomically: true, encoding: .utf8)
    return dir
}

@Test func processRunnerBasics() async {
    let ok = await runProcess(["/bin/echo", "hi"], timeout: 5)
    #expect(ok.status == 0 && ok.stdout == "hi\n" && !ok.timedOut)
    let fail = await runProcess(["/bin/sh", "-c", "echo err >&2; exit 3"], timeout: 5)
    #expect(fail.status == 3 && fail.stderr == "err\n")
    let missing = await runProcess(["no-such-command-xyz"], timeout: 5)
    #expect(missing.status == 127)
}

@Test func processTimeoutKillsTheGroup() async throws {
    let r = await runProcess(["/bin/sh", "-c", "sleep 30 & echo $!; wait"], timeout: 0.5)
    #expect(r.timedOut)
    let pid = pid_t(r.stdout.trimmingCharacters(in: .whitespacesAndNewlines))!
    try await Task.sleep(nanoseconds: 300_000_000)
    #expect(kill(pid, 0) != 0)
}

@Test func readFileNumbersAndRanges() async throws {
    let dir = try fixture()
    let ctx = context()
    let read = tool("read_file", ctx)
    let out = try await read.call(arguments: GeneratedContent(json: #"{"path":"\#(dir.path)/a.txt","start_line":2,"end_line":3}"#))
    #expect(out == "2\tline 2\n3\tline 3")
    let missing = try await read.call(arguments: GeneratedContent(json: #"{"path":"/nonexistent"}"#))
    #expect(missing.hasPrefix("error: "))
}

@Test func readFileTruncatesWithMarker() async throws {
    let dir = try fixture()
    let ctx = context(budget: 12)
    let out = try await tool("read_file", ctx).call(arguments: GeneratedContent(json: #"{"path":"\#(dir.path)/a.txt"}"#))
    #expect(out.contains("[truncated: "))
    #expect(out.contains("more lines; call read_file with start_line="))
}

@Test func grepAndListDir() async throws {
    let dir = try fixture()
    let ctx = context()
    let hits = try await tool("grep", ctx).call(arguments: GeneratedContent(json: #"{"pattern":"needle","path":"\#(dir.path)"}"#))
    #expect(hits.contains("sub/b.md:1:needle here"))
    let none = try await tool("grep", ctx).call(arguments: GeneratedContent(json: #"{"pattern":"zzz","path":"\#(dir.path)"}"#))
    #expect(none == "no matches")
    let list = try await tool("list_dir", ctx).call(arguments: GeneratedContent(json: #"{"path":"\#(dir.path)"}"#))
    #expect(list == "a.txt\nsub/")
}

@Test func callCapThrows() async throws {
    let dir = try fixture()
    let ctx = context(maxCalls: 1)
    let list = tool("list_dir", ctx)
    _ = try await list.call(arguments: GeneratedContent(json: #"{"path":"\#(dir.path)"}"#))
    await #expect(throws: ToolCapExceeded(max: 1)) {
        _ = try await list.call(arguments: GeneratedContent(json: #"{"path":"\#(dir.path)"}"#))
    }
}

@Test func nearlyFullContext() async throws {
    let dir = try fixture()
    let ctx = context(contextSize: 1100)
    ctx.start(used: 0)
    let out = try await tool("list_dir", ctx).call(arguments: GeneratedContent(json: #"{"path":"\#(dir.path)"}"#))
    #expect(out == nearlyFull)
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --filter ToolTests`
Expected: compile failure, `cannot find 'runProcess' in scope`.

- [ ] **Step 3: Implement**

`Sources/AFMuxCore/Proc.swift`:

```swift
import Darwin
import Foundation

public struct ProcResult: Sendable {
    public var status: Int32
    public var stdout: String
    public var stderr: String
    public var timedOut: Bool
}

/// Process groups of running tools, so a signal handler can kill them all.
public final class ProcessGroups: @unchecked Sendable {
    public static let shared = ProcessGroups()
    private let lock = NSLock()
    private var groups = Set<pid_t>()

    func add(_ group: pid_t) { lock.withLock { _ = groups.insert(group) } }
    func remove(_ group: pid_t) { lock.withLock { _ = groups.remove(group) } }

    public func killAll() {
        lock.withLock { for g in groups { kill(-g, SIGKILL) } }
    }
}

/// Run argv (PATH lookup) in its own process group, stdin /dev/null; on timeout kill the group.
public func runProcess(_ argv: [String], timeout: Double) async -> ProcResult {
    await withCheckedContinuation { continuation in
        DispatchQueue.global().async {
            continuation.resume(returning: runProcessSync(argv, timeout: timeout))
        }
    }
}

private final class Box<T>: @unchecked Sendable {
    var value: T
    init(_ value: T) { self.value = value }
}

private func readAll(_ fd: Int32) -> Data {
    var data = Data()
    var buffer = [UInt8](repeating: 0, count: 65536)
    while true {
        let n = read(fd, &buffer, buffer.count)
        if n <= 0 { break }
        data.append(buffer, count: n)
    }
    close(fd)
    return data
}

private func runProcessSync(_ argv: [String], timeout: Double) -> ProcResult {
    var outPipe: [Int32] = [0, 0]
    var errPipe: [Int32] = [0, 0]
    pipe(&outPipe)
    pipe(&errPipe)
    var actions: posix_spawn_file_actions_t?
    posix_spawn_file_actions_init(&actions)
    posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
    posix_spawn_file_actions_adddup2(&actions, outPipe[1], 1)
    posix_spawn_file_actions_adddup2(&actions, errPipe[1], 2)
    for fd in outPipe + errPipe { posix_spawn_file_actions_addclose(&actions, fd) }
    var attr: posix_spawnattr_t?
    posix_spawnattr_init(&attr)
    posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETPGROUP))
    posix_spawnattr_setpgroup(&attr, 0)
    var pid: pid_t = 0
    let cargs: [UnsafeMutablePointer<CChar>?] = argv.map { strdup($0) } + [nil]
    let rc = posix_spawnp(&pid, argv[0], &actions, &attr, cargs, environ)
    cargs.forEach { free($0) }
    posix_spawn_file_actions_destroy(&actions)
    posix_spawnattr_destroy(&attr)
    close(outPipe[1])
    close(errPipe[1])
    if rc != 0 {
        close(outPipe[0])
        close(errPipe[0])
        return ProcResult(status: 127, stdout: "", stderr: "cannot run \(argv[0]): \(String(cString: strerror(rc)))\n", timedOut: false)
    }
    ProcessGroups.shared.add(pid)
    let out = Box(Data()), err = Box(Data()), status = Box(Int32(0))
    let readers = DispatchGroup()
    readers.enter()
    DispatchQueue.global().async { out.value = readAll(outPipe[0]); readers.leave() }
    readers.enter()
    DispatchQueue.global().async { err.value = readAll(errPipe[0]); readers.leave() }
    let exited = DispatchSemaphore(value: 0)
    DispatchQueue.global().async {
        var s: Int32 = 0
        waitpid(pid, &s, 0)
        status.value = s
        exited.signal()
    }
    var timedOut = false
    if exited.wait(timeout: .now() + timeout) == .timedOut {
        timedOut = true
        kill(-pid, SIGKILL)
        exited.wait()
    }
    // Leftover members of the group (background children) would hold the pipes open.
    kill(-pid, SIGKILL)
    readers.wait()
    ProcessGroups.shared.remove(pid)
    let s = status.value
    let code = (s & 0x7f) == 0 ? (s >> 8) & 0xff : 128 + (s & 0x7f)
    return ProcResult(status: code, stdout: String(decoding: out.value, as: UTF8.self),
                      stderr: String(decoding: err.value, as: UTF8.self), timedOut: timedOut)
}
```

`Sources/AFMuxCore/Tools.swift`:

```swift
import Foundation
import FoundationModels

public let nearlyFull = "Context nearly full. Answer now with what you have."

/// Shared by the tools of one afm call: the running context count and the call cap.
public final class ToolContext: @unchecked Sendable {
    public let counter: any TokenCounter
    public let maxCalls: Int
    public let outputBudget: Int
    public let toolTimeout: Double
    private let lock = NSLock()
    private var used = 0
    private var calls = 0

    public init(counter: any TokenCounter, maxCalls: Int, outputBudget: Int, toolTimeout: Double) {
        self.counter = counter
        self.maxCalls = maxCalls
        self.outputBudget = outputBudget
        self.toolTimeout = toolTimeout
    }

    /// Reset for a model call whose pre-call total is used.
    public func start(used: Int) {
        lock.withLock {
            self.used = used
            calls = 0
        }
    }

    /// Tokens left before contextSize minus the 1024-token output reserve.
    public var room: Int { lock.withLock { counter.contextSize - 1024 - used } }

    func add(_ n: Int) { lock.withLock { used += n } }

    func beginCall() throws {
        try lock.withLock {
            calls += 1
            if calls > maxCalls { throw ToolCapExceeded(max: maxCalls) }
        }
    }

    /// Cut text at a line boundary to fit cap tokens; marker(omitted, kept) ends a cut result.
    func fit(_ text: String, cap: Int, marker: (Int, Int) -> String) async throws -> String {
        let total = try await counter.count(prompt: text, instructions: nil)
        if total <= cap { return text }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        var keep = min(lines.count - 1, lines.count * cap / max(1, total))
        while keep > 0 {
            let candidate = lines[..<keep].joined(separator: "\n") + "\n" + marker(lines.count - keep, keep)
            if try await counter.count(prompt: candidate, instructions: nil) <= cap { return candidate }
            keep = min(keep - 1, keep * 9 / 10)
        }
        return marker(lines.count, 0)
    }
}

public struct ToolOutput: Sendable {
    public var text: String
    public var marker: @Sendable (Int, Int) -> String

    public init(_ text: String, marker: @escaping @Sendable (Int, Int) -> String = { omitted, _ in "[truncated: \(omitted) more lines]" }) {
        self.text = text
        self.marker = marker
    }
}

/// Every afm tool: dynamic arguments, a running context count, a cap, truncated output.
public struct AfmTool: Tool {
    public typealias Arguments = GeneratedContent
    public typealias Output = String

    public let name: String
    public let description: String
    public let parameters: GenerationSchema
    let context: ToolContext
    let body: @Sendable (GeneratedContent) async -> ToolOutput

    public init(name: String, description: String, parameters: GenerationSchema, context: ToolContext,
                body: @escaping @Sendable (GeneratedContent) async -> ToolOutput) {
        self.name = name
        self.description = description
        self.parameters = parameters
        self.context = context
        self.body = body
    }

    public func call(arguments: GeneratedContent) async throws -> String {
        try context.beginCall()
        context.add(try await context.counter.count(prompt: compactJSON(arguments), instructions: nil))
        if context.room < 100 { return nearlyFull }
        let result = await body(arguments)
        let out = try await context.fit(result.text, cap: min(context.outputBudget, context.room), marker: result.marker)
        context.add(try await context.counter.count(prompt: out, instructions: nil))
        return out
    }
}

func stringArg(_ args: GeneratedContent, _ key: String) -> String? {
    (try? args.value(String?.self, forProperty: key)) ?? nil
}

func intArg(_ args: GeneratedContent, _ key: String) -> Int? {
    (try? args.value(Int?.self, forProperty: key)) ?? nil
}
```

`Sources/AFMuxCore/BuiltinTools.swift`:

```swift
import Foundation
import FoundationModels

private func schema(_ json: String) -> GenerationSchema {
    let obj = try! JSONSerialization.jsonObject(with: Data(json.utf8)) as! [String: Any]
    return try! SchemaLoader.convert(obj)
}

public func builtinTools(context: ToolContext) -> [AfmTool] {
    [readFile(context), grep(context), listDir(context)]
}

private func readFile(_ ctx: ToolContext) -> AfmTool {
    AfmTool(name: "read_file", description: "Read lines of a text file. Returns numbered lines.",
            parameters: schema(#"{"title":"ReadFile","type":"object","properties":{"path":{"type":"string","description":"file path, relative to the working directory or absolute"},"start_line":{"type":"integer","description":"first line to return, 1-based"},"end_line":{"type":"integer","description":"last line to return, inclusive"}},"required":["path"],"x-order":["path","start_line","end_line"]}"#),
            context: ctx) { args in
        let path = stringArg(args, "path") ?? ""
        guard let data = FileManager.default.contents(atPath: path) else { return ToolOutput("error: cannot read \(path)") }
        var lines = String(decoding: data, as: UTF8.self).components(separatedBy: "\n")
        if lines.last == "" { lines.removeLast() }
        if lines.isEmpty { return ToolOutput("(empty file)") }
        let start = max(1, intArg(args, "start_line") ?? 1)
        let end = min(lines.count, intArg(args, "end_line") ?? lines.count)
        if start > lines.count { return ToolOutput("error: \(path) has \(lines.count) lines") }
        if end < start { return ToolOutput("error: end_line is before start_line") }
        let body = (start...end).map { "\($0)\t\(lines[$0 - 1])" }.joined(separator: "\n")
        return ToolOutput(body) { omitted, kept in
            "[truncated: \(omitted) more lines; call read_file with start_line=\(start + kept)]"
        }
    }
}

private func grep(_ ctx: ToolContext) -> AfmTool {
    AfmTool(name: "grep", description: "Search files under a path for an extended regular expression. Returns file:line:text.",
            parameters: schema(#"{"title":"Grep","type":"object","properties":{"pattern":{"type":"string","description":"extended regular expression"},"path":{"type":"string","description":"file or directory to search"},"glob":{"type":"string","description":"only files whose name matches, e.g. *.swift"}},"required":["pattern","path"],"x-order":["pattern","path","glob"]}"#),
            context: ctx) { args in
        var argv = ["/usr/bin/grep", "-rnIE", "--exclude-dir=.git"]
        if let glob = stringArg(args, "glob"), !glob.isEmpty { argv.append("--include=\(glob)") }
        argv += ["-e", stringArg(args, "pattern") ?? "", "--", stringArg(args, "path") ?? "."]
        let r = await runProcess(argv, timeout: ctx.toolTimeout)
        if r.timedOut { return ToolOutput("timed out after \(pyG(ctx.toolTimeout)) s") }
        switch r.status {
        case 0: return ToolOutput(r.stdout.rstripped())
        case 1: return ToolOutput("no matches")
        default: return ToolOutput("error: " + r.stderr.rstripped())
        }
    }
}

private func listDir(_ ctx: ToolContext) -> AfmTool {
    AfmTool(name: "list_dir", description: "List a directory. Directories end with /.",
            parameters: schema(#"{"title":"ListDir","type":"object","properties":{"path":{"type":"string","description":"directory, relative to the working directory or absolute"}},"required":["path"]}"#),
            context: ctx) { args in
        let path = stringArg(args, "path") ?? "."
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: path) else {
            return ToolOutput("error: cannot list \(path)")
        }
        let lines = names.sorted().map { name -> String in
            var isDir: ObjCBool = false
            FileManager.default.fileExists(atPath: (path as NSString).appendingPathComponent(name), isDirectory: &isDir)
            return isDir.boolValue ? name + "/" : name
        }
        return ToolOutput(lines.isEmpty ? "(empty directory)" : lines.joined(separator: "\n"))
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `swift test --filter ToolTests`
Expected: all pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/AFMuxCore/Proc.swift Sources/AFMuxCore/Tools.swift Sources/AFMuxCore/BuiltinTools.swift Tests/AFMuxCoreTests/ToolTests.swift
git commit -m "Add process runner, tool context and built-in tools"
```

---

### Task 10: Caller-defined tools and tool wiring

**Files:**
- Create: `Sources/AFMuxCore/CommandTools.swift`, `Tests/CLITests/ToolCLITests.swift`
- Modify: `Sources/AFMuxCore/Tools.swift` (add `Toolset`), `Sources/AFMuxCore/App.swift` (`runOnce`)
- Test: `Tests/AFMuxCoreTests/CommandToolTests.swift`

**Interfaces:**
- Consumes: `AfmTool`, `ToolContext`, `ToolOutput`, `runProcess`, `SchemaLoader`, `compactJSON`.
- Produces: `struct ToolSpec { name; description; parameters: GenerationSchema; argumentNames: [String]; command: [String] }`, `func loadToolsFile(_ path: String) throws -> [ToolSpec]`, `func substitute(_ command: [String], arguments: GeneratedContent, names: [String]) -> [String]`, `func commandTool(_: ToolSpec, context: ToolContext) -> AfmTool`, `struct Toolset { tools: [any Tool]; context: ToolContext?; static func make(_: Options, counter: any TokenCounter) throws -> Toolset }`.

- [ ] **Step 1: Write the failing tests**

`Tests/AFMuxCoreTests/CommandToolTests.swift`:

```swift
import Foundation
import FoundationModels
import Testing
@testable import AFMuxCore

private func toolsFile(_ json: String) throws -> String {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("tools-\(UUID().uuidString).json")
    try json.write(to: url, atomically: true, encoding: .utf8)
    return url.path
}

private func loadError(_ json: String) -> String? {
    do { _ = try loadToolsFile(try toolsFile(json)); return nil } catch let e as AfmError { return e.message } catch { return "\(error)" }
}

@Test func substitutionRendersEachType() throws {
    let args = try GeneratedContent(json: #"{"s":"a b","n":3,"f":0.5,"b":true,"l":[1,"x"],"brace":"{n}"}"#)
    let argv = substitute(["cmd", "{s}", "-n{n}", "{f}", "{b}", "{l}", "{missing}", "{unknown_name}", "{brace}"],
                          arguments: args, names: ["s", "n", "f", "b", "l", "missing", "brace"])
    #expect(argv == ["cmd", "a b", "-n3", "0.5", "true", "[1,\"x\"]", "", "{unknown_name}", "{n}"])
}

@Test func toolsFileValidation() {
    #expect(loadError("[]") == nil || loadError("[]")!.contains("must be an object with a \"tools\" array"))
    #expect(loadError(#"{"tools":[{"name":"Bad"}]}"#) == "tool #1: name must match [a-z][a-z0-9_]*")
    #expect(loadError(#"{"tools":[{"name":"grep","description":"d","command":["x"]}]}"#) == "tool grep: name is taken by a built-in tool")
    #expect(loadError(#"{"tools":[{"name":"t","description":"d","command":["x"]},{"name":"t","description":"d","command":["x"]}]}"#) == "tool t: duplicate name")
    #expect(loadError(#"{"tools":[{"name":"t","command":["x"]}]}"#) == "tool t: description is required")
    #expect(loadError(#"{"tools":[{"name":"t","description":"d","command":[]}]}"#) == "tool t: command must be a non-empty array of strings")
    #expect(loadError(#"{"tools":[{"name":"t","description":"d","command":["x"],"arguments":{"type":"object","oneOf":[]}}]}"#) == "tool t: arguments: unsupported keyword 'oneOf'")
}

@Test func commandToolRunsAndReports() async throws {
    let specs = try loadToolsFile(try toolsFile(#"{"tools":[{"name":"say","description":"echo a message","arguments":{"type":"object","properties":{"msg":{"type":"string"}},"required":["msg"]},"command":["/bin/sh","-c","echo \"$1\"; echo warn >&2; exit 2","_","{msg}"]}]}"#))
    let ctx = ToolContext(counter: FakeBackend(script: FakeScript()).counter, maxCalls: 8, outputBudget: 600, toolTimeout: 5)
    let out = try await commandTool(specs[0], context: ctx).call(arguments: GeneratedContent(json: #"{"msg":"hi there"}"#))
    #expect(out == "exit 2\nstdout:\nhi there\nstderr:\nwarn")
}
```

`Tests/CLITests/ToolCLITests.swift`:

```swift
import Foundation
import Testing

@Suite struct ToolCLITests {
    @Test func askWithToolsAndNoStdinUsesToolInstructions() throws {
        let r = try afm(["ask", "--tools", "fs", "which file defines x?"], tty: true)
        #expect(r.code == 0, "\(r.err)")
        let rec = r.records("respond")[0]
        #expect(rec["instructions"] as? String == "Answer the request. Use the tools to find the information you need. Reply with only the answer.")
        #expect(rec["prompt"] as? String == "which file defines x?")
        #expect(rec["tools"] as? [String] == ["read_file", "grep", "list_dir"])
    }

    @Test func toolOutputReachesTheModel() throws {
        let dir = makeTmp()
        try "hello tools\n".write(to: dir.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        let r = try afm(["ask", "--tools", "fs", "read a.txt"], fake: ["respond": ["toolCalls": [["name": "read_file", "arguments": #"{"path":"a.txt"}"#]], "text": "done"]], tmp: dir)
        #expect(r.code == 0, "\(r.err)")
        #expect(r.out == "done\n")
        #expect((r.records("toolOutputs")[0]["outputs"] as? [String]) == ["1\thello tools"])
    }

    @Test func toolCallCapIsExit1() throws {
        let call = ["name": "list_dir", "arguments": #"{"path":"."}"#]
        let r = try afm(["ask", "--tools", "fs", "--max-tool-calls", "2", "look"], fake: ["respond": ["toolCalls": [call, call, call]]])
        #expect(r.code == 1, "\(r.err)")
        #expect(r.err.contains("more than 2 tool calls"))
    }

    @Test func commandToolFromFile() throws {
        let dir = makeTmp()
        let file = dir.appendingPathComponent("tools.json")
        try #"{"tools":[{"name":"say","description":"echo","arguments":{"type":"object","properties":{"msg":{"type":"string"}},"required":["msg"]},"command":["/bin/echo","{msg}"]}]}"#
            .write(to: file, atomically: true, encoding: .utf8)
        let r = try afm(["ask", "--tools-file", file.path, "say hi"], fake: ["respond": ["toolCalls": [["name": "say", "arguments": #"{"msg":"hi"}"#]]]], tmp: dir)
        #expect(r.code == 0, "\(r.err)")
        #expect((r.records("toolOutputs")[0]["outputs"] as? [String]) == ["exit 0\nstdout:\nhi\nstderr:\n"])
    }

    @Test func toolUsageErrors() throws {
        #expect(try afm(["ask", "--tools", "fs", "--chunk", "x"], stdin: "y").err.contains("--chunk is not allowed with tools"))
        let r = try afm(["summarise", "--tools", "fs"], tty: true)
        #expect(r.code == 2 && r.err.contains("reads its input from stdin"))
        #expect(try afm(["ask", "--tools-file", "/nonexistent.json", "x"], stdin: "y").err.contains("tools file not found: /nonexistent.json"))
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift build && swift test --filter "CommandToolTests|ToolCLITests"`
Expected: compile failure, `cannot find 'loadToolsFile' in scope`.

- [ ] **Step 3: Implement**

`Sources/AFMuxCore/CommandTools.swift`:

```swift
import Foundation
import FoundationModels

public struct ToolSpec: Sendable {
    public var name: String
    public var description: String
    public var parameters: GenerationSchema
    public var argumentNames: [String]
    public var command: [String]
}

public let builtinNames: Set<String> = ["read_file", "grep", "list_dir"]

public func loadToolsFile(_ path: String) throws -> [ToolSpec] {
    guard let data = FileManager.default.contents(atPath: path) else {
        throw AfmError(.usage, "tools file not found: \(path)")
    }
    let root: Any
    do {
        root = try JSONSerialization.jsonObject(with: data)
    } catch {
        throw AfmError(.usage, "tools file \(path) is not valid JSON (\(error.localizedDescription))")
    }
    guard let obj = root as? [String: Any], let list = obj["tools"] as? [Any] else {
        throw AfmError(.usage, "tools file \(path) must be an object with a \"tools\" array")
    }
    var specs: [ToolSpec] = []
    var seen = Set<String>()
    for (k, item) in list.enumerated() {
        guard let t = item as? [String: Any] else { throw AfmError(.usage, "tool #\(k + 1): must be an object") }
        guard let name = t["name"] as? String, name.range(of: "^[a-z][a-z0-9_]*$", options: .regularExpression) != nil else {
            throw AfmError(.usage, "tool #\(k + 1): name must match [a-z][a-z0-9_]*")
        }
        if builtinNames.contains(name) { throw AfmError(.usage, "tool \(name): name is taken by a built-in tool") }
        if !seen.insert(name).inserted { throw AfmError(.usage, "tool \(name): duplicate name") }
        guard let description = t["description"] as? String, !description.isEmpty else {
            throw AfmError(.usage, "tool \(name): description is required")
        }
        guard let command = t["command"] as? [String], !command.isEmpty else {
            throw AfmError(.usage, "tool \(name): command must be a non-empty array of strings")
        }
        var arguments: [String: Any] = ["type": "object", "properties": [String: Any]()]
        if let given = t["arguments"] {
            guard let dict = given as? [String: Any] else {
                throw AfmError(.usage, "tool \(name): arguments must be a JSON Schema object")
            }
            arguments = dict
        }
        if arguments["title"] == nil { arguments["title"] = name }
        let parameters: GenerationSchema
        do {
            parameters = try SchemaLoader.load(try JSONSerialization.data(withJSONObject: arguments))
        } catch let p as SchemaProblem {
            throw AfmError(.usage, "tool \(name): arguments: \(p.message)")
        }
        let names = Array(((arguments["properties"] as? [String: Any]) ?? [:]).keys)
        specs.append(ToolSpec(name: name, description: description, parameters: parameters, argumentNames: names, command: command))
    }
    return specs
}

private let placeholder = try! NSRegularExpression(pattern: "\\{([A-Za-z0-9_]+)\\}")

/// Replace {name} in each argv element, in one pass, for declared argument names only.
public func substitute(_ command: [String], arguments: GeneratedContent, names: [String]) -> [String] {
    command.map { element in
        let ns = element as NSString
        var out = ""
        var pos = 0
        for m in placeholder.matches(in: element, range: NSRange(location: 0, length: ns.length)) {
            out += ns.substring(with: NSRange(location: pos, length: m.range.location - pos))
            let key = ns.substring(with: m.range(at: 1))
            out += names.contains(key) ? render(arguments, key) : ns.substring(with: m.range)
            pos = NSMaxRange(m.range)
        }
        return out + ns.substring(from: pos)
    }
}

private func render(_ arguments: GeneratedContent, _ key: String) -> String {
    guard case .structure(let props, _) = arguments.kind, let value = props[key] else { return "" }
    switch value.kind {
    case .string(let s): return s
    case .null: return ""
    default: return compactJSON(value)
    }
}

public func commandTool(_ spec: ToolSpec, context: ToolContext) -> AfmTool {
    AfmTool(name: spec.name, description: spec.description, parameters: spec.parameters, context: context) { args in
        let argv = substitute(spec.command, arguments: args, names: spec.argumentNames)
        let r = await runProcess(argv, timeout: context.toolTimeout)
        if r.timedOut { return ToolOutput("timed out after \(pyG(context.toolTimeout)) s") }
        return ToolOutput("exit \(r.status)\nstdout:\n\(r.stdout.rstripped())\nstderr:\n\(r.stderr.rstripped())")
    }
}
```

Append to `Sources/AFMuxCore/Tools.swift`:

```swift
/// The tools enabled for one afm call and their shared context.
public struct Toolset: Sendable {
    public var tools: [any Tool] = []
    public var context: ToolContext?

    public static func make(_ o: Options, counter: any TokenCounter) throws -> Toolset {
        guard o.toolsOn else { return Toolset() }
        let ctx = ToolContext(counter: counter, maxCalls: o.maxToolCalls, outputBudget: o.toolOutputBudget, toolTimeout: o.toolTimeout)
        var tools: [any Tool] = o.toolsFS ? builtinTools(context: ctx) : []
        if let path = o.toolsFile {
            tools += try loadToolsFile(path).map { commandTool($0, context: ctx) }
        }
        return Toolset(tools: tools, context: ctx)
    }
}
```

In `Sources/AFMuxCore/App.swift` `runOnce`, replace

```swift
    let tools: [any Tool] = []
```

with

```swift
    let toolset = try Toolset.make(o, counter: counter)
    let tools = toolset.tools
```

and directly before the final `do {` (the non-chunk call) insert

```swift
    toolset.context?.start(used: total)
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `swift build && swift test`
Expected: all pass. If the framework does not deliver `ToolCapExceeded` (inside `ToolCallError`) as the thrown error, print the error type in `toolCallCapIsExit1` and adjust `mapError`, not the test.

- [ ] **Step 5: Commit**

```bash
git add Sources/AFMuxCore Tests
git commit -m "Add caller-defined command tools and wire tools into afm"
```

---

### Task 11: Sessions

**Files:**
- Create: `Sources/AFMuxCore/Cleanup.swift`, `Sources/AFMuxCore/Session.swift`, `Sources/AFMuxCore/SessionTurn.swift`, `Tests/CLITests/SessionCLITests.swift`
- Modify: `Sources/AFMuxCore/App.swift` (`runAfm`)

**Interfaces:**
- Consumes: `Options`, `resolveJob`, `parseLabels`, `readInput`, `callShape`, `instructionsEntry`, `text(of:)`, `jobSchema`, `Toolset`, `TimedCounter`, `runModel`, `withTimeout`, `checkedAnswer`, `mapError`.
- Produces: `final class TempFiles { static let shared; add/remove/removeAll }`; `struct SessionFile: Codable`; `struct SessionStore(env:)` with `validate`, `load`, `save`, `lock`, `unlock`, `listing`, `remove`; `func sessionsCommand(_ args: [String], io: IO) throws -> Int32`; `func runSessionTurn(_ o: Options, name: String, io: IO, backend: any Backend) async throws -> Int32`.

- [ ] **Step 1: Write the failing tests**

`Tests/CLITests/SessionCLITests.swift`:

```swift
import Foundation
import Testing

@Suite struct SessionCLITests {
    func sessionFile(_ dir: URL, _ name: String) -> URL { dir.appendingPathComponent("sessions/\(name).json") }

    @Test func twoTurnAskSession() throws {
        let dir = makeTmp()
        let first = try afm(["ask", "Remember this.", "--session", "s1"], stdin: "The codename is BLUEHERON.", tmp: dir)
        #expect(first.code == 0, "\(first.err)")
        let second = try afm(["ask", "What is the codename?", "--session", "s1"], tty: true, fake: ["respond": ["text": "BLUEHERON"]], tmp: dir)
        #expect(second.code == 0, "\(second.err)")
        #expect(second.out == "BLUEHERON\n")
        let rec = second.records("respond")[0]
        #expect(rec["instructions"] as? String == "Remember this.")
        #expect(rec["prompt"] as? String == "What is the codename?")
        #expect(rec["history"] as? Int == 2)
        let file = try JSONSerialization.jsonObject(with: Data(contentsOf: sessionFile(dir, "s1"))) as! [String: Any]
        #expect(file["turns"] as? Int == 2 && file["job"] as? String == "ask")
    }

    @Test func followUpAppendsStdinToQuestion() throws {
        let dir = makeTmp()
        try afm(["ask", "Read logs.", "--session", "s"], stdin: "log one", tmp: dir)
        let r = try afm(["ask", "And this?", "--session", "s"], stdin: "log two", tmp: dir)
        #expect(r.records("respond")[0]["prompt"] as? String == "And this?\n\nlog two")
    }

    @Test func failedTurnLeavesFileUnchanged() throws {
        let dir = makeTmp()
        try afm(["ask", "x", "--session", "s"], stdin: "one", tmp: dir)
        let before = try Data(contentsOf: sessionFile(dir, "s"))
        let r = try afm(["ask", "y", "--session", "s"], stdin: "two", fake: ["respond": ["error": "guardrail"]], tmp: dir)
        #expect(r.code == 1)
        #expect(try Data(contentsOf: sessionFile(dir, "s")) == before)
    }

    @Test func presetSessionKeepsLabels() throws {
        let dir = makeTmp()
        let fake: [String: Any] = ["respond": ["text": #"{"label":"bug"}"#]]
        #expect(try afm(["classify", "--labels", "bug,feature", "--session", "c"], stdin: "crash", fake: fake, tmp: dir).code == 0)
        let r = try afm(["classify", "--session", "c"], stdin: "another crash", fake: fake, tmp: dir)
        #expect(r.code == 0, "\(r.err)")
        #expect(r.records("respond")[0]["prompt"] as? String == "another crash")
        #expect(try afm(["classify", "--labels", "x,y", "--session", "c"], stdin: "z", fake: fake, tmp: dir).err.contains("was created with --labels bug,feature"))
    }

    @Test func mismatchesAreUsageErrors() throws {
        let dir = makeTmp()
        try afm(["ask", "x", "--session", "s"], stdin: "one", tmp: dir)
        #expect(try afm(["summarise", "--session", "s"], stdin: "two", tmp: dir).err.contains("session s is a ask session"))
        let g = try afm(["ask", "y", "--session", "s", "--guardrails", "default"], stdin: "two", tmp: dir)
        #expect(g.code == 2 && g.err.contains("was created with --guardrails permissive-content-transformations"))
        #expect(try afm(["ask", "y", "--session", "bad/name"], stdin: "two", tmp: dir).code == 2)
        #expect(try afm(["ask", "y", "--session", "s", "--chunk"], stdin: "two", tmp: dir).err.contains("--chunk is not allowed with --session"))
    }

    @Test func busySessionTimesOut() throws {
        let dir = makeTmp()
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("sessions"), withIntermediateDirectories: true)
        let fd = open(dir.appendingPathComponent("sessions/s.lock").path, O_CREAT | O_RDWR, 0o644)
        #expect(flock(fd, LOCK_EX) == 0)
        defer { close(fd) }
        let r = try afm(["ask", "x", "--session", "s", "--timeout", "0.3"], stdin: "one", tmp: dir)
        #expect(r.code == 1)
        #expect(r.err.contains("session s is busy"))
    }

    @Test func listAndRemove() throws {
        let dir = makeTmp()
        try afm(["ask", "x", "--session", "alpha"], stdin: "one", tmp: dir)
        let list = try afm(["sessions"], tmp: dir)
        #expect(list.code == 0)
        let fields = list.out.trimmingCharacters(in: .newlines).split(separator: "\t").map(String.init)
        #expect(fields[0] == "alpha" && fields[1] == "1" && Int(fields[2]) != nil && fields[3].contains("T"))
        #expect(try afm(["sessions", "rm", "alpha"], tmp: dir).code == 0)
        #expect(try afm(["sessions"], tmp: dir).out == "")
        let missing = try afm(["sessions", "rm", "alpha"], tmp: dir)
        #expect(missing.code == 2 && missing.err.contains("session alpha does not exist"))
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift build && swift test --filter SessionCLITests`
Expected: failures (sessions are not implemented; `--session` is ignored).

- [ ] **Step 3: Implement**

`Sources/AFMuxCore/Cleanup.swift`:

```swift
import Foundation

/// Temporary files to delete if a signal ends the process.
public final class TempFiles: @unchecked Sendable {
    public static let shared = TempFiles()
    private let lock = NSLock()
    private var paths = Set<String>()

    func add(_ path: String) { lock.withLock { _ = paths.insert(path) } }
    func remove(_ path: String) { lock.withLock { _ = paths.remove(path) } }

    public func removeAll() {
        lock.withLock {
            for p in paths { unlink(p) }
            paths.removeAll()
        }
    }
}
```

`Sources/AFMuxCore/Session.swift`:

```swift
import Foundation
import FoundationModels

public struct SessionFile: Codable, Sendable {
    public var version = 1
    public var job: String
    public var labels: [String]?
    public var guardrails: String
    public var useCase: String
    public var turns: Int
    public var tokens: Int
    public var modified: String
    public var transcript: Transcript
}

public struct SessionStore: Sendable {
    public let dir: URL

    public init(env: [String: String]) {
        if let override = env["AFMUX_SESSIONS_DIR"] {
            dir = URL(fileURLWithPath: override)
        } else {
            dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/afmux/sessions")
        }
    }

    public static func validate(_ name: String) throws {
        guard name.range(of: "^[A-Za-z0-9._-]+$", options: .regularExpression) != nil else {
            throw AfmError(.usage, "session name \(pyRepr(name)) must match [A-Za-z0-9._-]+")
        }
    }

    func url(_ name: String) -> URL { dir.appendingPathComponent(name + ".json") }

    public func load(_ name: String) throws -> SessionFile? {
        guard let data = FileManager.default.contents(atPath: url(name).path) else { return nil }
        do {
            return try JSONDecoder().decode(SessionFile.self, from: data)
        } catch {
            throw AfmError(.model, "session \(name) cannot be read (\(error.localizedDescription))")
        }
    }

    /// Write to a temporary file in the same directory, then rename over the session.
    public func save(_ name: String, _ file: SessionFile) throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let tmp = dir.appendingPathComponent(".\(name).\(getpid()).tmp")
        TempFiles.shared.add(tmp.path)
        defer { TempFiles.shared.remove(tmp.path) }
        try JSONEncoder().encode(file).write(to: tmp)
        if rename(tmp.path, url(name).path) != 0 {
            let reason = String(cString: strerror(errno))
            unlink(tmp.path)
            throw AfmError(.model, "cannot save session \(name): \(reason)")
        }
    }

    /// Exclusive flock on NAME.lock, retried every 50 ms until timeout.
    public func lock(_ name: String, timeout: Double) throws -> Int32 {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let fd = open(dir.appendingPathComponent(name + ".lock").path, O_CREAT | O_RDWR, 0o644)
        guard fd >= 0 else { throw AfmError(.model, "cannot lock session \(name)") }
        let deadline = Date().addingTimeInterval(timeout)
        while flock(fd, LOCK_EX | LOCK_NB) != 0 {
            if Date() >= deadline {
                close(fd)
                throw AfmError(.model, "session \(name) is busy")
            }
            usleep(50_000)
        }
        return fd
    }

    public func unlock(_ fd: Int32) {
        flock(fd, LOCK_UN)
        close(fd)
    }

    /// name<TAB>turns<TAB>tokens<TAB>modified, one line per session, sorted by name.
    public func listing() -> String {
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [])
            .filter { $0.hasSuffix(".json") && !$0.hasPrefix(".") }
            .map { String($0.dropLast(5)) }
            .sorted()
        return names.compactMap { name -> String? in
            guard let file = try? load(name) else { return nil }
            return "\(name)\t\(file.turns)\t\(file.tokens)\t\(file.modified)\n"
        }.joined()
    }

    public func remove(_ name: String) throws {
        guard FileManager.default.fileExists(atPath: url(name).path) else {
            throw AfmError(.usage, "session \(name) does not exist")
        }
        try FileManager.default.removeItem(at: url(name))
        try? FileManager.default.removeItem(at: dir.appendingPathComponent(name + ".lock"))
    }
}

public func sessionsCommand(_ args: [String], io: IO) throws -> Int32 {
    let store = SessionStore(env: io.env)
    if args.isEmpty {
        io.out(store.listing())
        return 0
    }
    if args.count == 2 && args[0] == "rm" {
        try SessionStore.validate(args[1])
        try store.remove(args[1])
        return 0
    }
    throw AfmError(.usage, "usage: afm sessions | afm sessions rm NAME")
}
```

`Sources/AFMuxCore/SessionTurn.swift`:

```swift
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
    let schemaTokens = try await schema.map { try await counter.count(schema: $0) } ?? 0
    let fixed = try await counter.count(prompt: prompt, instructions: instructions) + schemaTokens
    var total = fixed + (try await counter.count(entries: history))
    let model = backend.model(guardrails: o.guardrails, useCase: o.useCase)
    if total > o.budget {
        throw AfmError(.budget, "input is \(total) tokens, budget is \(o.budget)")
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
```

(`total` is a `var` because Task 12 reassigns it after compaction.)

In `Sources/AFMuxCore/App.swift` `runAfm`, make the first lines of the `do` block:

```swift
        if argv.first == "sessions" { return try sessionsCommand(Array(argv.dropFirst()), io: io) }
        let o = try parseArgs(argv)
```

and before `return try await runOnce(o, io: io, backend: backend)` insert:

```swift
        if let name = o.session { return try await runSessionTurn(o, name: name, io: io, backend: backend) }
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `swift build && swift test`
Expected: all pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/AFMuxCore Tests/CLITests/SessionCLITests.swift
git commit -m "Add sessions: storage, locking, turns and afm sessions"
```

---

### Task 12: Compaction

**Files:**
- Create: `Sources/AFMuxCore/Compaction.swift`, `Tests/CLITests/CompactionCLITests.swift`
- Modify: `Sources/AFMuxCore/SessionTurn.swift`
- Test: `Tests/AFMuxCoreTests/CompactionTests.swift`

**Interfaces:**
- Consumes: `planChunks`, `runModel`, `withTimeout`, `mapError`, `instructionsEntry`, `text(of:)`, `compactJSON`.
- Produces: `let compactionInstructions: String`, `func render(_ entries: [Transcript.Entry]) -> String`, `func summaryEntries(_ summary: String) -> [Transcript.Entry]`, `struct Compaction { name; budget; maxChunks; timeout; counter; model; backend; err; func compact(_ history: [Transcript.Entry], fixed: Int) async throws -> [Transcript.Entry] }`.

- [ ] **Step 1: Write the failing tests**

`Tests/AFMuxCoreTests/CompactionTests.swift`:

```swift
import FoundationModels
import Testing
@testable import AFMuxCore

@Test func renderLabelsRoles() throws {
    let entries: [Transcript.Entry] = [
        .prompt(Transcript.Prompt(segments: [.text(.init(content: "hi"))])),
        .toolCalls(Transcript.ToolCalls([Transcript.ToolCall(id: "1", toolName: "grep", arguments: try GeneratedContent(json: #"{"pattern":"x"}"#))])),
        .toolOutput(Transcript.ToolOutput(id: "1", toolName: "grep", segments: [.text(.init(content: "a:1:x"))])),
        .response(Transcript.Response(segments: [.text(.init(content: "found"))])),
    ]
    #expect(render(entries) == "User: hi\n\nTool call: grep({\"pattern\":\"x\"})\n\nTool output (grep): a:1:x\n\nAssistant: found")
}

@Test func summaryEntryShape() {
    let entries = summaryEntries("facts")
    #expect(entries.count == 2)
    #expect(entryText(entries[0]) == "Summary of earlier conversation:\nfacts")
    #expect(entryText(entries[1]) == "OK")
}
```

`Tests/CLITests/CompactionCLITests.swift`:

```swift
import Foundation
import Testing

@Suite struct CompactionCLITests {
    // Fake counts are ceil(bytes / 4). Turn 1 stores 200 bytes (50 tokens); turn 2's prompt is
    // "Q?" + 320 bytes (about 84 tokens with instructions), so 135 > 120 triggers compaction,
    // the rendered history plus compaction instructions (about 88) fits one summary call,
    // and the summary pair (13) brings the total to about 97.
    let first = String(repeating: "word ", count: 40)
    let second = String(repeating: "x", count: 320)
    let long = String(repeating: "word ", count: 80)

    @Test func compactsWhenHistoryOverflows() throws {
        let dir = makeTmp()
        #expect(try afm(["ask", "Keep notes.", "--session", "s"], stdin: first, tmp: dir).code == 0)
        let r = try afm(["ask", "Q?", "--session", "s", "--budget", "120"], stdin: second,
                        fake: ["respond": ["texts": ["SHORT SUMMARY", "ANSWER"]]], tmp: dir)
        #expect(r.code == 0, "\(r.err)")
        #expect(r.out == "ANSWER\n")
        #expect(r.err.contains("afm: session s compacted ("))
        let calls = r.records("respond")
        #expect(calls[0]["instructions"] as? String == "Summarise this conversation for later reference. Keep facts, names, numbers, file paths and decisions. Omit pleasantries.")
        #expect(calls[0]["maxTokens"] as? Int == 40)
        #expect((calls[0]["prompt"] as? String)?.hasPrefix("User: ") == true)
        #expect(calls[1]["history"] as? Int == 2)
        let saved = try String(contentsOf: dir.appendingPathComponent("sessions/s.json"), encoding: .utf8)
        #expect(saved.contains("SHORT SUMMARY"))
    }

    @Test func failedSummaryLeavesSessionUnchanged() throws {
        let dir = makeTmp()
        try afm(["ask", "Keep notes.", "--session", "s"], stdin: first, tmp: dir)
        let before = try Data(contentsOf: dir.appendingPathComponent("sessions/s.json"))
        let r = try afm(["ask", "Q?", "--session", "s", "--budget", "120"], stdin: second,
                        fake: ["respond": ["error": "guardrail", "failOnCall": 1]], tmp: dir)
        #expect(r.code == 1)
        #expect(r.err.contains("compaction: "))
        #expect(try Data(contentsOf: dir.appendingPathComponent("sessions/s.json")) == before)
    }

    @Test func promptAloneOverBudgetIsExit6() throws {
        let dir = makeTmp()
        try afm(["ask", "Keep notes.", "--session", "s"], stdin: "short", tmp: dir)
        let r = try afm(["ask", "Q?", "--session", "s", "--budget", "40"], stdin: long, tmp: dir)
        #expect(r.code == 6, "\(r.err)")
        #expect(r.err.contains("budget is 40") && !r.err.contains("--chunk"))
    }

    @Test func tooLargeToCompact() throws {
        let dir = makeTmp()
        try afm(["ask", "Keep notes.", "--session", "s"], stdin: Array(repeating: long, count: 6).joined(separator: "\n\n"), tmp: dir)
        let r = try afm(["ask", "Q?", "--session", "s", "--budget", "120", "--max-chunks", "1"], tty: true, tmp: dir)
        #expect(r.code == 6, "\(r.err)")
        #expect(r.err.contains("session s is too large to compact"))
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift build && swift test --filter "CompactionTests|CompactionCLITests"`
Expected: compile failure, `cannot find 'render' in scope`.

- [ ] **Step 3: Implement**

`Sources/AFMuxCore/Compaction.swift`:

```swift
import Foundation
import FoundationModels

public let compactionInstructions = "Summarise this conversation for later reference. Keep facts, names, numbers, file paths and decisions. Omit pleasantries."

/// Transcript entries as plain text, labelled by role, for the summary call.
public func render(_ entries: [Transcript.Entry]) -> String {
    entries.compactMap { entry -> String? in
        switch entry {
        case .prompt(let p): return "User: " + text(of: p.segments)
        case .response(let r): return "Assistant: " + text(of: r.segments)
        case .toolCalls(let calls): return calls.map { "Tool call: \($0.toolName)(\(compactJSON($0.arguments)))" }.joined(separator: "\n")
        case .toolOutput(let o): return "Tool output (\(o.toolName)): " + text(of: o.segments)
        default: return nil
        }
    }.joined(separator: "\n\n")
}

public func summaryEntries(_ summary: String) -> [Transcript.Entry] {
    [
        .prompt(Transcript.Prompt(segments: [.text(.init(content: "Summary of earlier conversation:\n" + summary))])),
        .response(Transcript.Response(segments: [.text(.init(content: "OK"))])),
    ]
}

struct Compaction {
    let name: String
    let budget: Int
    let maxChunks: Int
    let timeout: Double
    let counter: any TokenCounter
    let model: any LanguageModel
    let backend: any Backend
    let err: @Sendable (String) -> Void

    /// fixed is the new prompt + instructions + schema. Returns a history that fits, or throws exit 6.
    func compact(_ history: [Transcript.Entry], fixed: Int) async throws -> [Transcript.Entry] {
        if fixed > budget { throw AfmError(.budget, "input is \(fixed) tokens, budget is \(budget)") }
        let before = fixed + (try await counter.count(entries: history))
        let split = history.lastIndex { if case .prompt = $0 { return true } else { return false } } ?? history.count
        var middle = Array(history[..<split])
        var kept = Array(history[split...])
        if middle.isEmpty {
            middle = kept
            kept = []
        }
        var total = before
        for _ in 0..<2 {
            let candidate = summaryEntries(try await summarise(middle)) + kept
            total = fixed + (try await counter.count(entries: candidate))
            if total <= budget {
                err("afm: session \(name) compacted (\(before) \u{2192} \(total) tokens)\n")
                return candidate
            }
            if kept.isEmpty { break }
            middle = candidate
            kept = []
        }
        throw AfmError(.budget, "input is \(total) tokens, budget is \(budget)")
    }

    private func summarise(_ entries: [Transcript.Entry]) async throws -> String {
        let text = render(entries)
        let instructions = instructionsEntry(compactionInstructions, tools: [])
        let total = try await counter.count(prompt: text, instructions: instructions)
        var pieces = [text]
        if total > budget {
            do {
                pieces = try await planChunks(text: text, instructions: instructions, schemaTokens: 0, budget: budget,
                                              maxChunks: maxChunks, totalTokens: total, counter: counter)
            } catch let e as AfmError where e.code == .budget {
                throw AfmError(.budget, "session \(name) is too large to compact")
            }
        }
        var parts: [String] = []
        for piece in pieces {
            let call = ModelCall(instructions: instructions, prompt: piece, maxResponseTokens: budget / 3)
            let model = self.model
            do {
                parts.append(try await withTimeout(timeout) { try await runModel(call, model: model) }.text.rstripped())
            } catch {
                let e = mapError(error, backend: backend)
                throw AfmError(e.code, "compaction: \(e.message)")
            }
        }
        return parts.joined(separator: "\n")
    }
}
```

In `Sources/AFMuxCore/SessionTurn.swift` replace

```swift
    if total > o.budget {
        throw AfmError(.budget, "input is \(total) tokens, budget is \(o.budget)")
    }
```

with

```swift
    if total > o.budget {
        let compaction = Compaction(name: name, budget: o.budget, maxChunks: o.maxChunks, timeout: o.timeout,
                                    counter: counter, model: model, backend: backend, err: io.err)
        history = try await compaction.compact(history, fixed: fixed)
        total = fixed + (try await counter.count(entries: history))
    }
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `swift build && swift test`
Expected: all pass. The CLI expectations depend on the fake counter's byte formula; if `compactsWhenHistoryOverflows` does not trigger compaction, print the count records and adjust `second`, keeping `--budget 120` (so `maxTokens` stays 40).

- [ ] **Step 5: Commit**

```bash
git add Sources/AFMuxCore Tests
git commit -m "Add automatic session compaction"
```

---

### Task 13: Signals

**Files:**
- Create: `Sources/AFMuxCore/Signals.swift`, `Tests/CLITests/SignalCLITests.swift`
- Modify: `Sources/afm/main.swift`

**Interfaces:**
- Consumes: `ProcessGroups`, `TempFiles`.
- Produces: `enum Signals { static func install() }`.

- [ ] **Step 1: Write the failing tests**

`Tests/CLITests/SignalCLITests.swift`:

```swift
import Foundation
import Testing

/// Start afm in fake mode without waiting, for signal tests.
private func start(_ args: [String], fake: [String: Any], dir: URL) throws -> (Process, Pipe, Pipe) {
    var script = fake
    script["log"] = dir.appendingPathComponent("log.jsonl").path
    try JSONSerialization.data(withJSONObject: script).write(to: dir.appendingPathComponent("fake.json"))
    let p = Process()
    p.executableURL = URL(fileURLWithPath: afmPath)
    p.arguments = args
    var e = ProcessInfo.processInfo.environment
    e["AFMUX_FAKE"] = dir.appendingPathComponent("fake.json").path
    e["AFMUX_SESSIONS_DIR"] = dir.appendingPathComponent("sessions").path
    p.environment = e
    p.currentDirectoryURL = dir
    let out = Pipe(), err = Pipe(), input = Pipe()
    p.standardOutput = out
    p.standardError = err
    p.standardInput = input
    try p.run()
    input.fileHandleForWriting.write(Data("hello".utf8))
    try input.fileHandleForWriting.close()
    return (p, out, err)
}

private func waitFor(_ condition: () -> Bool) {
    for _ in 0..<100 where !condition() { usleep(100_000) }
}

@Suite struct SignalCLITests {
    @Test func sigtermDuringGenerationExits1() throws {
        let dir = makeTmp()
        let (p, out, err) = try start(["classify", "--labels", "a,b"], fake: ["respond": ["delay": 10]], dir: dir)
        waitFor { Run(code: 0, out: "", err: "", tmp: dir).records("respond").count > 0 }
        p.terminate()
        p.waitUntilExit()
        #expect(p.terminationStatus == 1)
        #expect(out.fileHandleForReading.readDataToEndOfFile().isEmpty)
        #expect(String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).contains("interrupted by signal 15"))
    }

    @Test func sigtermKillsToolProcessGroupAndKeepsSession() throws {
        let dir = makeTmp()
        let pidFile = dir.appendingPathComponent("child.pid").path
        let tools = dir.appendingPathComponent("tools.json")
        try #"{"tools":[{"name":"slow","description":"slow","arguments":{"type":"object","properties":{"f":{"type":"string"}},"required":["f"]},"command":["/bin/sh","-c","sleep 30 & echo $! > \"$1\"; wait","_","{f}"]}]}"#
            .write(to: tools, atomically: true, encoding: .utf8)
        #expect(try afm(["ask", "x", "--session", "s"], stdin: "one", tmp: dir).code == 0)
        let before = try Data(contentsOf: dir.appendingPathComponent("sessions/s.json"))
        let call = ["name": "slow", "arguments": "{\"f\":\"\(pidFile)\"}"]
        let (p, _, _) = try start(["ask", "go", "--session", "s", "--tools-file", tools.path, "--tool-timeout", "60"],
                                  fake: ["respond": ["toolCalls": [call]]], dir: dir)
        waitFor { FileManager.default.fileExists(atPath: pidFile) && ((try? String(contentsOfFile: pidFile, encoding: .utf8)) ?? "").hasSuffix("\n") }
        let child = pid_t(try String(contentsOfFile: pidFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines))!
        p.terminate()
        p.waitUntilExit()
        #expect(p.terminationStatus == 1)
        waitFor { kill(child, 0) != 0 }
        #expect(kill(child, 0) != 0)
        #expect(try Data(contentsOf: dir.appendingPathComponent("sessions/s.json")) == before)
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift build && swift test --filter SignalCLITests`
Expected: FAIL; the default SIGTERM action gives termination status 15, not 1, and the tool's `sleep` survives.

- [ ] **Step 3: Implement**

`Sources/AFMuxCore/Signals.swift`:

```swift
import Darwin
import Foundation

public enum Signals {
    nonisolated(unsafe) private static var sources: [DispatchSourceSignal] = []

    /// SIGINT, SIGTERM, SIGHUP: kill tool process groups, remove temp files, exit 1.
    /// The session lock is released by process exit and the session file is only ever renamed into place.
    public static func install() {
        for sig in [SIGINT, SIGTERM, SIGHUP] {
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .global())
            source.setEventHandler {
                ProcessGroups.shared.killAll()
                TempFiles.shared.removeAll()
                FileHandle.standardError.write(Data("afm: interrupted by signal \(sig)\n".utf8))
                _exit(1)
            }
            source.resume()
            sources.append(source)
        }
    }
}
```

In `Sources/afm/main.swift`, add as the first statement after the imports:

```swift
Signals.install()
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `swift build && swift test`
Expected: all pass.

- [ ] **Step 5: Commit**

```bash
git add Sources Tests/CLITests/SignalCLITests.swift
git commit -m "Handle signals: kill tool process groups, exit 1"
```

---

### Task 14: Integration tests and README

**Files:**
- Create: `Tests/IntegrationTests/RealModelTests.swift`
- Modify: `Package.swift` (add IntegrationTests target), `README.md` (replace)

**Interfaces:**
- Consumes: the built binary with the real backend.

- [ ] **Step 1: Add the target and the tests**

In `Package.swift` add:

```swift
        .testTarget(name: "IntegrationTests", dependencies: ["afm"], swiftSettings: v5),
```

`Tests/IntegrationTests/RealModelTests.swift`:

```swift
import Foundation
import Testing

private let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
private let binary = root.appendingPathComponent(".build/debug/afm").path

private func run(_ args: [String], stdin: String = "", cwd: URL? = nil, sessions: URL? = nil) throws -> (Int32, String, String) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: binary)
    p.arguments = args
    var e = ProcessInfo.processInfo.environment
    e.removeValue(forKey: "AFMUX_FAKE")
    if let sessions { e["AFMUX_SESSIONS_DIR"] = sessions.path }
    p.environment = e
    if let cwd { p.currentDirectoryURL = cwd }
    let out = Pipe(), err = Pipe(), input = Pipe()
    p.standardOutput = out
    p.standardError = err
    p.standardInput = input
    try p.run()
    input.fileHandleForWriting.write(Data(stdin.utf8))
    try input.fileHandleForWriting.close()
    let o = out.fileHandleForReading.readDataToEndOfFile(), r = err.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return (p.terminationStatus, String(decoding: o, as: UTF8.self), String(decoding: r, as: UTF8.self))
}

private let realModelWorks: Bool = {
    guard FileManager.default.isExecutableFile(atPath: binary) else { return false }
    return (try? run(["ask", "Reply with one word."], stdin: "hi").0) == 0
}()

private func tmp() -> URL {
    let u = FileManager.default.temporaryDirectory.appendingPathComponent("afm-int-" + UUID().uuidString)
    try! FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
    return u
}

@Suite(.enabled(if: realModelWorks, "on-device model not usable here"), .serialized)
struct RealModelTests {
    @Test func classifyReal() throws {
        let (code, out, err) = try run(["classify", "--labels", "positive,negative"], stdin: "I absolutely loved this film.")
        #expect(code == 0, "\(err)")
        let obj = try JSONSerialization.jsonObject(with: Data(out.utf8)) as! [String: Any]
        #expect(["positive", "negative"].contains(obj["label"] as! String))
    }

    @Test func extractWithFmFormatSchema() throws {
        let dir = tmp()
        let schema = dir.appendingPathComponent("s.json")
        try #"{"title":"Counts","type":"object","properties":{"errors":{"type":"integer"}},"required":["errors"],"x-order":["errors"],"additionalProperties":false}"#
            .write(to: schema, atomically: true, encoding: .utf8)
        let (code, out, err) = try run(["extract", "--schema", schema.path], stdin: "The build finished with 3 errors and 2 warnings.")
        #expect(code == 0, "\(err)")
        #expect(out == "{\"errors\":3}\n")
    }

    @Test func twoTurnSession() throws {
        let sessions = tmp()
        #expect(try run(["ask", "Remember the facts you are given.", "--session", "it"], stdin: "The project codename is BLUEHERON.", sessions: sessions).0 == 0)
        let (code, out, err) = try run(["ask", "What is the project codename? Reply with the codename only.", "--session", "it"], sessions: sessions)
        #expect(code == 0, "\(err)")
        #expect(out.uppercased().contains("BLUEHERON"))
    }

    @Test func toolsFindAString() throws {
        let dir = tmp()
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("docs"), withIntermediateDirectories: true)
        try "nothing here\n".write(to: dir.appendingPathComponent("docs/a.txt"), atomically: true, encoding: .utf8)
        try "the magic token is ZEBRA-42\n".write(to: dir.appendingPathComponent("docs/notes.txt"), atomically: true, encoding: .utf8)
        let (code, out, err) = try run(["ask", "--tools", "fs", "Which file under docs contains the text ZEBRA-42? Reply with the file name only."], cwd: dir)
        #expect(code == 0, "\(err)")
        #expect(out.contains("notes.txt"))
    }
}
```

- [ ] **Step 2: Run them (outside any agent sandbox)**

Run: `swift build && swift test --filter IntegrationTests`
Expected: 4 passing tests on a Mac with the model enabled; the suite is skipped elsewhere. A failure here is real-model behaviour: read the stderr in the failure message before changing anything.

- [ ] **Step 3: Write the README**

Replace `README.md` with sections, in this order:

1. Title and one paragraph: a Swift `afm` that is a drop-in engine for the afmux skill, calling FoundationModels in-process; what it adds (in-process token counts, native schemas, tools, sessions).
2. Requirements: macOS 27 on Apple silicon with the model enabled; Command Line Tools (Swift 6.4).
3. Install: the three commands from the spec's Installation section; "replaces afmux's Python `afm`; install the afmux skill as its README describes; point the symlink back at `afmux/scripts/afm` to revert".
4. What is the same: link to afmux's SKILL.md for presets, options and exit codes; list the accepted differences from the spec, verbatim.
5. Tools: `--tools fs` (the three tools and their arguments), `--tools-file` with the JSON example from the spec, the limits and their flags, the "context nearly full" behaviour.
6. Sessions: the two-turn example from the spec, the turn rules, where files live, compaction and its stderr line, `afm sessions`, `afm sessions rm NAME`.
7. Sandbox: in-process calls are expected to fail inside an agent sandbox with ModelManager error 1008 (exit 5), as with `fm`; a manual check: run `echo hi | afm summarise` inside a sandboxed agent shell and confirm exit 5 and `fm is blocked by a sandbox; run afm outside it`.
8. Development: `swift build && swift test`; the fake backend (`AFMUX_FAKE`, `AFMUX_SESSIONS_DIR`) is for tests only; integration tests run only where the model answers.
9. Licence: MIT, see `LICENSE`.

- [ ] **Step 4: Run the whole suite**

Run: `swift build && swift test`
Expected: all unit and CLI tests pass; integration tests pass or are skipped.

- [ ] **Step 5: Commit**

```bash
git add Package.swift Tests/IntegrationTests README.md
git commit -m "Add real-model integration tests and README"
```

---

## Execution notes (2026-10-22)

Where the code departs from the blocks above:

- `Package.swift`: test targets use `testSettings`, which adds `-plugin-path` for the Command Line Tools' Swift Testing plugin directory when it exists. Without it the build system intermittently left `libTestingMacros` out of test compiles. Builds and tests run outside the agent sandbox, which blocks the macro plugin entirely.
- `Args.swift`: leftovers are reported in argv order (unknown options and extra positionals interleaved), which is what argparse does; the plan's version listed unknown options first.
- `App.swift`, `SessionTurn.swift`: `Optional.map` cannot take an async closure; the schema count is an `if let`.
- `SchemaTests.converterProblems`: `{"type":"string"}` decodes as an fm-format `GenerationSchema`, so the top-level rule is tested on `SchemaLoader.convert` directly.
- Session and compaction CLI tests read the last respond records: every turn of a test shares one log file.

### After the PR #1 code review

- `Proc.swift` rewritten: one thread polls both pipes against the tool deadline and stops reading 0.5 s after the child exits (descendants that leave the group no longer hang afm); `withTaskCancellationHandler` kills the group when the model call is cancelled, so `--timeout` cuts off a running tool; spawn resets INT/TERM/HUP to default, clears the signal mask inherited from the GCD thread, and passes only fds 0-2 (`POSIX_SPAWN_CLOEXEC_DEFAULT`); spawning and registration happen under the lock `killAll()` takes, closing the signal window.
- Session lock fd is `O_CLOEXEC`; `afm sessions rm` deletes under the lock and keeps the lock file.
- `ToolContext.fit` cuts a single over-long line by characters instead of returning only the marker.
- `-h` returns help as soon as it is reached, as argparse does.
- New tests in `Tests/CLITests/PRReviewTests.swift` for each finding, plus concurrent turns, lock release after a signal, stale tool definitions and the compaction second fold.
