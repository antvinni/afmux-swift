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
