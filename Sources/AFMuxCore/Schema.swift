import Foundation
import FoundationModels

public struct SchemaProblem: Error, Equatable {
    public var message: String
}

private let allowedKeys: Set<String> = [
    "type", "properties", "required", "items", "minItems", "maxItems", "enum",
    "description", "title", "additionalProperties", "x-order",
]

public enum SchemaLoader {
    /// fm's own format first (it needs x-order), then plain JSON Schema through the converter.
    public static func load(_ data: Data) throws -> GenerationSchema {
        if let schema = try? JSONDecoder().decode(GenerationSchema.self, from: data) { return schema }
        guard let obj = try? JSONSerialization.jsonObject(with: data), let dict = obj as? [String: Any] else {
            throw SchemaProblem(message: "not a JSON object")
        }
        return try convert(dict)
    }

    public static func convert(_ root: [String: Any]) throws -> GenerationSchema {
        guard root["type"] as? String == "object" else {
            throw SchemaProblem(message: #"the top level must have "type": "object""#)
        }
        var names = Set<String>()
        let dynamic = try node(root, name: (root["title"] as? String) ?? "Output", path: "", names: &names)
        do {
            return try GenerationSchema(root: dynamic, dependencies: [])
        } catch {
            throw SchemaProblem(message: (error as? LocalizedError)?.errorDescription ?? "\(error)")
        }
    }

    public static func classify(labels: [String]) -> GenerationSchema {
        let root = DynamicGenerationSchema(name: "Classification", properties: [
            .init(name: "label", schema: DynamicGenerationSchema(name: "Label", anyOf: labels)),
        ])
        return try! GenerationSchema(root: root, dependencies: [])
    }

    /// The schema's top-level x-order, for output key order.
    public static func order(_ schema: GenerationSchema) -> [String] {
        guard let data = try? JSONEncoder().encode(schema),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let order = obj["x-order"] as? [String] else { return [] }
        return order
    }

    /// Stable JSON text of a schema, for the fake backend's log and counter.
    public static func jsonText(_ schema: GenerationSchema) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return String(decoding: (try? encoder.encode(schema)) ?? Data(), as: UTF8.self)
    }

    private static func node(_ obj: [String: Any], name: String, path: String, names: inout Set<String>) throws -> DynamicGenerationSchema {
        let at = path.isEmpty ? "" : " at \(path)"
        if let key = obj.keys.sorted().first(where: { !allowedKeys.contains($0) }) {
            throw SchemaProblem(message: "unsupported keyword \(pyRepr(key))\(at)")
        }
        let description = obj["description"] as? String
        if let values = obj["enum"] {
            guard let strings = values as? [String], !strings.isEmpty else {
                throw SchemaProblem(message: "enum must be a non-empty list of strings\(at)")
            }
            return DynamicGenerationSchema(name: unique(name, &names), description: description, anyOf: strings)
        }
        guard let type = obj["type"] as? String else { throw SchemaProblem(message: #"missing "type""# + at) }
        switch type {
        case "string": return DynamicGenerationSchema(type: String.self)
        case "integer": return DynamicGenerationSchema(type: Int.self)
        case "number": return DynamicGenerationSchema(type: Double.self)
        case "boolean": return DynamicGenerationSchema(type: Bool.self)
        case "array":
            guard let items = obj["items"] as? [String: Any] else { throw SchemaProblem(message: #"array needs "items""# + at) }
            let child = try node(items, name: name + "Item", path: path + "[]", names: &names)
            return DynamicGenerationSchema(arrayOf: child, minimumElements: obj["minItems"] as? Int, maximumElements: obj["maxItems"] as? Int)
        case "object":
            let props = obj["properties"] as? [String: Any] ?? [:]
            let required = obj["required"] as? [String] ?? []
            let order = (obj["x-order"] as? [String])
                ?? (required.filter { props[$0] != nil } + props.keys.filter { !required.contains($0) }.sorted())
            var properties: [DynamicGenerationSchema.Property] = []
            for key in order {
                let childPath = path.isEmpty ? key : path + "." + key
                guard let child = props[key] as? [String: Any] else {
                    throw SchemaProblem(message: "property \(pyRepr(key)) must be an object\(at)")
                }
                let schema = try node(child, name: name + "_" + key, path: childPath, names: &names)
                properties.append(.init(name: key, description: child["description"] as? String, schema: schema, isOptional: !required.contains(key)))
            }
            return DynamicGenerationSchema(name: unique(name, &names), description: description, properties: properties)
        default:
            throw SchemaProblem(message: "unsupported type \(pyRepr(type))\(at)")
        }
    }

    private static func unique(_ name: String, _ names: inout Set<String>) -> String {
        var candidate = name
        var k = 2
        while names.contains(candidate) {
            candidate = "\(name)\(k)"
            k += 1
        }
        names.insert(candidate)
        return candidate
    }
}
