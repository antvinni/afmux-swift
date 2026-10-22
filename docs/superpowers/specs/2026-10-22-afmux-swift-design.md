# afmux-swift design

Date: 2026-10-22. Status: approved in brainstorming, awaiting spec review.

## Purpose

afmux-swift is a Swift reimplementation of afmux's `afm` command that calls
the FoundationModels framework in-process instead of spawning Apple's `fm`
CLI. It is a **drop-in engine**: same commands, presets, options, output and
exit codes, so the afmux skill (SKILL.md, standing rule, sandbox settings,
nudge hook) works unchanged with this binary on `PATH` in place of the
Python script.

On top of that contract it adds what the framework makes possible and `fm`
does not:

- in-process token counting for instructions, prompt, schema, tools and
  transcript entries, with no extra process per count;
- native structured output through `DynamicGenerationSchema`;
- real tool calling, built-in and caller-defined;
- sessions whose transcript persists across calls, with automatic
  compaction when it outgrows the context.

The goal is the same as afmux's: move as much bounded work as possible off
the paid agent model onto the free on-device model. Every choice below is
made for delegation capability and agent-token efficiency. Tools are not
confined or restricted beyond what the framework itself does.

## Architecture

Approach A: a one-shot executable with state on disk. A SwiftPM package with
two targets:

```
afmux-swift/
  Package.swift
  Sources/
    AFMuxCore/        all logic: CLI parsing, presets, budget, chunking,
                      schema conversion, tools, sessions, compaction,
                      error mapping
      Resources/presets/  summarise.md classify.md extract.md commit-msg.md
    afm/              thin executable: main() calls AFMuxCore and exits
  Tests/
    AFMuxCoreTests/   unit tests against FakeModel
    CLITests/         subprocess tests of the built binary under the fake model
    IntegrationTests/ real-model tests, skipped when the model is unavailable
  README.md
  LICENSE
```

Each call is a fresh process. The model is hosted by the system model
service, so per-process cost should be small; the Step 0 spike measures it.

Deferred, not rejected: **approach B**, an optional resident `afm serve`
holding sessions in memory and calling `prewarm()`. Revisit only if the
spike or real use shows per-process start-up or transcript reload is too
slow. AFMuxCore's structure does not preclude it.

Preset texts are copied from afmux into package resources, so the binary
does not depend on the afmux checkout's location.

## CLI contract

### Unchanged from afmux

- Command shapes: `afm <preset> [opts] < input`,
  `afm ask "<instructions>" [opts] < input`, `afm --list`.
- Presets `summarise`, `classify`, `extract`, `commit-msg`, with afmux's
  instruction texts.
- Options `--labels`, `--schema`, `--guardrails` (default
  `permissive-content-transformations`), `--use-case` (default `general`),
  `--timeout` (default 120, counts from process start), `--budget` (default
  7168), `--chunk`, `--max-chunks` (default 8), with afmux's validation
  rules.
- Output: only the answer on stdout; compact one-line JSON when a schema is
  used; JSON lines or `[i/n]` headers under `--chunk`.
- Exit codes 0 to 6 with afmux's meanings (see Error handling).
- Greedy decoding, no streaming output, no retries except the single
  compaction retry described under Sessions.

### New options

| Option | Meaning | Default |
|---|---|---|
| `--tools fs` | enable the built-in filesystem tools | off |
| `--tools-file FILE` | add caller-defined tools; combinable with `--tools fs` | none |
| `--max-tool-calls N` | exceeding it is exit 1 | 16 |
| `--tool-output-budget TOKENS` | cap on each tool result | 1500 |
| `--tool-timeout SECONDS` | per tool call | 30 |
| `--trace` | one stderr line per tool call | off |
| `--session NAME` | load, run a turn, compact if needed, save | none |

Subcommands: `afm sessions` lists sessions (name, turns, tokens, last
modified); `afm sessions rm NAME` deletes one.

Tools are off by default because their definitions consume part of the
8192-token context.

### Input rules

As in afmux, stdin must be non-empty and not a terminal, except when
`--session` names an existing session or any tools are enabled; then stdin
may be empty or a terminal and is ignored if so. This allows
`afm ask --tools fs "which file defines parseConfig?"` with no pipe.

New usage errors (exit 2): `--chunk` with `--session`; `--chunk` with any
tools.

## Sessions and compaction

### Turns

- The first call with `--session NAME` creates the session. The preset text
  (with `{labels}` substituted) or the `ask` text becomes the transcript's
  instructions; stdin is the first prompt. Identical to a sessionless call.
- Later calls: the `ask` text or preset text, followed by a blank line and
  stdin if present, is the turn's prompt. Instructions are unchanged.
- Per turn: `--schema`, `--labels` and tools may differ, since each call
  builds a fresh `LanguageModelSession(model:tools:transcript:)`.
- Fixed at creation: guardrails and use-case. A later call passing a
  different explicit value is exit 2.

### Storage

- `~/Library/Application Support/afmux/sessions/NAME.json`, containing
  `{"version": 1, "guardrails": ..., "useCase": ..., "transcript": ...}`
  where `transcript` is the framework's `Codable` encoding of `Transcript`.
- Names match `[A-Za-z0-9._-]+`, else exit 2.
- Saved only when the turn exits 0, by writing a temporary file in the same
  directory and renaming it. A failed turn leaves the file unchanged.
- Concurrent calls on one session serialise on an exclusive `flock` of
  `NAME.lock`. Waiting counts against `--timeout`.
- No expiry, rename, fork or export in v1.

### Compaction

Before each turn, afm counts transcript entries + new prompt + tools +
schema. If the sum exceeds `--budget`:

1. Keep the instructions entry and the most recent complete turn (prompt,
   any tool calls and outputs, response) verbatim.
2. Render the entries in between as plain text and summarise them with a
   separate one-shot call under fixed instructions: keep facts, names,
   numbers, file paths and decisions; drop pleasantries. If that text is
   over budget, summarise it in pieces with the `--chunk` splitter and join
   the piece summaries.
3. Replace the middle with one synthetic entry pair: a prompt
   `Summary of earlier conversation:\n<summary>` and a response `OK`.
4. If still over budget, fold the kept turn into the summary as well and
   recount. If the new prompt alone (with instructions, tools and schema)
   is over budget, exit 6 as without a session.

If generation itself throws `contextSizeExceeded` (tool output can grow the
transcript mid-turn), afm compacts the transcript as it stood before the
turn and retries the turn once. A second overflow is exit 1. This is the
only retry in the design; it is justified because the retried input is
smaller, whereas greedy decoding reproduces any other failure exactly.

Each compaction writes one stderr line:
`afm: session NAME compacted (7400 → 2100 tokens)`. Compaction is lossy and
the agent should know it happened.

## Tools

### Built-in (`--tools fs`)

Relative paths resolve against afm's working directory. No confinement.

| Tool | Arguments | Returns |
|---|---|---|
| `read_file` | `path`, optional `start_line`, `end_line` (1-based, inclusive) | numbered lines |
| `grep` | `pattern` (extended regex), `path`, optional `glob` | `file:line:text` lines from `/usr/bin/grep -rnIE`, skipping `.git` |
| `list_dir` | `path`, optional `depth` (default 1) | entries, directories suffixed `/` |

Errors (missing file, bad regex) are returned to the model as the tool's
output, not raised.

### Caller-defined (`--tools-file FILE`)

```json
{"tools": [{
  "name": "run_tests",
  "description": "Run pytest on one path and return its output",
  "arguments": {"type": "object",
                "properties": {"path": {"type": "string", "description": "test file or dir"}},
                "required": ["path"]},
  "command": ["pytest", "-q", "{path}"]
}]}
```

- `name` matches `[a-z][a-z0-9_]*` and must not collide with a built-in
  name; `description` and `command` (non-empty array of strings) are
  required; `arguments` is a JSON Schema object (see Schemas). Violations
  are exit 2 naming the tool and field.
- `command` is an argv array. `{name}` inside any element is replaced by
  the argument's value (numbers and booleans in their JSON text form,
  arrays as JSON). A missing optional argument becomes the empty string.
  There is no shell unless the caller asks for one, e.g.
  `["sh", "-c", "pytest -q \"$1\" | tail -50", "_", "{path}"]`.
- Runs with afm's working directory and environment, stdin `/dev/null`.
- The model receives `exit N`, then stdout, then stderr, each labelled.

### Limits (context efficiency, not safety)

- Each tool result is capped at `--tool-output-budget` tokens, cut at a
  line boundary, ending with a marker telling the model how to get the
  rest, e.g. `[truncated: 840 more lines; call read_file with
  start_line=161]` (command tools: `[truncated: N more lines]`).
- `--tool-timeout` per call; on expiry the process is killed and the model
  receives `timed out after N s`.
- Everything runs inside the overall `--timeout`.
- More than `--max-tool-calls` calls in one turn is exit 1.
- Tool definitions are counted with `tokenCount(for: tools)` in the
  pre-call budget check.
- In sessions, tool calls and outputs are transcript entries, saved and
  compacted like everything else.

`--trace` prints, per call: `afm: tool NAME(args, abbreviated to 80 chars)
→ exit N, M tokens`.

## Schemas

One converter, used for `--schema`, tool `arguments` and the generated
`classify` schema, turns JSON Schema into `DynamicGenerationSchema` and
then `GenerationSchema`.

- Supported: `type` of `object`, `string`, `number`, `integer`, `boolean`,
  `array` (with `minItems`, `maxItems`, `items`); `enum` of strings;
  `description`; `required`; `properties`; `title` (used as the schema
  name, default `Output`). `additionalProperties` and `x-order` are
  accepted. Any other keyword is exit 2 naming it.
- Property order: `x-order` when present, so afmux's schema files work;
  otherwise `required` order followed by remaining properties
  alphabetically, because Foundation's JSON parsing does not preserve key
  order.
- `classify` builds `{label: enum(--labels)}` through the same converter.
  The output label is still checked against `--labels` (exit 3 on
  mismatch).
- Schema output is serialised from `GeneratedContent` to compact JSON in
  property order.

## Error handling

All errors pass through one mapping function.

| Source | Exit |
|---|---|
| usage: bad flags, unsupported schema keyword, bad tools file, bad session name, conflicting guardrails or use-case on a later turn, `--chunk` with session or tools, stdin rules | 2 |
| `guardrailViolation`, `refusal`, framework `timeout`, our `--timeout`, a signal, tool-call cap, overflow after the compaction retry, any other generation error | 1 |
| schema output not valid JSON, label not in `--labels` | 3 |
| `availability` is `.unavailable(_)`, `assetsUnavailable` | 4 |
| ModelManager error 1008 (agent sandbox), matched by error domain and code, on any framework call including token counting | 5 |
| over budget before the call; `--chunk` over `--max-chunks`; a single line over budget | 6 |

- On non-zero exit nothing is printed on stdout; the reason is one line on
  stderr (framework messages passed through).
- SIGINT, SIGTERM and SIGHUP cancel the generation task and any running
  tool process, release the session lock, remove temporary files and exit
  1 without saving the session.
- Availability is checked only after a generation failure, as afmux does,
  so the success path does no extra work.

## Testing

Swift Testing, `swift test`. No model needed except for the integration
target.

- **FakeModel** implements the SDK's public `LanguageModel` protocol and
  plays a script: per call, return text or `GeneratedContent`, emit tool
  calls with given arguments, throw a given error, report given token
  counts. All AFMuxCore logic is tested against it: budget checks,
  chunking, schema conversion, the tool loop and cap, truncation markers,
  compaction trigger, summary entry, single overflow retry, error mapping.
- **CLI tests**: a hidden environment variable `AFMUX_FAKE_MODEL=<script
  json>` makes the binary use FakeModel. Tests run the built `afm` as a
  subprocess and assert stdout, stderr and exit code. afmux's
  `tests/test_afm.py` cases are ported here; passing them is the drop-in
  claim.
- **Tools**: built-ins against a temporary directory tree; command tools
  for substitution, missing optional argument, non-zero exit, timeout,
  truncation and marker text; tools-file validation errors.
- **Sessions**: round-trip; file unchanged after a failed turn; two
  concurrent writers serialise under the lock; compaction output shape;
  guardrails conflict is exit 2.
- **Signals**: SIGTERM during a fake generation and during a running tool
  process; assert exit 1, child gone, lock released, session unchanged.
- **Integration** (skipped unless the model answers a one-word prompt):
  `classify` returns a valid label; a two-turn session answers a follow-up
  that needs turn one; `--tools fs` finds a known string in a fixture tree.

## Installation

Requirements: macOS 27 or later on Apple silicon with the on-device model
enabled; Xcode Command Line Tools (Swift 6.4).

```bash
git clone https://github.com/antvinni/afmux-swift ~/src/afmux-swift
cd ~/src/afmux-swift && swift build -c release
ln -sf "$PWD/.build/release/afm" ~/.local/bin/afm
```

This replaces afmux's Python `afm` on `PATH`. Install the afmux skill as
its README describes; nothing in it changes. Removing the symlink (or
pointing it back at `afmux/scripts/afm`) reverts to Python.

## Step 0: spike before implementation

Throwaway code, results recorded in the plan. Each assumption below the
design depends on; if one fails, stop and revise the spec with the user.

1. A command-line binary built with SwiftPM can use FoundationModels with
   no special entitlements; measure process start to first token for a
   one-word prompt, cold and warm. (Decides whether approach B is needed.)
2. Inside the Claude Code sandbox the in-process framework fails with
   ModelManager error 1008, and record its domain and code.
3. `LanguageModel` (and its executor) can be implemented outside Apple's
   code for FakeModel, including tool calls.
4. Synthetic `Transcript` entries (prompt and response) can be constructed,
   encoded, decoded and resumed by a new session.
5. A `DynamicGenerationSchema` string `enum` constrains output, and Swift
   Testing runs under the Command Line Tools without Xcode.

## Non-goals (v1)

- Resident server (approach B), Private Cloud Compute, image input,
  streaming output.
- Any change to afmux's SKILL.md or its other files.
- Session expiry, rename, fork or export.
- Retries other than the single compaction retry.
