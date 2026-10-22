import Foundation
import FoundationModels
import Testing
@testable import AFMuxCore

private func json(_ s: String) throws -> GeneratedContent { try GeneratedContent(json: s) }

@Test func compactFormatting() throws {
    #expect(compactJSON(try json(#"{"a": 1, "b": "two"}"#), topOrder: ["a", "b"]) == #"{"a":1,"b":"two"}"#)
    #expect(compactJSON(try json(#"{"ratio": 0.25, "n": 12, "big": 1e20}"#), topOrder: ["n", "ratio", "big"]) == #"{"n":12,"ratio":0.25,"big":100000000000000000000}"#)
    #expect(compactJSON(try json(#"{"s": "caf\u00e9 / \"q\" \n"}"#), topOrder: ["s"]) == "{\"s\":\"caf\u{e9} / \\\"q\\\" \\n\"}")
    #expect(compactJSON(try json(#"{"k": true, "l": [1, null, "x"]}"#), topOrder: ["k", "l"]) == #"{"k":true,"l":[1,null,"x"]}"#)
}

@Test func schemaOrderThenOthers() throws {
    let c = try json("{\"b\": \"two\", \"a\": 1}")
    #expect(compactJSON(c, topOrder: ["a"]).hasPrefix(#"{"a":1,"#))
}

@Test func fmFormatDecodes() throws {
    let text = #"{"title":"T","type":"object","properties":{"a":{"type":"integer"}},"required":["a"],"x-order":["a"],"additionalProperties":false}"#
    let s = try SchemaLoader.load(Data(text.utf8))
    #expect(s.name == "T")
    #expect(SchemaLoader.order(s) == ["a"])
}

@Test func plainSchemaConverts() throws {
    let text = #"{"type":"object","properties":{"z":{"type":"string"},"b":{"type":"number"},"a":{"type":"boolean","description":"flag"},"tags":{"type":"array","items":{"type":"string"},"maxItems":3},"kind":{"type":"string","enum":["x","y"]},"inner":{"type":"object","properties":{"q":{"type":"integer"}},"required":["q"]}},"required":["z"]}"#
    let s = try SchemaLoader.load(Data(text.utf8))
    #expect(SchemaLoader.order(s) == ["z", "a", "b", "inner", "kind", "tags"])
    #expect(SchemaLoader.jsonText(s).contains(#""enum":["x","y"]"#))
}

@Test func converterProblems() {
    func problem(_ text: String) -> String? {
        do { _ = try SchemaLoader.load(Data(text.utf8)); return nil } catch let p as SchemaProblem { return p.message } catch { return "\(error)" }
    }
    #expect(problem(#"{"type":"object","anyOf":[]}"#) == "unsupported keyword 'anyOf'")
    #expect(throws: SchemaProblem(message: #"the top level must have "type": "object""#)) {
        _ = try SchemaLoader.convert(["type": "string"])
    }
    #expect(problem(#"{"type":"object","properties":{"a":{"type":"date"}}}"#) == "unsupported type 'date' at a")
    #expect(problem(#"{"type":"object","properties":{"a":{"type":"array"}}}"#) == #"array needs "items" at a"#)
    #expect(problem("[1]") == "not a JSON object")
}

@Test func classifySchemaHasEnum() {
    let text = SchemaLoader.jsonText(SchemaLoader.classify(labels: ["bug", "feature", "question"]))
    let obj = try! JSONSerialization.jsonObject(with: Data(text.utf8)) as! [String: Any]
    let label = (obj["properties"] as! [String: Any])["label"] as! [String: Any]
    #expect(label["enum"] as? [String] == ["bug", "feature", "question"])
}
