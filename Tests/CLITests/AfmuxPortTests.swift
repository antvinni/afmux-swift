import Foundation
import Testing

// afmux tests/test_afm.py (read-mode reference), one Swift test per Python test.

@Suite struct UsageTests {
    func usage(_ r: Run, _ needle: String) {
        #expect(r.code == 2, "\(r.stdout)\(r.stderr)")
        #expect(r.stdout == "")
        #expect(r.stderr.contains(needle), "\(r.stderr)")
    }

    @Test func noCommand() throws { usage(try Project().run([]), "usage") }
    @Test func missingDir() throws { usage(try Project().run(["run", "nosuch"]), "nosuch") }
    @Test func emptyDir() throws { usage(try Project().run(["run", "steps"]), "no step files") }

    @Test func stepWithoutFileKey() throws {
        let pr = Project()
        pr.step("01-a", file: nil)
        usage(try pr.run(["run", "steps"]), "file:")
    }

    @Test func stepWithoutTestKey() throws {
        let pr = Project()
        pr.step("01-a", test: nil)
        usage(try pr.run(["run", "steps"]), "test:")
    }

    @Test func stepWithoutSeparator() throws {
        let pr = Project()
        pr.write("steps/01-a.md", "file: util.py\ntest: true\nno separator here\n")
        usage(try pr.run(["run", "steps"]), "---")
    }

    @Test func stepWithEmptySpec() throws {
        let pr = Project()
        pr.write("steps/01-a.md", "file: util.py\ntest: true\n---\n\n")
        usage(try pr.run(["run", "steps"]), "empty")
    }

    @Test func unknownHeaderKey() throws {
        let pr = Project()
        pr.step("01-a", headerExtra: "\nbogus: 1")
        usage(try pr.run(["run", "steps"]), "bogus")
    }

    @Test func missingContextFile() throws {
        let pr = Project()
        pr.step("01-a", context: "nothere.py")
        usage(try pr.run(["run", "steps"]), "nothere.py")
    }

    @Test func contextProducedByAnEarlierStepIsAccepted() throws {
        let pr = Project()
        pr.write("test_util.py", slugifyTests)
        pr.step("01-a", file: "first.py", test: "true")
        pr.step("02-b", file: "util.py", context: "first.py")
        pr.reply("# first\n")
        pr.reply(goodSlugify)
        let r = try pr.run(["run", "steps"])
        #expect(r.code == 0, "\(r.stdout)\(r.stderr)")
        #expect(pr.prompts[1].contains("# first"))
    }

    @Test func contextFromALaterStepIsRejected() throws {
        let pr = Project()
        pr.step("01-a", file: "util.py", context: "later.py")
        pr.step("02-b", file: "later.py", test: "true")
        usage(try pr.run(["run", "steps"]), "later.py")
    }

    @Test func helpUsageLineIsNotDoubled() throws {
        let r = try Project().run(["--help"])
        #expect(r.code == 0, "\(r.stderr)")
        #expect(r.stdout.hasPrefix("usage: afm "))
        #expect(!r.stdout.contains("usage: usage:"))
        #expect(r.stdout.contains("--retries") && r.stdout.contains("file:"))
    }

    @Test func badRetries() throws {
        let pr = Project()
        pr.step("01-a")
        usage(try pr.run(["run", "steps", "--retries", "-1"]), "--retries")
    }

    @Test func usageErrorsMakeNoFmCalls() throws {
        let pr = Project()
        pr.step("01-a", file: nil)
        try pr.run(["run", "steps"])
        #expect(pr.calls.isEmpty)
    }

    @Test func allStepsValidatedBeforeAnyRun() throws {
        let pr = Project()
        pr.step("01-a")
        pr.step("02-b", test: nil)
        pr.reply(goodSlugify)
        let r = try pr.run(["run", "steps"])
        #expect(r.code == 2, "\(r.stderr)")
        #expect(pr.calls.isEmpty)
    }
}

@Suite struct SingleStepTests {
    @Test func passFirstTry() throws {
        let pr = Project()
        pr.write("test_util.py", slugifyTests)
        pr.step("01-slugify")
        pr.reply(goodSlugify)
        let r = try pr.run(["run", "steps"])
        #expect(r.code == 0, "\(r.stdout)\(r.stderr)")
        #expect(pr.read("util.py") == goodSlugify)
        #expect(r.stdout.contains("01-slugify") && r.stdout.contains("pass"))
        #expect(r.stderr == "")
        #expect(pr.responds.count == 1)
    }

    @Test func promptHasSpecNotTests() throws {
        let pr = Project()
        pr.write("test_util.py", slugifyTests)
        pr.step("01-slugify")
        pr.reply(goodSlugify)
        try pr.run(["run", "steps"])
        let rec = pr.responds[0]
        let prompt = rec["prompt"] as! String
        #expect(prompt.contains(slugifySpec))
        #expect(!prompt.contains("assertEqual"))
        #expect((rec["instructions"] as! String).contains("util.py"))
        #expect(rec["sampling"] as? String == "greedy")
        #expect(!prompt.contains("Current contents"))
    }

    @Test func existingFileIsShownForEdit() throws {
        let pr = Project()
        pr.write("test_util.py", slugifyTests)
        pr.write("util.py", "# old\n")
        pr.step("01-slugify")
        pr.reply(goodSlugify)
        try pr.run(["run", "steps"])
        #expect(pr.prompts[0].contains("Current contents of util.py") && pr.prompts[0].contains("# old"))
    }

    @Test func contextFilesAreShown() throws {
        let pr = Project()
        pr.write("test_util.py", slugifyTests)
        pr.write("types.py", "class Thing: pass\n")
        pr.write("errors.py", "class Oops(Exception): pass\n")
        pr.step("01-slugify", context: "types.py, errors.py")
        pr.reply(goodSlugify)
        try pr.run(["run", "steps"])
        let prompt = pr.prompts[0]
        #expect(prompt.contains("Reference only, do not modify: types.py"))
        #expect(prompt.contains("class Thing") && prompt.contains("class Oops"))
    }

    @Test func fencesAreStripped() throws {
        let pr = Project()
        pr.write("test_util.py", slugifyTests)
        pr.step("01-slugify")
        pr.reply("```python\n" + goodSlugify + "```\n")
        let r = try pr.run(["run", "steps"])
        #expect(r.code == 0, "\(r.stdout)\(r.stderr)")
        #expect(pr.read("util.py") == goodSlugify)
    }

    @Test func fileInSubdirectoryIsCreated() throws {
        let pr = Project()
        pr.write("test_util.py", slugifyTests.replacingOccurrences(of: "from util", with: "from pkg.util"))
        pr.write("pkg/__init__.py", "")
        pr.step("01-slugify", file: "pkg/util.py")
        pr.reply(goodSlugify)
        let r = try pr.run(["run", "steps"])
        #expect(r.code == 0, "\(r.stdout)\(r.stderr)")
        #expect(pr.exists("pkg/util.py"))
    }

    @Test func jsonReport() throws {
        let pr = Project()
        pr.write("test_util.py", slugifyTests)
        pr.step("01-slugify")
        pr.reply(goodSlugify)
        let r = try pr.run(["run", "steps", "--json"])
        #expect(r.code == 0, "\(r.stdout)\(r.stderr)")
        let d = try JSONSerialization.jsonObject(with: Data(r.stdout.utf8)) as! [String: Any]
        #expect(d["failed"] is NSNull)
        let s = (d["steps"] as! [[String: Any]])[0]
        #expect(s["id"] as? String == "01-slugify" && s["file"] as? String == "util.py")
        #expect(s["result"] as? String == "pass" && s["attempts"] as? Int == 1 && s["seconds"] != nil)
    }

    @Test func stepCommandRunsOneFile() throws {
        let pr = Project()
        pr.write("test_util.py", slugifyTests)
        let path = pr.step("01-slugify")
        pr.reply(goodSlugify)
        let r = try pr.run(["step", path])
        #expect(r.code == 0, "\(r.stdout)\(r.stderr)")
        #expect(pr.read("util.py") == goodSlugify)
    }

    @Test func stepsRunInFilenameOrder() throws {
        let pr = Project()
        pr.step("02-second", spec: "SECOND", file: "second.py", test: "true")
        pr.step("01-first", spec: "FIRST", file: "first.py", test: "true")
        pr.step("10-tenth", spec: "TENTH", file: "tenth.py", test: "true")
        for _ in 0..<3 { pr.reply("x = 1\n") }
        let r = try pr.run(["run", "steps"])
        #expect(r.code == 0, "\(r.stdout)\(r.stderr)")
        let p = pr.prompts
        #expect(p[0].contains("FIRST") && p[1].contains("SECOND") && p[2].contains("TENTH"))
        #expect(r.stdout.range(of: "01-first")!.lowerBound < r.stdout.range(of: "02-second")!.lowerBound)
    }
}

@Suite struct RetryAndFailureTests {
    @Test func failThenPassOnRetry() throws {
        let pr = Project()
        pr.write("test_util.py", slugifyTests)
        pr.step("01-slugify")
        pr.reply(badSlugify)
        pr.reply(goodSlugify)
        let r = try pr.run(["run", "steps"])
        #expect(r.code == 0, "\(r.stdout)\(r.stderr)")
        #expect(pr.read("util.py") == goodSlugify)
        #expect(lines(r.stdout)[1].contains("2"))
        let retry = pr.prompts[1]
        #expect(retry.contains("Your previous implementation") && retry.contains("return title"))
        #expect(retry.contains("test_basic") && retry.contains(slugifySpec))
    }

    @Test func failAfterRetriesRestoresFileAndSavesAttempt() throws {
        let pr = Project()
        pr.write("test_util.py", slugifyTests)
        pr.write("util.py", "# original\n")
        pr.step("01-slugify")
        pr.reply(badSlugify)
        pr.reply(badSlugify)
        let r = try pr.run(["run", "steps"])
        #expect(r.code == 1, "\(r.stdout)\(r.stderr)")
        #expect(pr.read("util.py") == "# original\n")
        #expect(pr.read("util.py.afm-failed") == badSlugify)
        for needle in ["FAIL", "failed after 2 attempts", "python3 -m unittest test_util", "test_basic", "util.py.afm-failed", "restored"] {
            #expect(r.stdout.contains(needle), "\(needle)")
        }
    }

    @Test func createdFileIsDeletedOnFinalFailure() throws {
        let pr = Project()
        pr.write("test_util.py", slugifyTests)
        pr.step("01-slugify")
        pr.reply(badSlugify)
        pr.reply(badSlugify)
        let r = try pr.run(["run", "steps"])
        #expect(r.code == 1)
        #expect(!pr.exists("util.py") && pr.exists("util.py.afm-failed"))
        #expect(r.stdout.contains("removed"))
    }

    @Test func zeroRetries() throws {
        let pr = Project()
        pr.write("test_util.py", slugifyTests)
        pr.step("01-slugify")
        pr.reply(badSlugify)
        let r = try pr.run(["run", "steps", "--retries", "0"])
        #expect(r.code == 1)
        #expect(pr.responds.count == 1)
        #expect(r.stdout.contains("failed after 1 attempt"))
    }

    @Test func stopsAtFirstFailure() throws {
        let pr = Project()
        pr.write("test_util.py", slugifyTests)
        pr.step("01-a")
        pr.step("02-b", spec: "SECOND", file: "b.py", test: "python3 -c \"import b; assert b.OK\"")
        pr.step("03-c", spec: "THIRD", file: "c.py", test: "true")
        pr.reply(goodSlugify)
        pr.reply("OK = False\n")
        pr.reply("OK = False\n")
        pr.reply("x = 1\n")
        let r = try pr.run(["run", "steps"])
        #expect(r.code == 1, "\(r.stdout)\(r.stderr)")
        #expect(pr.responds.count == 3)
        #expect(r.stdout.contains("03-c") && r.stdout.contains("skipped"))
    }

    @Test func jsonReportOnFailure() throws {
        let pr = Project()
        pr.write("test_util.py", slugifyTests)
        pr.step("01-a")
        pr.step("02-b", spec: "SECOND", file: "b.py", test: "true")
        pr.reply(badSlugify)
        pr.reply(badSlugify)
        let r = try pr.run(["run", "steps", "--json"])
        #expect(r.code == 1)
        let d = try JSONSerialization.jsonObject(with: Data(r.stdout.utf8)) as! [String: Any]
        let f = d["failed"] as! [String: Any]
        #expect(f["id"] as? String == "01-a")
        #expect((f["output"] as! String).contains("test_basic"))
        #expect(f["test"] as? String == "python3 -m unittest test_util")
        #expect((f["saved"] as! String).hasSuffix("util.py.afm-failed"))
        #expect((d["steps"] as! [[String: Any]]).map { $0["result"] as! String } == ["FAIL", "skipped"])
    }

    @Test func emptyModelOutputCountsAsFailure() throws {
        let pr = Project()
        pr.write("test_util.py", slugifyTests)
        pr.step("01-slugify")
        pr.reply("   \n")
        pr.reply(goodSlugify)
        let r = try pr.run(["run", "steps"])
        #expect(r.code == 0, "\(r.stdout)\(r.stderr)")
        #expect(lines(r.stdout)[1].contains("2"))
    }

    @Test func fmRefusalFailsTheStep() throws {
        let pr = Project()
        pr.write("test_util.py", slugifyTests)
        pr.step("01-slugify")
        let r = try pr.run(["run", "steps"], respond: ["error": "guardrail"], withReplies: false)
        #expect(r.code == 1, "\(r.stdout)\(r.stderr)")
        #expect(r.stdout.contains("01-slugify") && r.stdout.contains("guardrails"))
    }

    @Test func sandboxIsExit5() throws {
        let pr = Project()
        pr.write("test_util.py", slugifyTests)
        pr.step("01-slugify")
        let r = try pr.run(["run", "steps"], count: ["error": "sandbox"])
        #expect(r.code == 5, "\(r.stdout)\(r.stderr)")
        #expect(r.stderr.contains("sandbox"))
    }

    @Test func fmMissingIsExit4() throws {
        let pr = Project()
        pr.step("01-slugify")
        let r = try pr.run(["run", "steps"], count: ["error": "other:no model"], availability: "unavailable")
        #expect(r.code == 4, "\(r.stderr)")
    }

    @Test func overBudgetNamesTheStep() throws {
        let pr = Project()
        pr.write("test_util.py", slugifyTests)
        pr.step("01-big", spec: String(repeating: "x", count: 2000))
        let r = try pr.run(["run", "steps", "--budget", "100"])
        #expect(r.code == 6, "\(r.stdout)\(r.stderr)")
        #expect(r.stderr.contains("01-big") && r.stderr.contains("budget is 100") && r.stderr.contains("split the step"))
        #expect(pr.responds.isEmpty)
    }

    @Test func timeoutFailsTheStep() throws {
        let pr = Project()
        pr.write("test_util.py", slugifyTests)
        pr.step("01-slugify")
        let r = try pr.run(["run", "steps", "--timeout", "0.5", "--retries", "0"], respond: ["delay": 5], withReplies: false)
        #expect(r.code == 1, "\(r.stdout)\(r.stderr)")
        #expect(r.stdout.contains("timed out"))
    }

    @Test func testCommandFailureOutputIsShown() throws {
        let pr = Project()
        pr.step("01-slugify", test: "python3 -c \"import sys; print('boom'); sys.exit(3)\"")
        pr.reply(goodSlugify)
        pr.reply(goodSlugify)
        let r = try pr.run(["run", "steps"])
        #expect(r.code == 1)
        #expect(r.stdout.contains("boom"))
    }
}

@Suite struct RerunTests {
    @Test func stepWhoseTestAlreadyPassesIsSkipped() throws {
        let pr = Project()
        pr.write("test_util.py", slugifyTests)
        pr.write("util.py", goodSlugify)
        pr.step("01-slugify")
        let r = try pr.run(["run", "steps"])
        #expect(r.code == 0, "\(r.stdout)\(r.stderr)")
        #expect(pr.responds.isEmpty)
        #expect(r.stdout.contains("already"))
        let d = try JSONSerialization.jsonObject(with: Data(try pr.run(["run", "steps", "--json"]).stdout.utf8)) as! [String: Any]
        #expect((d["steps"] as! [[String: Any]])[0]["attempts"] as? Int == 0)
    }

    @Test func rerunAfterFixSkipsPassedSteps() throws {
        let pr = Project()
        pr.write("test_util.py", slugifyTests)
        pr.step("01-a")
        pr.step("02-b", file: "other.py", test: "python3 -c \"import other; assert other.X == 1\"")
        pr.reply(goodSlugify)
        pr.reply("X = 2\n")
        pr.reply("X = 2\n")
        var r = try pr.run(["run", "steps"])
        #expect(r.code == 1, "\(r.stdout)\(r.stderr)")
        // the fake numbers replies per process; the second run's first model call is its call 1
        pr.replies = ["X = 1\n"]
        r = try pr.run(["run", "steps"])
        #expect(r.code == 0, "\(r.stdout)\(r.stderr)")
        #expect(pr.responds.count == 4, "step 01 must not be regenerated on the rerun")
        #expect(pr.read("other.py") == "X = 1\n")
    }

    @Test func handWrittenStepIsLeftAlone() throws {
        let pr = Project()
        pr.write("test_util.py", slugifyTests)
        pr.write("util.py", goodSlugify + "# by hand\n")
        pr.step("01-slugify")
        try pr.run(["run", "steps"])
        #expect(pr.read("util.py").contains("# by hand"))
    }
}

@Suite struct ReportDetailTests {
    @Test func retriedPassReportsWhyTheFirstAttemptFailed() throws {
        let pr = Project()
        pr.write("test_util.py", slugifyTests)
        pr.step("01-slugify")
        pr.reply(badSlugify)
        pr.reply(goodSlugify)
        let r = try pr.run(["run", "steps"])
        #expect(r.code == 0, "\(r.stdout)\(r.stderr)")
        #expect(r.stdout.contains("attempt 1 failed") && r.stdout.contains("test_basic"))
        let d = try JSONSerialization.jsonObject(with: Data(try pr.run(["run", "steps", "--json"]).stdout.utf8)) as! [String: Any]
        #expect((d["steps"] as! [[String: Any]])[0]["result"] as? String == "pass")
    }

    @Test func staleFailedAttemptIsRemovedOnPass() throws {
        let pr = Project()
        pr.write("test_util.py", slugifyTests)
        pr.write("util.py.afm-failed", "old\n")
        pr.write("util.py.afm-failed.log", "old\n")
        pr.step("01-slugify")
        pr.reply(goodSlugify)
        let r = try pr.run(["run", "steps"])
        #expect(r.code == 0, "\(r.stdout)\(r.stderr)")
        #expect(!pr.exists("util.py.afm-failed") && !pr.exists("util.py.afm-failed.log"))
    }

    @Test func failureKeepsFullLogAndShowsHeadAndTail() throws {
        let pr = Project()
        let body = (0..<200).map { String(format: "line %03d", $0) }.joined(separator: "\\n")
        pr.step("01-x", test: "python3 -c \"print('\(body)'); raise SystemExit(1)\"")
        pr.reply("x = 1\n")
        pr.reply("x = 1\n")
        let r = try pr.run(["run", "steps"])
        #expect(r.code == 1)
        #expect(r.stdout.contains("line 000") && r.stdout.contains("line 199") && r.stdout.contains("lines omitted"))
        #expect(pr.read("util.py.afm-failed.log").contains("line 100"))
        #expect(r.stdout.contains("util.py.afm-failed.log"))
    }

    @Test func removedMessageSaysItDidNotExist() throws {
        let pr = Project()
        pr.write("test_util.py", slugifyTests)
        pr.step("01-slugify")
        pr.reply(badSlugify)
        pr.reply(badSlugify)
        #expect(try pr.run(["run", "steps"]).stdout.contains("did not exist before"))
    }
}

@Suite struct RegressionTests {
    @Test func stepThatBreaksAnEarlierStepFailsWithRegression() throws {
        let pr = Project()
        pr.write("test_util.py", slugifyTests)
        pr.step("01-slugify")
        pr.step("02-other", file: "util.py", test: "python3 -c \"import util; assert util.X == 1\"")
        pr.reply(goodSlugify)
        pr.reply("X = 1\n")
        pr.reply("X = 1\n")
        let r = try pr.run(["run", "steps"])
        #expect(r.code == 1, "\(r.stdout)\(r.stderr)")
        #expect(r.stdout.contains("regression") && r.stdout.contains("01-slugify"))
        #expect(pr.read("util.py") == goodSlugify, "the breaking rewrite must be rolled back")
    }

    @Test func regressionIsRetriedWithTheReason() throws {
        let pr = Project()
        pr.write("test_util.py", slugifyTests)
        pr.step("01-slugify")
        pr.step("02-other", file: "util.py", test: "python3 -c \"import util; assert util.X == 1\"")
        pr.reply(goodSlugify)
        pr.reply("X = 1\n")
        pr.reply(goodSlugify + "X = 1\n")
        let r = try pr.run(["run", "steps"])
        #expect(r.code == 0, "\(r.stdout)\(r.stderr)")
        let third = pr.prompts[2]
        #expect(third.contains("regression"))
        #expect(third.components(separatedBy: "regression").dropFirst().joined().contains("slugify"))
    }
}

@Suite struct RetryQualityTests {
    @Test func identicalRetryIsNotRetested() throws {
        let pr = Project()
        pr.step("01-x", test: "python3 -c \"open('runs','a').write('x'); raise SystemExit(1)\"")
        pr.reply("x = 1\n")
        pr.reply("x = 1\n")
        let r = try pr.run(["run", "steps"])
        #expect(r.code == 1)
        #expect(pr.read("runs") == "x", "the identical retry must not run the tests again")
        #expect(r.stdout.contains("identical"))
    }

    @Test func notesIncludeTheExceptionLine() throws {
        let pr = Project()
        pr.write("test_util.py", slugifyTests)
        pr.step("01-slugify")
        pr.reply(badSlugify)
        pr.reply(goodSlugify)
        let r = try pr.run(["run", "steps"])
        #expect(r.stdout.contains("AssertionError") && r.stdout.contains("test_basic"))
    }

    @Test func failureReportListsEveryAttempt() throws {
        let pr = Project()
        pr.write("test_util.py", slugifyTests)
        pr.step("01-slugify")
        pr.reply(badSlugify)
        pr.reply("def slugify(title):\n    return title.lower()\n")
        let r = try pr.run(["run", "steps"])
        #expect(r.code == 1)
        #expect(r.stdout.contains("attempt 1 failed") && r.stdout.contains("attempt 2 failed"))
    }

    @Test func duplicateTopLevelDefinitionIsFlagged() throws {
        let pr = Project()
        pr.write("test_util.py", slugifyTests)
        pr.step("01-slugify")
        pr.reply("def slugify(t):\n    return 'x'\n\n" + goodSlugify)
        let r = try pr.run(["run", "steps"])
        #expect(r.code == 0, "\(r.stdout)\(r.stderr)")
        #expect(r.stdout.contains("duplicate") && r.stdout.contains("slugify"))
    }

    @Test func textReportHasSeconds() throws {
        let pr = Project()
        pr.write("test_util.py", slugifyTests)
        pr.step("01-slugify")
        pr.reply(goodSlugify)
        #expect(lines(try pr.run(["run", "steps"]).stdout)[0].contains("seconds"))
    }
}

@Suite struct HeaderAndSummaryTests {
    @Test func headerCommentsAreStripped() throws {
        let pr = Project()
        pr.write("test_util.py", slugifyTests)
        pr.write("steps/01-a.md", "file: util.py   # the one file\ntest: python3 -m unittest test_util  # exit 0 = pass\n---\n" + slugifySpec + "\n")
        pr.reply(goodSlugify)
        let r = try pr.run(["run", "steps"])
        #expect(r.code == 0, "\(r.stdout)\(r.stderr)")
        #expect(pr.exists("util.py") && !pr.exists("util.py   # the one file"))
    }

    @Test func zeroTestsRunIsWarned() throws {
        let pr = Project()
        pr.step("01-a", test: "python3 -c \"print('Ran 0 tests in 0.000s'); print('OK')\"")
        pr.reply("x = 1\n")
        let r = try pr.run(["run", "steps"])
        #expect(r.code == 0, "\(r.stdout)\(r.stderr)")
        #expect(r.stdout.contains("0 tests") && r.stdout.contains("warning"))
    }

    @Test func successSummaryLine() throws {
        let pr = Project()
        pr.write("test_util.py", slugifyTests)
        pr.step("01-slugify")
        pr.reply(goodSlugify)
        let last = lines(try pr.run(["run", "steps"]).stdout).last!
        #expect(last.contains("1/1 steps passed") && last.contains("2 tests") && last.contains("0 retries") && last.contains("0 warnings"))
    }
}

@Suite struct Round4Tests {
    @Test func alreadyPassingStepCountsItsTests() throws {
        let pr = Project()
        pr.write("test_util.py", slugifyTests)
        pr.write("util.py", goodSlugify)
        pr.step("01-slugify")
        let r = try pr.run(["run", "steps"])
        #expect(r.code == 0, "\(r.stdout)\(r.stderr)")
        #expect(lines(r.stdout).last!.contains("2 tests"))
        #expect(r.stdout.contains("0 warnings") && !r.stdout.contains("warning:"))
    }

    @Test func existingFailingFileIsReportedBeforeRegenerating() throws {
        let pr = Project()
        pr.write("test_util.py", slugifyTests)
        pr.write("util.py", badSlugify)
        pr.step("01-slugify")
        pr.reply(goodSlugify)
        let r = try pr.run(["run", "steps"])
        #expect(r.code == 0, "\(r.stdout)\(r.stderr)")
        #expect(r.stdout.contains("existing util.py failed its test"))
    }

    @Test func retriesSampleInsteadOfRepeating() throws {
        let pr = Project()
        pr.write("test_util.py", slugifyTests)
        pr.step("01-slugify")
        pr.reply(badSlugify)
        pr.reply(goodSlugify)
        try pr.run(["run", "steps"])
        #expect(pr.responds[0]["sampling"] as? String == "greedy")
        #expect(pr.responds[1]["sampling"] as? String == "default")
    }
}

let doc = (
    (1..<7).map { "Chapter \($0). " + String(repeating: "Nothing of note here. ", count: 30) }
        + ["Chapter 7. The sandbox is turned on with the enabled key. " + String(repeating: "Filler sentence. ", count: 30)]
        + (8..<12).map { "Chapter \($0). " + String(repeating: "More filler text here. ", count: 30) }
).joined(separator: "\n\n")

func found(_ quote: String) -> String {
    String(decoding: try! JSONSerialization.data(withJSONObject: ["found": true, "quote": quote]), as: UTF8.self)
}

let notFound = #"{"found": false, "quote": ""}"#

@Suite struct ReadTests {
    @Test func usage() throws {
        let pr = Project()
        #expect(try pr.run(["read", "nosuch.md", "--ask", "q"]).code == 2)
        pr.write("doc.md", doc)
        let r = try pr.run(["read", "doc.md"])
        #expect(r.code == 2 && r.stderr.contains("--ask"))
    }

    @Test func chunksAreSmallAndCoverTheFile() throws {
        let pr = Project()
        pr.write("doc.md", doc)
        for _ in 0..<40 { pr.reply(notFound) }
        let r = try pr.run(["read", "doc.md", "--ask", "How is the sandbox turned on?", "--chunk-tokens", "200"])
        #expect(r.code == 0, "\(r.stdout)\(r.stderr)")
        let chunks = pr.prompts
        #expect(chunks.count > 3)
        let joined = chunks.map { $0.components(separatedBy: "---\n").dropFirst().joined(separator: "---\n") }.joined()
        #expect(joined.replacingOccurrences(of: "\n", with: "") == doc.replacingOccurrences(of: "\n", with: ""))
        #expect(r.stdout.contains("no chunk matched"))
    }

    @Test func schemaAndQuestionAreSent() throws {
        let pr = Project()
        pr.write("doc.md", doc)
        pr.reply(found("turned on with the enabled key"))
        let r = try pr.run(["read", "doc.md", "--ask", "How is the sandbox turned on?", "--chunk-tokens", "100000"])
        #expect(r.code == 0, "\(r.stdout)\(r.stderr)")
        let rec = pr.responds[0]
        #expect(((rec["instructions"] as! String) + (rec["prompt"] as! String)).contains("How is the sandbox turned on?"))
        let schema = try JSONSerialization.jsonObject(with: Data((rec["schema"] as! String).utf8)) as! [String: Any]
        #expect(schema["x-order"] as? [String] == ["found", "quote"])
        #expect(r.stdout.contains("enabled key"))
    }

    @Test func abstentionsDroppedAndSurvivorsCiteLines() throws {
        let pr = Project()
        pr.write("doc.md", doc)
        for _ in 0..<40 { pr.reply(notFound) }
        try pr.run(["read", "doc.md", "--ask", "q", "--chunk-tokens", "200"])
        let chunks = pr.prompts
        let target = chunks.firstIndex { $0.contains("enabled key") }!
        let pr2 = Project()
        pr2.write("doc.md", doc)
        for i in chunks.indices { pr2.reply(i == target ? found("turned on with the enabled key") : notFound) }
        let r = try pr2.run(["read", "doc.md", "--ask", "q", "--chunk-tokens", "200"])
        #expect(r.code == 0, "\(r.stdout)\(r.stderr)")
        #expect(r.stdout.contains("1 of \(chunks.count) chunks"))
        #expect(r.stdout.contains("turned on with the enabled key") && r.stdout.contains("lines"))
    }

    @Test func answerWhoseQuoteIsNotInTheChunkIsDropped() throws {
        let pr = Project()
        pr.write("doc.md", doc)
        pr.reply(found("this text is not in the document"))
        let r = try pr.run(["read", "doc.md", "--ask", "q", "--chunk-tokens", "100000"])
        #expect(r.code == 0, "\(r.stdout)\(r.stderr)")
        #expect(r.stdout.contains("no chunk matched") && r.stdout.contains("1 dropped"))
    }

    @Test func jsonOutput() throws {
        let pr = Project()
        pr.write("doc.md", doc)
        pr.reply(found("enabled key"))
        let r = try pr.run(["read", "doc.md", "--ask", "q", "--chunk-tokens", "100000", "--json"])
        let d = try JSONSerialization.jsonObject(with: Data(r.stdout.utf8)) as! [String: Any]
        #expect(d["chunks"] as? Int == 1)
        let a = (d["answers"] as! [[String: Any]])[0]
        #expect(a["quote"] as? String == "enabled key" && a["lines"] != nil)
    }

    @Test func fmFailureOnAChunkIsExit1() throws {
        let pr = Project()
        pr.write("doc.md", doc)
        let r = try pr.run(["read", "doc.md", "--ask", "q", "--chunk-tokens", "100000"], respond: ["error": "other:Error: boom"], withReplies: false)
        #expect(r.code == 1, "\(r.stdout)\(r.stderr)")
        #expect(r.stderr.contains("boom"))
    }
}

@Suite struct SignalTests {
    @Test func sigtermExits1() throws {
        let pr = Project()
        pr.write("test_util.py", slugifyTests)
        pr.step("01-slugify")
        let script: [String: Any] = ["log": pr.path("fm.log"), "respond": ["delay": 10]]
        try JSONSerialization.data(withJSONObject: script).write(to: URL(fileURLWithPath: pr.path("fake.json")))
        let p = Process()
        p.executableURL = URL(fileURLWithPath: afmPath)
        p.arguments = ["run", "steps"]
        var e = ProcessInfo.processInfo.environment
        e["AFMUX_FAKE"] = pr.path("fake.json")
        p.environment = e
        p.currentDirectoryURL = pr.dir
        p.standardInput = FileHandle.nullDevice
        p.standardOutput = FileHandle.nullDevice
        let err = Pipe()
        p.standardError = err
        try p.run()
        for _ in 0..<50 where pr.responds.isEmpty { usleep(100_000) }
        p.terminate()
        p.waitUntilExit()
        #expect(p.terminationStatus == 1)
        #expect(String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).contains("interrupted"))
    }
}
