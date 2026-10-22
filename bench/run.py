#!/usr/bin/env python3
"""Benchmark afm engines on the bench tasks, with no agent in the loop.

    python3 bench/run.py implement   # every implement task with every engine
    python3 bench/run.py read        # every read question with every engine
    python3 bench/run.py all

Engines: the Python afm (AFMUX_PY, default ../afmux/scripts/afm) and the Swift afm
(AFMUX_SWIFT, default .build/release/afm), the Swift one also with its additions.
Results go to bench/results/<kind>-<timestamp>.json and a table on stdout.
"""
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import time

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
PY = os.environ.get("AFMUX_PY", os.path.join(os.path.dirname(ROOT), "afmux", "scripts", "afm"))
SW = os.environ.get("AFMUX_SWIFT", os.path.join(ROOT, ".build", "release", "afm"))

# engine name -> (command prefix, extra options after the subcommand)
IMPLEMENT_ENGINES = {
    "python": ([sys.executable, PY], []),
    "swift": ([SW], []),
    "swift --samples 3": ([SW], ["--samples", "3"]),
    "swift --split": ([SW], ["--split"]),
    "swift --split --samples 3": ([SW], ["--split", "--samples", "3"]),
}
READ_ENGINES = {
    "python": ([sys.executable, PY], []),
    "swift": ([SW], []),
    "swift --chunk-tokens 600": ([SW], ["--chunk-tokens", "600"]),
}


def unittest_counts(task_dir, module):
    p = subprocess.run([sys.executable, "-m", "unittest", module], cwd=task_dir, capture_output=True, text=True, timeout=120)
    out = p.stdout + p.stderr
    ran = int((re.search(r"Ran (\d+) tests?", out) or [0, 0])[1])
    bad = sum(int(n) for n in re.findall(r"(?:failures|errors)=(\d+)", out))
    return ran, ran - bad if p.returncode else ran


def implement(names):
    rows = []
    tasks = sorted(n for n in os.listdir(os.path.join(HERE, "implement")) if not n.startswith("."))
    for task in tasks:
        src = os.path.join(HERE, "implement", task)
        ref_dir = tempfile.mkdtemp(prefix="afm-ref-")
        shutil.copy(os.path.join(src, "test_%s.py" % task), ref_dir)
        shutil.copy(os.path.join(src, "reference.py"), os.path.join(ref_dir, task + ".py"))
        total, _ = unittest_counts(ref_dir, "test_" + task)
        for name in names:
            work = tempfile.mkdtemp(prefix="afm-bench-")
            shutil.copytree(os.path.join(src, "steps"), os.path.join(work, "steps"))
            shutil.copy(os.path.join(src, "test_%s.py" % task), work)
            prefix, extra = IMPLEMENT_ENGINES[name]
            cmd = prefix + ["run", "steps", "--json"] + extra
            t0 = time.time()
            p = subprocess.run(cmd, cwd=work, capture_output=True, text=True, timeout=1800)
            seconds = time.time() - t0
            try:
                report = json.loads(p.stdout)
                attempts = sum(s["attempts"] for s in report["steps"])
            except ValueError:
                report, attempts = None, None
            _, passed = unittest_counts(work, "test_" + task)
            rows.append({"task": task, "engine": name, "exit": p.returncode, "tests": total, "passed": passed,
                         "attempts": attempts, "seconds": round(seconds, 1), "stderr": p.stderr.strip()[-300:]})
            print("%-9s %-26s exit %d  tests %d/%d  attempts %s  %.1f s" % (task, name, p.returncode, passed, total, attempts, seconds), flush=True)
    return rows


def read(names):
    rows = []
    with open(os.path.join(HERE, "read", "questions.json")) as f:
        questions = json.load(f)
    for q in questions:
        path = os.path.join(HERE, "read", q["file"])
        size = os.path.getsize(path)
        for name in names:
            prefix, extra = READ_ENGINES[name]
            cmd = prefix + ["read", path, "--ask", q["ask"]] + extra
            t0 = time.time()
            p = subprocess.run(cmd, capture_output=True, text=True, timeout=3600)
            seconds = time.time() - t0
            quotes = re.findall(r'^\[lines [^\]]+\] "(.*)"$', p.stdout, re.M)
            correct = any(q["expect"].lower() in x.lower() for x in quotes)
            m = re.search(r"\((\d+) chunks?, (\d+) tokens read locally|of (\d+) chunks matched \((\d+) tokens", p.stdout)
            file_tokens = int(m.group(2) or m.group(4)) if m else None
            rows.append({"file": q["file"], "ask": q["ask"], "engine": name, "exit": p.returncode, "correct": correct,
                         "quotes": len(quotes), "output_chars": len(p.stdout), "file_bytes": size, "file_tokens": file_tokens,
                         "seconds": round(seconds, 1), "stderr": p.stderr.strip()[-300:]})
            print("%-26s %-26s exit %d  %s  quotes %d  out %d chars  file %s tok  %.1f s" % (
                q["file"], name, p.returncode, "correct" if correct else "WRONG  ", len(quotes), len(p.stdout),
                file_tokens, seconds), flush=True)
    return rows


def main(argv):
    kind = argv[0] if argv else "all"
    os.makedirs(os.path.join(HERE, "results"), exist_ok=True)
    stamp = time.strftime("%Y%m%d-%H%M%S")
    for k, fn, engines in (("implement", implement, IMPLEMENT_ENGINES), ("read", read, READ_ENGINES)):
        if kind in (k, "all"):
            names = [n for n in engines if not argv[1:] or n in argv[1:]]
            rows = fn(names)
            with open(os.path.join(HERE, "results", "%s-%s.json" % (k, stamp)), "w") as f:
                json.dump({"engines": {n: engines[n] for n in names}, "rows": rows}, f, indent=1)


if __name__ == "__main__":
    main(sys.argv[1:])
