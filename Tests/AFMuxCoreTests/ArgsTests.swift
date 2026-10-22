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
