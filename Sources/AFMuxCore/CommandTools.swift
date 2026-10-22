import Foundation
import FoundationModels

public struct ToolSpec: Sendable {
    public var name: String
    public var description: String
    public var parameters: GenerationSchema
    public var argumentNames: [String]
    public var command: [String]
}

public let builtinNames: Set<String> = ["read_file", "grep", "list_dir"]

public func loadToolsFile(_ path: String) throws -> [ToolSpec] {
    guard let data = FileManager.default.contents(atPath: path) else {
        throw AfmError(.usage, "tools file not found: \(path)")
    }
    let root: Any
    do {
        root = try JSONSerialization.jsonObject(with: data)
    } catch {
        throw AfmError(.usage, "tools file \(path) is not valid JSON (\(error.localizedDescription))")
    }
    guard let obj = root as? [String: Any], let list = obj["tools"] as? [Any] else {
        throw AfmError(.usage, "tools file \(path) must be an object with a \"tools\" array")
    }
    var specs: [ToolSpec] = []
    var seen = Set<String>()
    for (k, item) in list.enumerated() {
        guard let t = item as? [String: Any] else { throw AfmError(.usage, "tool #\(k + 1): must be an object") }
        guard let name = t["name"] as? String, name.range(of: "^[a-z][a-z0-9_]*$", options: .regularExpression) != nil else {
            throw AfmError(.usage, "tool #\(k + 1): name must match [a-z][a-z0-9_]*")
        }
        if builtinNames.contains(name) { throw AfmError(.usage, "tool \(name): name is taken by a built-in tool") }
        if !seen.insert(name).inserted { throw AfmError(.usage, "tool \(name): duplicate name") }
        guard let description = t["description"] as? String, !description.isEmpty else {
            throw AfmError(.usage, "tool \(name): description is required")
        }
        guard let command = t["command"] as? [String], !command.isEmpty else {
            throw AfmError(.usage, "tool \(name): command must be a non-empty array of strings")
        }
        var arguments: [String: Any] = ["type": "object", "properties": [String: Any]()]
        if let given = t["arguments"] {
            guard let dict = given as? [String: Any] else {
                throw AfmError(.usage, "tool \(name): arguments must be a JSON Schema object")
            }
            arguments = dict
        }
        if arguments["title"] == nil { arguments["title"] = name }
        let parameters: GenerationSchema
        do {
            parameters = try SchemaLoader.load(try JSONSerialization.data(withJSONObject: arguments))
        } catch let p as SchemaProblem {
            throw AfmError(.usage, "tool \(name): arguments: \(p.message)")
        }
        let names = Array(((arguments["properties"] as? [String: Any]) ?? [:]).keys)
        specs.append(ToolSpec(name: name, description: description, parameters: parameters, argumentNames: names, command: command))
    }
    return specs
}

private let placeholder = try! NSRegularExpression(pattern: "\\{([A-Za-z0-9_]+)\\}")

/// Replace {name} in each argv element, in one pass, for declared argument names only.
public func substitute(_ command: [String], arguments: GeneratedContent, names: [String]) -> [String] {
    command.map { element in
        let ns = element as NSString
        var out = ""
        var pos = 0
        for m in placeholder.matches(in: element, range: NSRange(location: 0, length: ns.length)) {
            out += ns.substring(with: NSRange(location: pos, length: m.range.location - pos))
            let key = ns.substring(with: m.range(at: 1))
            out += names.contains(key) ? render(arguments, key) : ns.substring(with: m.range)
            pos = NSMaxRange(m.range)
        }
        return out + ns.substring(from: pos)
    }
}

private func render(_ arguments: GeneratedContent, _ key: String) -> String {
    guard case .structure(let props, _) = arguments.kind, let value = props[key] else { return "" }
    switch value.kind {
    case .string(let s): return s
    case .null: return ""
    default: return compactJSON(value)
    }
}

public func commandTool(_ spec: ToolSpec, context: ToolContext) -> AfmTool {
    AfmTool(name: spec.name, description: spec.description, parameters: spec.parameters, context: context) { args in
        let argv = substitute(spec.command, arguments: args, names: spec.argumentNames)
        let r = await runProcess(argv, timeout: context.toolTimeout)
        if r.timedOut { return ToolOutput("timed out after \(pyG(context.toolTimeout)) s") }
        return ToolOutput("exit \(r.status)\nstdout:\n\(r.stdout.rstripped())\nstderr:\n\(r.stderr.rstripped())")
    }
}
