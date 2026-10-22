import Foundation

public struct Step: Equatable, Sendable {
    public var id: String
    public var path: String
    public var file: String
    public var test: String
    public var context: [String]
    public var spec: String
}

private let headerKeys = ["file", "test", "context"]
private let trailingComment = try! NSRegularExpression(pattern: "\\s+#")

func isFile(_ path: String) -> Bool {
    var dir: ObjCBool = false
    return FileManager.default.fileExists(atPath: path, isDirectory: &dir) && !dir.boolValue
}

func isDirectory(_ path: String) -> Bool {
    var dir: ObjCBool = false
    return FileManager.default.fileExists(atPath: path, isDirectory: &dir) && dir.boolValue
}

/// afmux parse_step.
public func parseStep(_ path: String) throws -> Step {
    let id = ((path as NSString).lastPathComponent as NSString).deletingPathExtension
    let text: String
    do {
        text = try String(contentsOfFile: path, encoding: .utf8)
    } catch {
        throw AfmError(.usage, "cannot read step \(path) (\(error.localizedDescription))")
    }
    let startsWithSeparator = text.hasPrefix("---\n")
    guard text.contains("\n---\n") || startsWithSeparator else {
        throw AfmError(.usage, "step \(id): no '---' line separating the header from the spec")
    }
    var header = ""
    var spec: String
    if startsWithSeparator {
        spec = String(text.dropFirst(4))
    } else {
        let r = text.range(of: "\n---\n")!
        header = String(text[..<r.lowerBound])
        spec = String(text[r.upperBound...])
    }
    var fields: [String: String] = [:]
    for line in header.components(separatedBy: "\n") {
        if line.stripped().isEmpty { continue }
        guard let colon = line.firstIndex(of: ":"), headerKeys.contains(line[..<colon].stripped()) else {
            throw AfmError(.usage, "step \(id): unknown header line \(pyRepr(line)) (allowed: \(headerKeys.joined(separator: ", ")))")
        }
        var value = String(line[line.index(after: colon)...])
        let ns = value as NSString
        if let m = trailingComment.firstMatch(in: value, range: NSRange(location: 0, length: ns.length)) {
            value = ns.substring(to: m.range.location)  // a trailing "  # comment" is allowed
        }
        fields[line[..<colon].stripped()] = value.stripped()
    }
    guard let file = fields["file"], !file.isEmpty else {
        throw AfmError(.usage, "step \(id): missing 'file:' header (the one file this step writes)")
    }
    guard let test = fields["test"], !test.isEmpty else {
        throw AfmError(.usage, "step \(id): missing 'test:' header (the command that judges the step)")
    }
    spec = spec.stripped()
    if spec.isEmpty { throw AfmError(.usage, "step \(id): the spec after '---' is empty") }
    let context = (fields["context"] ?? "").split(separator: ",", omittingEmptySubsequences: false)
        .map { $0.stripped() }.filter { !$0.isEmpty }
    return Step(id: id, path: path, file: file, test: test, context: context, spec: spec)
}

/// Every context file must exist now or be the file an earlier step writes.
public func checkContext(_ steps: [Step]) throws {
    var produced = Set<String>()
    for step in steps {
        for c in step.context where !isFile(c) && !produced.contains(c) {
            throw AfmError(.usage, "step \(step.id): context file not found: \(c) (it is not written by an earlier step either)")
        }
        produced.insert(step.file)
    }
}

public func loadSteps(_ directory: String) throws -> [Step] {
    guard isDirectory(directory) else { throw AfmError(.usage, "steps directory not found: \(directory)") }
    let names = ((try? FileManager.default.contentsOfDirectory(atPath: directory)) ?? []).filter { $0.hasSuffix(".md") }.sorted()
    if names.isEmpty { throw AfmError(.usage, "no step files (*.md) in \(directory)") }
    let steps = try names.map { try parseStep((directory as NSString).appendingPathComponent($0)) }
    try checkContext(steps)
    return steps
}
