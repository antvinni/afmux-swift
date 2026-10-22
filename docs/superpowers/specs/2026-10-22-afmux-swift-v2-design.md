# afmux-swift v2 design

Date: 2026-10-22. Status: agreed in conversation; supersedes the v1 spec.

## Purpose

afmux pivoted from pipe mode to two jobs: `afm run`/`afm step` implement
test-gated steps on the on-device model, and `afm read` answers a question
about a long file from verified quotes (MinionS-style). v2 makes afmux-swift a
drop-in engine for that `afm`, calling FoundationModels in-process, and adds
four MinionS-inspired options for measurement.

Reference: afmux branch `read-mode` (commit `02e3997` plus the working tree
of 2026-10-22, script sha1 `9dec2fb3`), whose `tests/test_afm.py` (66 tests)
is ported as the drop-in gate.

## Drop-in behaviour

Everything in afmux's implementer design and its read mode: step-file format
(header with trailing `# comments`, `---`, spec), context validation, prompt
assembly, budget check, first attempt greedy and retries sampled, fence
stripping, test command via `/bin/sh -c` from the current directory with a
120 s timeout, already-passing skip, regression reruns of earlier steps,
identical-retry detection, duplicate-definition and zero-test warnings,
restore or delete on final failure with `<file>.afm-failed` and `.log`,
`__pycache__` cleanup, text and `--json` reports, summary line, read-mode
chunking, extract-or-abstain schema, quote verification, exit codes 0, 1, 2,
4, 5, 6, and every message word for word.

## Swift-only additions (opt-in; defaults keep drop-in behaviour)

| Option | Idea (MinionS) | Behaviour |
|---|---|---|
| `--samples K` (run/step, default 1) | several samples per job, tests as the filter | after the greedy first attempt fails, up to K-1 seeded samples of the same first prompt are tested before the retries; a sample identical to an earlier attempt is noted and not retested |
| `--split` (run/step) | single-step jobs | for a step that creates a new `.py` file and whose spec has two or more paragraphs starting `name(...)`, generate each function as its own job (module header + that paragraph + functions written so far), assemble imports and functions, test once; on failure the normal retry path continues from the assembled file |
| `--ask` repeated (read) | many jobs per round | every question is asked of every chunk; output grouped by question. One `--ask` gives the afmux output exactly |
| `--lines A-B` (read) | aggregate, then a narrower round | read only lines A..B; citations keep the file's line numbers |

`--chunk-tokens` (idea 4) is already in afmux and is ported.

## Read-mode fixes over the reference (found in review)

- A paragraph larger than the chunk size (a log with no blank lines) is split
  at line boundaries. The reference sends it as one chunk, which overflows
  the context and fails the whole read.
- A model error on one chunk is recorded and the read continues; only when
  every chunk fails is it exit 1 with the reference's message.
- A verified quote is cited with the lines it spans, not the whole chunk.

## Testing

The 66 reference tests ported to Swift Testing against the fake backend
(replies by call number, errors, delays, availability), plus tests for each
addition and fix, plus real-model integration tests.

## Comparison

Same tasks three ways: an agent working without afm, with the Python afm, and
with the Swift afm (with and without the additions). Implementer tasks: small
modules with hidden tests and short specs; read tasks: long files with known
answers. Recorded: agent tokens, wall time, tests passed, read answers
correct.
