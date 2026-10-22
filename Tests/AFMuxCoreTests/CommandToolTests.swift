import Foundation
import FoundationModels
import Testing
@testable import AFMuxCore

private func toolsFile(_ json: String) throws -> String {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("tools-\(UUID().uuidString).json")
    try json.write(to: url, atomically: true, encoding: .utf8)
    return url.path
}

private func loadError(_ json: String) -> String? {
    do { _ = try loadToolsFile(try toolsFile(json)); return nil } catch let e as AfmError { return e.message } catch { return "\(error)" }
}

@Test func substitutionRendersEachType() throws {
    let args = try GeneratedContent(json: #"{"s":"a b","n":3,"f":0.5,"b":true,"l":[1,"x"],"brace":"{n}"}"#)
    let argv = substitute(["cmd", "{s}", "-n{n}", "{f}", "{b}", "{l}", "{missing}", "{unknown_name}", "{brace}"],
                          arguments: args, names: ["s", "n", "f", "b", "l", "missing", "brace"])
    #expect(argv == ["cmd", "a b", "-n3", "0.5", "true", "[1,\"x\"]", "", "{unknown_name}", "{n}"])
}

@Test func toolsFileValidation() {
    #expect(loadError("[]")?.hasSuffix("must be an object with a \"tools\" array") == true)
    #expect(loadError(#"{"tools":[{"name":"Bad"}]}"#) == "tool #1: name must match [a-z][a-z0-9_]*")
    #expect(loadError(#"{"tools":[{"name":"grep","description":"d","command":["x"]}]}"#) == "tool grep: name is taken by a built-in tool")
    #expect(loadError(#"{"tools":[{"name":"t","description":"d","command":["x"]},{"name":"t","description":"d","command":["x"]}]}"#) == "tool t: duplicate name")
    #expect(loadError(#"{"tools":[{"name":"t","command":["x"]}]}"#) == "tool t: description is required")
    #expect(loadError(#"{"tools":[{"name":"t","description":"d","command":[]}]}"#) == "tool t: command must be a non-empty array of strings")
    #expect(loadError(#"{"tools":[{"name":"t","description":"d","command":["x"],"arguments":{"type":"object","oneOf":[]}}]}"#) == "tool t: arguments: unsupported keyword 'oneOf'")
}

@Test func commandToolRunsAndReports() async throws {
    let specs = try loadToolsFile(try toolsFile(#"{"tools":[{"name":"say","description":"echo a message","arguments":{"type":"object","properties":{"msg":{"type":"string"}},"required":["msg"]},"command":["/bin/sh","-c","echo \"$1\"; echo warn >&2; exit 2","_","{msg}"]}]}"#))
    let ctx = ToolContext(counter: FakeBackend(script: FakeScript()).counter, maxCalls: 8, outputBudget: 600, toolTimeout: 5)
    let out = try await commandTool(specs[0], context: ctx).call(arguments: GeneratedContent(json: #"{"msg":"hi there"}"#))
    #expect(out == "exit 2\nstdout:\nhi there\nstderr:\nwarn")
}
