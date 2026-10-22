import Foundation
import Testing
@testable import AFMuxCore

@Test func processRunnerBasics() async {
    let ok = await runProcess(["/bin/echo", "hi"], timeout: 5)
    #expect(ok.status == 0 && ok.stdout == "hi\n" && !ok.timedOut)
    let fail = await runProcess(["/bin/sh", "-c", "echo err >&2; exit 3"], timeout: 5)
    #expect(fail.status == 3 && fail.stderr == "err\n")
    #expect(await runProcess(["no-such-command-xyz"], timeout: 5).status == 127)
}

@Test func processTimeoutKillsTheGroup() async throws {
    let r = await runProcess(["/bin/sh", "-c", "sleep 30 & echo $!; wait"], timeout: 0.5)
    #expect(r.timedOut)
    let pid = pid_t(r.stdout.trimmingCharacters(in: .whitespacesAndNewlines))!
    try await Task.sleep(nanoseconds: 300_000_000)
    #expect(kill(pid, 0) != 0)
}

@Test func childrenGetDefaultSignalsAndOnlyStandardFds() async {
    let sig = await runProcess(["/bin/sh", "-c", "kill -TERM $$; echo survived"], timeout: 5)
    #expect(sig.status == 143 && !sig.stdout.contains("survived"))
    let fds = await runProcess(["/bin/sh", "-c", "for f in 3 4 5 6 7 8 9; do [ -e /dev/fd/$f ] && echo open $f; done; true"], timeout: 5)
    #expect(!fds.stdout.contains("open "), "\(fds.stdout)")
}

@Test func stripFenceAndSummaries() {
    #expect(stripFence("```python\nx = 1\n```\n") == "x = 1\n")
    #expect(stripFence("x = 1\n\n") == "x = 1\n")
    #expect(failureSummary("FAIL: test_a (m.T.test_a)\nTraceback (most recent call last):\nAssertionError: 1 != 2\n")
        == "FAIL: test_a (m.T.test_a) | AssertionError: 1 != 2")
    #expect(failureSummary("") == "no output")
    #expect(testsRun("Ran 3 tests in 0.1s\n\nOK") == 3)
    #expect(testsRun("5 passed in 0.2s") == 5)
    #expect(testsRun("nothing") == nil)
    #expect(duplicateDefinitions("def a():\n  pass\ndef b(): pass\ndef a(): pass\n") == ["a"])
}

@Test func splitJobsParsing() {
    let step = Step(id: "01", path: "", file: "util.py", test: "true", context: [], spec: """
    Module util.py.

    f(x): one.
    Examples: f(1) == 1.

    g(y): two.

    Note that g never raises.
    """)
    let jobs = splitJobs(step)!
    #expect(jobs.header == "Module util.py.")
    #expect(jobs.functions.map(\.name) == ["f", "g"])
    #expect(jobs.functions[1].text.contains("never raises"))
    #expect(assemble(["import re\n\ndef f(x):\n    return x\n", "import re\nimport os\n\ndef g(y):\n    return y\n"])
        == "import re\nimport os\n\n\ndef f(x):\n    return x\n\n\ndef g(y):\n    return y\n")
}
