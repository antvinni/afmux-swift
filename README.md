# afmux-swift

A Swift `afm` that is a drop-in engine for the
[afmux](https://github.com/antvinni/afmux) skill. Claude Code, OpenCode or
Codex pipe command output or files into `afm`, and the free on-device Apple
Foundation Model returns a short answer. This version calls the
FoundationModels framework in-process instead of spawning Apple's `fm` CLI,
which gives it in-process token counting, native structured output, real
tool calling, and sessions that keep a transcript across calls.

    pytest 2>&1 | afm ask "list each failing test and its error, one per line"
    git diff --cached | afm commit-msg
    afm ask --tools fs "which file under src defines parseConfig?" < /dev/null

The design, its measurements and the reasoning behind each choice are in
[`docs/superpowers/specs/2026-10-22-afmux-swift-design.md`](docs/superpowers/specs/2026-10-22-afmux-swift-design.md).

## Requirements

- macOS 27 or later on Apple silicon, with the on-device model enabled.
- Xcode Command Line Tools (Swift 6.4).

## Install

```bash
git clone https://github.com/antvinni/afmux-swift ~/src/afmux-swift
cd ~/src/afmux-swift && swift build -c release
ln -sf "$PWD/.build/release/afm" ~/.local/bin/afm
```

This replaces afmux's Python `afm` on `PATH`. Install the afmux skill as its
README describes; nothing in it changes. Point the symlink back at
`afmux/scripts/afm` to revert.

## What stays the same

Presets (`summarise`, `classify`, `extract`, `commit-msg`), `ask`, every
option, the output formats and the exit codes are afmux's (reference: afmux
commit `e814b9e`); see afmux's `SKILL.md`. Its test suite is ported in
`Tests/CLITests/AfmuxPortTests.swift`.

Accepted differences:

- Option prefix abbreviations are not accepted.
- `-h` output differs in layout from argparse's help, and `-h=x` or
  `--help=x` is reported as `argument --help: ignored explicit argument
  'x'` rather than argparse's `-h/--help` form.
- Unknown `--guardrails` or `--use-case` values are exit 2, not exit 1.
- The schema's share of `--budget` is `tokenCount(for: GenerationSchema)`
  rather than the token count of the schema file's text, so the exit-6
  cut-off can move by a few tokens.
- A `--schema` file without `x-order` is accepted (converted as plain JSON
  Schema) instead of exit 2.
- `fm not found or not executable` and `fm count-tokens failed/returned
  ...` cannot occur. An unavailable framework is `model not available`,
  exit 4.
- afmux strips ANSI escapes from `fm`'s stderr; framework messages carry
  none, so there is nothing to strip.

## Tools

Tools let the on-device model fetch its own input, so the agent does not
read files or command output into its context first. They are off by
default because their definitions take up part of the 8192-token context.

`--tools fs` enables three built-in tools. Paths are relative to the
working directory or absolute; there is no confinement.

| Tool | Arguments | Returns |
|---|---|---|
| `read_file` | `path`, optional `start_line`, `end_line` | numbered lines |
| `grep` | `pattern` (extended regex), `path`, optional `glob` | `file:line:text` |
| `list_dir` | `path` | entries, directories ending in `/` |

`--tools-file FILE` adds caller-defined tools that run commands:

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

`command` is an argv array; `{name}` is replaced by the argument's value.
There is no shell unless you ask for one:
`["sh", "-c", "pytest -q \"$1\" | tail -50", "_", "{path}"]`. Each command
runs in its own process group with stdin `/dev/null`; the model receives
`exit N`, `stdout:` and `stderr:`.

Limits, all there to keep work inside the context:

| Option | Default | |
|---|---|---|
| `--max-tool-calls N` | 8 | more calls in one model call is exit 1 |
| `--tool-output-budget TOKENS` | 600 | each result is cut at a line boundary, with a marker saying how to fetch the rest |
| `--tool-timeout SECONDS` | 30 | the process group is killed and the model is told |

When the context is nearly full, a tool replies `Context nearly full. Answer
now with what you have.` instead of running.

## Sessions

```bash
pytest 2>&1 | afm ask --session t1 "list failing tests"
afm ask --session t1 "which of those touch the db?" < /dev/null
```

- The first call creates the session; the preset or `ask` text becomes its
  instructions and stdin is the first prompt.
- Later calls use the same job. For `ask`, the new question (plus stdin, if
  any) is the prompt; for a preset, stdin is the prompt.
- `--labels`, `--guardrails` and `--use-case` are fixed at creation;
  `--schema` and tools may change per turn.
- Sessions live in `~/Library/Application Support/afmux/sessions/`. A
  session is saved only when the turn succeeds; concurrent calls on one
  session wait for each other (up to `--timeout`).
- When the transcript outgrows `--budget`, older turns are summarised by the
  on-device model and replaced by the summary. Each compaction writes
  `afm: session NAME compacted (N → M tokens)` to stderr, because it loses
  detail.
- `afm sessions` lists sessions (name, turns, tokens, last modified);
  `afm sessions rm NAME` deletes one.

## Agent sandboxes

afmux documents that inside a sandboxed agent shell `fm` fails with
`ModelManagerServices.ModelManagerError error 1008`; afm maps that error to
exit 5 (`fm is blocked by a sandbox; run afm outside it`) and checks it
before anything else. In the Claude Code sandbox used during development,
the in-process framework worked normally, so this path is tested only with
the fake backend. To check your own setup, run `echo hi | afm summarise` in
a sandboxed agent shell: it either answers or exits 5.

Building is different: inside the Claude Code sandbox, the compiler cannot
load the Swift Testing macro plugin, so run `swift build` and `swift test`
outside it.

## Development

```bash
swift build && swift test
```

- `Tests/AFMuxCoreTests` covers the library against a scripted fake model.
- `Tests/CLITests` runs the built binary with `AFMUX_FAKE=<script.json>`,
  which selects the fake backend, and `AFMUX_SESSIONS_DIR`, which moves the
  session directory. Both are for tests only.
- `Tests/IntegrationTests` uses the real model and is skipped where the
  model does not answer.

With only the Command Line Tools installed, the build system sometimes
leaves the Swift Testing macro plugin out of test compiles;
`Package.swift` names the plugin directory to prevent that.

## Licence

MIT, see [`LICENSE`](LICENSE).
