# afmux-swift design

Date: 2026-10-22. Status: revised after one external review, awaiting
second review.

## Purpose

afmux-swift is a Swift reimplementation of afmux's `afm` command that calls
the FoundationModels framework in-process instead of spawning Apple's `fm`
CLI. It is a **drop-in engine**: same commands, presets, options, output and
exit codes, so the afmux skill (SKILL.md, standing rule, sandbox settings,
nudge hook) works unchanged with this binary on `PATH` in place of the
Python script. Known, accepted differences are listed under Compatibility.

On top of that contract it adds what the framework makes possible and `fm`
does not:

- in-process token counting for instructions, prompt, schema, tools and
  transcript entries, with no extra process per count;
- native structured output, from `fm`-format schema files or plain JSON
  Schema;
- real tool calling, built-in and caller-defined;
- sessions whose transcript persists across calls, with automatic
  compaction when it outgrows the context.

The goal is the same as afmux's: move as much bounded work as possible off
the paid agent model onto the free on-device model. Every choice below is
made for delegation capability and agent-token efficiency. Tools are not
confined or restricted beyond what the framework itself does; the only
limits are there to keep work inside the 8192-token context.

## Architecture

Approach A: a one-shot executable with state on disk. A SwiftPM package
with no third-party dependencies and two targets:

```
afmux-swift/
  Package.swift
  presets/              summarise.md classify.md extract.md commit-msg.md
                        (copied from afmux; the source of truth for texts)
  Sources/
    AFMuxCore/          all logic
      Presets.swift     the preset texts as string constants
      ...
    afm/                thin executable: main() calls AFMuxCore and exits
  Tests/
    AFMuxCoreTests/     unit tests against FakeModel and FakeTokenCounter
    CLITests/           subprocess tests of the built binary in fake mode
    IntegrationTests/   real-model tests, skipped when the model is unavailable
  README.md
  LICENSE
```

Preset texts live in `Presets.swift` as constants, not as bundle resources:
`Bundle.module` in a symlinked command-line tool resolves to a build path
baked into the binary and breaks when the checkout moves. A unit test reads
`presets/*.md` from the source tree (via `#filePath`) and asserts the
constants match, so the files stay the editable source and the binary has
no file dependency.

Each call is a fresh process. The model is hosted by the system model
service, so per-process cost should be small; Step 0 measures it.

Deferred, not rejected: **approach B**, an optional resident `afm serve`
holding sessions in memory and calling `prewarm()`. Revisit only if Step 0
or real use shows per-process start-up or transcript reload is too slow.

### Seams for testing

Two protocols in AFMuxCore isolate the framework:

- **`TokenCounter`**: `count(instructions:)`, `count(prompt:)`,
  `count(schema:)`, `count(tools:)`, `count(entries:)`, and `contextSize`.
  `SystemTokenCounter` calls `SystemLanguageModel.tokenCount(for:)` (these
  overloads exist only on `SystemLanguageModel`, not on the `LanguageModel`
  protocol). `FakeTokenCounter` returns deterministic counts (UTF-8 bytes
  divided by 4, rounded up, unless a test script overrides a value). Every
  count in the program, including tool-output truncation and compaction,
  goes through this protocol.
- **`LanguageModel`**: the SDK's public protocol. Production uses
  `SystemLanguageModel(useCase:guardrails:)`; tests use `FakeModel`, which
  implements `LanguageModel` and its executor and plays a script per call:
  return text or structured content, emit tool calls with given arguments,
  throw a given error, or sleep.

A hidden environment variable `AFMUX_FAKE=<script.json>` makes the binary
use both fakes, for the CLI tests.

## CLI contract

### Unchanged from afmux

- Command shapes: `afm <preset> [opts] < input`,
  `afm ask "<instructions>" [opts] < input`, `afm --list`.
- Presets `summarise`, `classify`, `extract`, `commit-msg`, with afmux's
  instruction texts. `--list` prints one line per preset, sorted by name,
  formatted as afmux's `"%-12s %s" % (name, first_line)`.
- Options `--labels`, `--schema`, `--guardrails` (default
  `permissive-content-transformations`), `--use-case` (default `general`),
  `--timeout` (default 120), `--budget` (default 7168), `--chunk`,
  `--max-chunks` (default 8), with afmux's validation rules and messages.
- `--timeout` applies to **each model call** separately, as in afmux: each
  `respond`, each chunk, each compaction summary call. Tool calls run
  inside the model call that issued them and count against its timeout.
- Output: only the answer on stdout; text answers with trailing whitespace
  stripped; compact one-line JSON when a schema is used; JSON lines or
  `[i/n]` headers under `--chunk` (format used even for one piece).
- Exit codes 0 to 6 with afmux's meanings (see Error handling).
- Greedy decoding (`GenerationOptions(sampling: .greedy)`), no streaming
  output, no retries.

### Argument parsing

A small hand-written parser, so exit codes and messages are exact:

- Accepted: `--opt value`, `--opt=value`, options before or after the
  positionals, `--` ending options, `-h`/`--help` (prints the usage line
  and an option list in afm's own format, exit 0).
- Not accepted: option prefix abbreviations (`--sch` for `--schema`), which
  Python's argparse allows. The SKILL.md uses full names.
- Parser errors print `afm: <message>` followed by a second line with the
  usage string, exactly as afmux does; exit 2. The messages reproduce
  argparse's texts for the cases afm can hit:
  - `argument --budget: invalid int value: 'x'` (also `--max-chunks`,
    `--max-tool-calls`, `--tool-output-budget`)
  - `argument --timeout: invalid float value: 'x'` (also `--tool-timeout`)
  - `argument --schema: expected one argument` (any option missing its
    value)
  - `unrecognized arguments: a b` (unknown options and extra positionals,
    space separated, in order)
  - `argument --chunk: ignored explicit argument 'yes'` (a value given with
    `=` to `--chunk` or `--list`; the option is named as written here)
- `--guardrails` accepts `default` and `permissive-content-transformations`
  (mapped to `.default` and `.permissiveContentTransformations`).
  `--use-case` accepts `general` and `content-tagging`. Any other value is
  exit 2 (afmux passed it through and `fm` failed with exit 1).

### New options

| Option | Meaning | Default |
|---|---|---|
| `--tools fs` | enable the built-in filesystem tools | off |
| `--tools-file FILE` | add caller-defined tools; combinable with `--tools fs` | none |
| `--max-tool-calls N` | more calls in one model call is exit 1 | 8 |
| `--tool-output-budget TOKENS` | cap on each tool result | 600 |
| `--tool-timeout SECONDS` | per tool call | 30 |
| `--session NAME` | load, compact if needed, run a turn, save | none |

Subcommands: `afm sessions` prints one line per session,
`name<TAB>turns<TAB>tokens<TAB>modified` (ISO 8601), from data stored in
the session file, so it needs no model. `afm sessions rm NAME` deletes one
(exit 2 if it does not exist).

Tools are off by default because their definitions consume part of the
context.

### Input rules

- As in afmux: stdin must not be a terminal and must not be empty or
  whitespace only.
- Exceptions: when `--session` names an existing `ask` session, or any
  tools are enabled on an `ask` call, stdin may be a terminal or empty; it
  is then treated as absent and not read if a terminal. Preset calls always
  need stdin, with or without a session.
- New usage errors (exit 2): `--chunk` with `--session`; `--chunk` with any
  tools.

### Instructions and prompt for each call shape

| Call | Instructions | Prompt |
|---|---|---|
| preset, stdin present | preset text (`{labels}` substituted) | stdin |
| `ask "T"`, stdin present | `T` | stdin |
| `ask "T"`, stdin absent, tools on (no session, or creating one) | the fixed tool-use text below | `T` |
| preset, stdin absent, tools on | exit 2 (`input is empty`) | |

Fixed tool-use text: `Answer the request. Use the tools to find the
information you need. Reply with only the answer.`

### Budget

One rule for every call, with or without a session or tools:

**pre-call total** = instructions + tool definitions + prior transcript
entries (sessions only) + prompt + schema.

Tool definitions are counted with `tokenCount(for: tools)` unless Step 0
shows that `tokenCount(for: transcriptEntries)` already includes the
instructions entry's `toolDefinitions`, in which case they are counted
there and not again. Either way they are counted exactly once. If the
pre-call total exceeds `--budget`, the call does not start (exit 6, or
compaction in a session, or splitting under `--chunk`).

## Sessions and compaction

### Creation and turns

- The first call with `--session NAME` creates the session, using the table
  above for its instructions and first prompt. The session stores its
  **job** (preset name, or `ask`), its `--labels` if any, guardrails and
  use-case.
- Later calls must use the same job. A different preset, or `ask` on a
  preset session, is exit 2 (`session NAME is a <job> session`).
- Later turn prompts:
  - preset session: stdin (required; `input is empty` otherwise).
  - `ask` session: the `ask` text, followed by a blank line and stdin if
    present.
  The instructions entry is not repeated.
- `--labels`, `--guardrails`, `--use-case`: fixed at creation. Passing a
  different explicit value on a later call is exit 2; passing the same
  value or omitting it is fine. The stored values are filled in before
  afmux's usage validation runs, so a later `classify` turn without
  `--labels` does not hit `classify needs --labels a,b,c`.
- Per turn: `--schema` and tools may differ. Each call builds a fresh
  `LanguageModelSession(model:tools:transcript:)`. Before building it, afm
  rewrites the stored instructions entry's tool definitions to the current
  call's tools, so the transcript never carries stale definitions and tools
  are counted once, as part of the transcript entries.

### Storage

- `~/Library/Application Support/afmux/sessions/NAME.json`, containing
  `{"version": 1, "job": ..., "labels": ..., "guardrails": ..., "useCase":
  ..., "turns": N, "tokens": N, "transcript": ...}` where `transcript` is
  the framework's `Codable` encoding of `Transcript` and `tokens` is the
  transcript's count at last save.
- Names match `[A-Za-z0-9._-]+`, else exit 2.
- Saved only when the turn exits 0, by writing a temporary file in the same
  directory and renaming it. A failed turn leaves the file unchanged.
- Concurrent calls on one session serialise on an exclusive `flock` of
  `NAME.lock`, taken with `LOCK_EX | LOCK_NB` and retried every 50 ms until
  `--timeout` has passed; then exit 1 with `session NAME is busy`.
- No expiry, rename, fork or export in v1.

### Compaction

Before each turn, afm computes the pre-call total (see Budget) for the
stored transcript plus the new prompt. If it exceeds `--budget`:

1. Keep the instructions entry and the most recent complete turn (prompt,
   tool calls and outputs, response) verbatim.
2. Render the entries in between as plain text, labelled by role, and
   summarise them with a separate one-shot call under fixed instructions:
   `Summarise this conversation for later reference. Keep facts, names,
   numbers, file paths and decisions. Omit pleasantries.` The call uses the
   session's guardrails and use-case, greedy decoding,
   `maximumResponseTokens` of one third of `--budget`, and its own
   `--timeout`. If the rendered text is over budget, it is split with the
   `--chunk` splitter and each piece summarised in turn, at most
   `--max-chunks` pieces, and the piece summaries are joined.
3. Replace the middle with one synthetic pair: a prompt entry
   `Summary of earlier conversation:\n<summary>` and a response entry `OK`.
4. If still over budget, fold the kept turn into the middle and repeat steps
   2 and 3 once. If still over budget after that, or if the new prompt alone
   (with instructions and schema) is over budget, exit 6 with `input is N
   tokens, budget is M` (no `--chunk` hint, since it is not allowed with
   sessions).

Failure handling: more than `--max-chunks` pieces is exit 6 with `session
NAME is too large to compact`; a failed summary call exits with that call's
code and the message prefixed `compaction: `. The session file is unchanged
in both cases.

Each successful compaction writes one stderr line:
`afm: session NAME compacted (7400 → 2100 tokens)`. Compaction is lossy and
the agent should know it happened.

## Tools

### Built-in (`--tools fs`)

Relative paths resolve against afm's working directory. No confinement.

| Tool | Arguments | Returns |
|---|---|---|
| `read_file` | `path`, optional `start_line`, `end_line` (1-based, inclusive) | numbered lines |
| `grep` | `pattern` (extended regex), `path`, optional `glob` | `file:line:text` lines from `/usr/bin/grep -rnIE`, skipping `.git` |
| `list_dir` | `path` | direct entries, directories suffixed `/` |

Errors (missing file, bad regex) are returned to the model as the tool's
output.

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

- `name` matches `[a-z][a-z0-9_]*` and must not collide with a built-in or
  another tool; `description` and `command` (non-empty array of strings)
  are required; `arguments` is a schema loaded as under Schemas.
  Violations are exit 2 naming the tool and field.
- `command` is an argv array. `{name}` inside any element is replaced by
  the argument's value: strings as is, numbers and booleans in the JSON
  output form under Schemas, arrays and objects as compact JSON. A missing
  optional argument becomes the empty string. No shell unless the caller
  asks for one, e.g.
  `["sh", "-c", "pytest -q \"$1\" | tail -50", "_", "{path}"]`.
- Each command runs in its own process group with afm's working directory
  and environment and stdin `/dev/null`. On tool timeout or afm signal the
  whole group is killed, so `sh -c` grandchildren do not survive.
- The model receives `exit N`, then `stdout:` and its text, then `stderr:`
  and its text.

Each tool is a type conforming to `Tool` with `Arguments = GeneratedContent`
and a `parameters` property returning the runtime-built `GenerationSchema`.

### Limits (context, not safety)

Within one model call afm keeps a running count: the pre-call total (see
Budget) plus, for every tool call so far, the tokens of its arguments
(counted as a prompt of their compact JSON) and of its returned result,
against `contextSize` minus a 1024-token output reserve.

- Each result is first capped at `--tool-output-budget` tokens, then at
  whatever room remains. Cuts are at a line boundary and end with a marker:
  `[truncated: N more lines; call read_file with start_line=K]` for
  `read_file`, `[truncated: N more lines]` otherwise.
- When less than 100 tokens of room remain, the tool returns
  `Context nearly full. Answer now with what you have.` instead of running.
- The tool-call cap is a counter checked inside each tool's `call`; the
  call after the cap throws `ToolCapExceeded`, which ends the model call
  with exit 1 and `more than N tool calls`. (The framework's
  `ToolCallingMode` has no count limit.) The framework delivers errors
  thrown from `Tool.call` wrapped in `ToolCallError`; the error mapper
  unwraps `underlyingError` first and maps that.
- `--tool-timeout` per tool call; on expiry the group is killed and the
  model receives `timed out after N s`.
- If generation still throws `contextSizeExceeded`, exit 1 with
  `context exceeded during tool calls`. No retry.
- In sessions, tool calls and outputs are transcript entries, saved and
  compacted like everything else.

## Schemas

One loader, used for `--schema` and tool `arguments`:

1. Decode the JSON with `JSONDecoder` into `GenerationSchema`. This is the
   format `fm` uses, so every schema file that worked with afmux works
   unchanged, including `anyOf` and `$defs` references if `fm` accepted
   them.
2. If decoding fails, convert it as plain JSON Schema into
   `DynamicGenerationSchema` and build a `GenerationSchema` from that.
   Supported: `type` of `object`, `string`, `number`, `integer`, `boolean`,
   `array` (with `items`, `minItems`, `maxItems`); `enum` of strings;
   `description`; `required`; `properties`; `title` (schema name, default
   `Output`); `additionalProperties` and `x-order` accepted. Property order:
   `x-order` if present, else `required` order then the rest alphabetically.
3. If both fail, exit 2 with the converter's message naming the first
   unsupported keyword or problem.

`classify` builds `{label: enum(--labels)}` with the converter. The output
label is still checked against `--labels` (exit 3 on mismatch).

Structured output is serialised from `GeneratedContent` to match afmux's
`json.dumps(obj, separators=(",", ":"), ensure_ascii=False)`:

- keys in the order of `.structure(orderedKeys:)`;
- separators `,` and `:` with no spaces;
- non-ASCII characters unescaped; `/` not escaped;
- a number with an integral value and magnitude below 2^53 printed without
  a decimal point; other numbers in the shortest form that round-trips.

## Error handling

All errors pass through one mapping function, which decides in this order:

1. `ToolCallError`: unwrap `underlyingError` and continue with it.
2. ModelManager error 1008 (agent sandbox): exit 5. This is checked first
   because inside a sandbox the availability check may itself report the
   model unavailable, and SKILL.md gives opposite advice for 4 and 5.
3. Any other framework failure, token counting included: check
   `SystemLanguageModel.availability`; if it is `.unavailable(_)`, exit 4.
4. Otherwise the table below.

| Source | Exit |
|---|---|
| usage: bad flags or values, schema that neither decodes nor converts, bad tools file, bad session name or job mismatch, fixed-at-creation option changed, `--chunk` with session or tools, stdin rules, `unsupportedGenerationGuide`, `GenerationSchema.SchemaError` | 2 |
| `guardrailViolation`, `refusal`, framework `timeout`, `rateLimited`, `concurrentRequests`, `ToolCallError`, our `--timeout`, a signal, the tool-call cap, `contextSizeExceeded` during tool calls, session busy, any other framework error | 1 |
| label not in `--labels`; structured content that cannot be serialised | 3 |
| model unavailable (availability check above), `assetsUnavailable` | 4 |
| ModelManager error 1008 (agent sandbox), matched by error domain and code, on any framework call including token counting | 5 |
| over budget before the call; `--chunk` over `--max-chunks`; a single line over budget; session too large to compact | 6 |

- On non-zero exit nothing is printed on stdout; the reason is one line on
  stderr prefixed `afm: ` (framework messages passed through).
- SIGINT, SIGTERM and SIGHUP cancel the generation task, kill any running
  tool process group, release the session lock and exit 1 with
  `afm: interrupted by signal N`, without saving the session.

### Pinned stderr messages

Kept word for word from afmux (after the `afm: ` prefix), because SKILL.md
and agents may match them:

- `timed out after %g s` (Python `%g` formatting: `120`, `0.5`)
- `input is %d tokens, budget is %d; rerun with --chunk`
- `line %d is %d tokens, budget is %d`
- `input needs %d chunks, max is %d`
- `chunk %d/%d: ` prefix
- `interrupted by signal %d`
- `fm is blocked by a sandbox; run afm outside it`
- `model not available`
- `label %r is not one of a, b, c` (`None` when there is no label)
- all usage messages in afmux's `resolve_job`, `parse_labels` and
  `read_input`.

`%r` follows Python's `repr` for `str`: single quotes, unless the string
contains `'` and no `"`, then double quotes; backslash, the chosen quote,
`\n`, `\r`, `\t` and other non-printable characters escaped as Python does;
printable non-ASCII left as is. A `PythonRepr` helper implements this and
is tested on those edge cases.

## Compatibility

### Accepted differences from afmux

- Option prefix abbreviations are not accepted.
- `-h` output differs in layout from argparse's help, and `-h=x` or
  `--help=x` is reported as `argument --help: ignored explicit argument
  'x'` rather than argparse's `-h/--help` form.
- Unknown `--guardrails` or `--use-case` values are exit 2, not exit 1.
- The schema's share of `--budget` is `tokenCount(for: GenerationSchema)`
  rather than the token count of the schema file's text, so the exit-6
  cut-off can move by a few tokens.
- `fm not found or not executable` cannot occur; an unavailable framework
  is `model not available`, exit 4.
- `model output is not valid JSON` cannot occur under guided generation;
  exit 3 remains for label mismatch and unserialisable content.

### Porting afmux's tests

| afmux test | In afmux-swift |
|---|---|
| ListTests (both) | ported; "no fm calls" becomes "no model calls" |
| UsageTests (all 15) | ported unchanged, same messages; "no fm calls" becomes "no model or counter calls" |
| `test_fm_missing_is_exit_4` | changed: fake availability `.unavailable` gives exit 4 |
| `test_sandbox_on_count_tokens_is_exit_5_before_respond` | ported: fake counter throws 1008, no model call made |
| `test_other_count_failure_is_exit_1_with_stderr` | ported against the fake counter |
| `test_count_includes_instructions` | changed: fake counter records that instructions were counted |
| BudgetTests (both) | ported; schema share from the fake counter |
| `test_success_prints_answer_only` | ported |
| `test_respond_arguments` | changed: fake model records greedy sampling, guardrails, use-case, instructions and prompt |
| `test_default_guardrails_permissive` | ported via the same recording |
| `test_refusal_is_exit_1_with_stderr` | ported: fake throws `guardrailViolation` |
| `test_respond_failure_with_model_unavailable_is_exit_4` | ported: fake throws, availability `.unavailable` |
| `test_sandbox_on_respond_is_exit_5` | ported |
| `test_timeout_is_exit_1_and_kills_child` | changed: fake sleeps; assert exit 1, message, and that generation was cancelled |
| `test_sigterm_kills_child_and_removes_temp_schema` | changed: no temp file exists; assert exit 1, message, cancellation |
| SchemaTests: classify schema fields | changed: assert the built `GenerationSchema` constrains `label` to the enum |
| SchemaTests: instructions have labels, compact JSON, label outside list | ported |
| `test_invalid_json_is_exit_3_with_raw_on_stderr` | dropped (cannot occur) |
| `test_extract_uses_given_schema_and_compacts`, `test_ask_with_schema` | ported; schema file decoded as `GenerationSchema` |
| ChunkTests (all 8) | ported against the fake counter |
| IntegrationTests | ported to the IntegrationTests target |

## Testing

Swift Testing, `swift test`. No model needed except for the integration
target.

- **AFMuxCoreTests** against FakeModel and FakeTokenCounter: argument
  parsing; budget checks; chunk planning; schema loading (decode path,
  converter path, both-fail message); JSON output formatting (integers,
  non-ASCII, key order); the tool loop, running context count, truncation
  markers, "context nearly full" reply, call cap; compaction trigger,
  summary entry shape, second fold, too-large and failed-summary paths;
  instructions rewrite of tool definitions; error mapping including the
  availability override; presets match `presets/*.md`.
- **CLITests**: run the built `afm` with `AFMUX_FAKE` as a subprocess and
  assert stdout, stderr and exit code, covering the ported afmux cases and
  the new options.
- **Tools**: built-ins against a temporary directory tree; command tools
  for substitution of each value type, missing optional argument, non-zero
  exit, tool timeout, truncation, and that an `sh -c` grandchild is killed
  with its group; tools-file validation errors.
- **Sessions**: round-trip; file unchanged after a failed turn; two
  concurrent writers serialise under the lock; busy timeout; job mismatch
  and changed fixed options are exit 2; `afm sessions` output from stored
  fields.
- **Signals**: SIGTERM during a fake generation and during a running tool
  process; assert exit 1, process group gone, lock released, session
  unchanged.
- **Integration** (skipped unless the model answers a one-word prompt):
  `classify` returns a valid label; an afmux-format schema file decodes and
  `extract` succeeds; a two-turn session answers a follow-up that needs
  turn one; `--tools fs` finds a known string in a fixture tree.

## Installation

Requirements: macOS 27 or later on Apple silicon with the on-device model
enabled; Xcode Command Line Tools (Swift 6.4).

```bash
git clone https://github.com/antvinni/afmux-swift ~/src/afmux-swift
cd ~/src/afmux-swift && swift build -c release
ln -sf "$PWD/.build/release/afm" ~/.local/bin/afm
```

This replaces afmux's Python `afm` on `PATH`. Install the afmux skill as
its README describes; nothing in it changes. Pointing the symlink back at
`afmux/scripts/afm` reverts to Python.

## Step 0: spike before implementation

Throwaway code, results recorded in the plan. The design depends on each
item; if one fails, stop and revise the spec with the user.

1. A SwiftPM command-line binary can use FoundationModels with no special
   entitlements; measure process start to first token for a one-word
   prompt, cold and warm (decides whether approach B is needed).
2. Inside the Claude Code sandbox the in-process framework fails with
   ModelManager error 1008; record the error's type, domain and code, on
   both `tokenCount` and `respond`, and what
   `SystemLanguageModel.availability` returns there.
3. `LanguageModel` and its executor can be implemented outside Apple's
   code for FakeModel, including emitting tool calls.
4. Synthetic `Transcript` entries (prompt, response, instructions with tool
   definitions) can be constructed, encoded, decoded and resumed by a new
   session.
5. An afmux-format schema file (with `x-order`) decodes as
   `GenerationSchema` and constrains output; a `DynamicGenerationSchema`
   string enum constrains output.
6. A `Tool` with `Arguments = GeneratedContent` and a custom `parameters`
   schema receives correctly shaped arguments.
7. Cancelling the task running `respond` stops generation promptly and
   frees the model for the next call.
8. `tokenCount` gives the same numbers on
   `SystemLanguageModel(useCase:guardrails:)` as on `.default`.
9. Swift Testing runs under the Command Line Tools without Xcode.
10. Whether `tokenCount(for: transcriptEntries)` includes the instructions
    entry's `toolDefinitions`, by comparing it with and without tools
    against `tokenCount(for: tools)` (see Budget).

## Non-goals (v1)

- Resident server (approach B), Private Cloud Compute, image input,
  streaming output.
- Any change to afmux's SKILL.md or its other files.
- Session expiry, rename, fork or export; `list_dir` depth; a tool trace
  flag.
- Retries of any kind.
