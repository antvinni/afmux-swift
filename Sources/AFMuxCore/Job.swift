import Foundation

public struct Job: Equatable, Sendable {
    public var name: String
    public var instructions: String
    public var labels: [String]?
    public var schemaPath: String?

    public init(name: String, instructions: String, labels: [String]?, schemaPath: String?) {
        self.name = name
        self.instructions = instructions
        self.labels = labels
        self.schemaPath = schemaPath
    }
}

public let toolUseInstructions = "Answer the request. Use the tools to find the information you need. Reply with only the answer."

/// afmux's parse_labels.
public func parseLabels(_ text: String) throws -> [String] {
    let labels = text.split(separator: ",", omittingEmptySubsequences: false)
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
    if labels.contains(where: \.isEmpty) {
        throw AfmError(.usage, "empty label in --labels (labels are comma-separated and cannot contain commas)")
    }
    if Set(labels).count != labels.count {
        throw AfmError(.usage, "duplicate label in --labels")
    }
    for label in labels where label.contains(where: { "\"'\\".contains($0) }) {
        throw AfmError(.usage, "label \(pyRepr(label)): quotes and backslashes are not allowed in labels")
    }
    return labels
}

/// afmux's check_schema_file, minus the x-order requirement (plain JSON Schema is converted).
public func checkSchemaFile(_ path: String) throws {
    var isDir: ObjCBool = false
    guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir), !isDir.boolValue else {
        throw AfmError(.usage, "schema file not found: \(path)")
    }
    let obj: Any
    do {
        obj = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: path)))
    } catch {
        throw AfmError(.usage, "schema file \(path) is not valid JSON (\(error.localizedDescription))")
    }
    guard obj is [String: Any] else {
        throw AfmError(.usage, "schema file \(path) must be a JSON object")
    }
}

/// afmux's resolve_job.
public func resolveJob(_ o: Options) throws -> Job {
    guard let name = o.job, !name.isEmpty else { throw AfmError(.usage, usageLine) }
    var instructions: String
    if name == "ask" {
        guard let text = o.instructions, !text.isEmpty else {
            throw AfmError(.usage, "ask needs instructions as its argument")
        }
        instructions = text
    } else if let text = Presets.texts[name] {
        if let extra = o.instructions, !extra.isEmpty {
            throw AfmError(.usage, "unexpected argument \(pyRepr(extra)) (only ask takes instructions)")
        }
        instructions = text
    } else {
        throw AfmError(.usage, "unknown preset \(pyRepr(name)); run afm --list")
    }
    var labels: [String]?
    if name == "classify" {
        guard let raw = o.labels, !raw.isEmpty else { throw AfmError(.usage, "classify needs --labels a,b,c") }
        if let schema = o.schema, !schema.isEmpty {
            throw AfmError(.usage, "--schema is not allowed with classify (its schema is generated)")
        }
        labels = try parseLabels(raw)
        instructions = instructions.replacingOccurrences(of: "{labels}", with: labels!.joined(separator: ", "))
    } else if let raw = o.labels, !raw.isEmpty {
        throw AfmError(.usage, "--labels is only for classify")
    }
    if name == "extract" && (o.schema ?? "").isEmpty {
        throw AfmError(.usage, "extract needs --schema FILE")
    }
    if name == "commit-msg" && o.chunk {
        throw AfmError(.usage, "--chunk is not allowed with commit-msg; pipe a smaller diff")
    }
    if let schema = o.schema, !schema.isEmpty {
        try checkSchemaFile(schema)
    }
    return Job(name: name, instructions: instructions, labels: labels, schemaPath: o.schema)
}

/// Usage rules afmux-swift adds on top of afmux's.
public func checkNewCombos(_ o: Options) throws {
    if o.chunk && o.session != nil { throw AfmError(.usage, "--chunk is not allowed with --session") }
    if o.chunk && o.toolsOn { throw AfmError(.usage, "--chunk is not allowed with tools") }
}

/// Instructions and prompt for one call (spec: "Instructions and prompt for each call shape").
public func callShape(job: Job, input: String?) -> (instructions: String, prompt: String) {
    if let input { return (job.instructions, input) }
    return (toolUseInstructions, job.instructions)
}
