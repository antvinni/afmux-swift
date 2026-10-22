# afmux-swift

> **Archived 2026-10-22.** Use [afmux](https://github.com/antvinni/afmux)'s
> Python `afm`. With afmux's read fixes (#15) the two engines gave the same
> results on every benchmark task; the only Swift advantage was seeded
> sampling (`--samples`, one extra module of five), which the `fm` CLI cannot
> do. See [`docs/benchmarks/2026-10-22.md`](docs/benchmarks/2026-10-22.md).
> If sampling ever matters, a small Swift sampling helper called by afmux
> would be the way back, not a second `afm`.

A Swift `afm` that is a drop-in engine for the
[afmux](https://github.com/antvinni/afmux) skill, calling Apple's
FoundationModels framework in-process instead of the `fm` CLI. Same two jobs:

```
afm run steps/                     # implement test-gated steps on the on-device model
afm step steps/01-util.md          # one step
afm read app.log --ask "question"  # answer from verified quotes, without the agent reading the file
```

Step files, prompts, retries, regression checks, reports, `--json` and exit
codes are afmux's (reference: afmux `read-mode`, whose test suite is ported in
`Tests/CLITests/AfmuxPortTests.swift`). See afmux's `SKILL.md` for how an
agent uses it.

## Additions (opt-in, from the MinionS protocol)

| Option | What it does | Measured (docs/benchmarks) |
|---|---|---|
| `--samples K` | after the greedy attempt fails, test up to K-1 seeded samples of the same prompt before the retry | 3/5 modules instead of 2/5 at K=3 |
| `--split` | generate a new module one function at a time, then test it whole | worse alone (1/5); not recommended |
| `--ask` repeated | every question against every chunk, one block per question | |
| `--lines A-B` | read only those lines; citations keep the file's numbering | |

## Read-mode fixes over the reference

- A paragraph larger than a chunk (a log with no blank lines) is split at
  lines; the reference sends the whole file as one chunk and fails.
- A failed chunk is reported and the read continues.
- Quotes are cited by their own line range.

On the benchmark's four read questions: Swift 4/4, Python 1/4.

## Install

```bash
git clone https://github.com/antvinni/afmux-swift ~/src/afmux-swift
cd ~/src/afmux-swift && swift build -c release
ln -sf "$PWD/.build/release/afm" ~/.local/bin/afm
```

This replaces afmux's Python `afm` on `PATH`; the afmux skill is unchanged.
Point the symlink back at `afmux/scripts/afm` to revert. Requires macOS 27 on
Apple silicon with the on-device model, and the Command Line Tools (Swift 6.4).

## Development

```bash
swift build && swift test       # unit and CLI tests use a scripted fake model (AFMUX_FAKE)
python3 bench/run.py all        # benchmark Python and Swift afm on bench/ tasks
```

Inside the Claude Code sandbox the Swift Testing macro plugin cannot load, so
build and test outside it. `Package.swift` names the Testing plugin directory
because Command Line Tools builds otherwise drop it intermittently.

## Licence

MIT, see [`LICENSE`](LICENSE).
