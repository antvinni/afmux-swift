import Foundation
import FoundationModels

private func schema(_ json: String) -> GenerationSchema {
    let obj = try! JSONSerialization.jsonObject(with: Data(json.utf8)) as! [String: Any]
    return try! SchemaLoader.convert(obj)
}

public func builtinTools(context: ToolContext) -> [AfmTool] {
    [readFile(context), grep(context), listDir(context)]
}

private func readFile(_ ctx: ToolContext) -> AfmTool {
    AfmTool(name: "read_file", description: "Read lines of a text file. Returns numbered lines.",
            parameters: schema(#"{"title":"ReadFile","type":"object","properties":{"path":{"type":"string","description":"file path, relative to the working directory or absolute"},"start_line":{"type":"integer","description":"first line to return, 1-based"},"end_line":{"type":"integer","description":"last line to return, inclusive"}},"required":["path"],"x-order":["path","start_line","end_line"]}"#),
            context: ctx) { args in
        let path = stringArg(args, "path") ?? ""
        guard let data = FileManager.default.contents(atPath: path) else { return ToolOutput("error: cannot read \(path)") }
        var lines = String(decoding: data, as: UTF8.self).components(separatedBy: "\n")
        if lines.last == "" { lines.removeLast() }
        if lines.isEmpty { return ToolOutput("(empty file)") }
        let start = max(1, intArg(args, "start_line") ?? 1)
        let end = min(lines.count, intArg(args, "end_line") ?? lines.count)
        if start > lines.count { return ToolOutput("error: \(path) has \(lines.count) lines") }
        if end < start { return ToolOutput("error: end_line is before start_line") }
        let body = (start...end).map { "\($0)\t\(lines[$0 - 1])" }.joined(separator: "\n")
        return ToolOutput(body) { omitted, kept in
            "[truncated: \(omitted) more lines; call read_file with start_line=\(start + kept)]"
        }
    }
}

private func grep(_ ctx: ToolContext) -> AfmTool {
    AfmTool(name: "grep", description: "Search files under a path for an extended regular expression. Returns file:line:text.",
            parameters: schema(#"{"title":"Grep","type":"object","properties":{"pattern":{"type":"string","description":"extended regular expression"},"path":{"type":"string","description":"file or directory to search"},"glob":{"type":"string","description":"only files whose name matches, e.g. *.swift"}},"required":["pattern","path"],"x-order":["pattern","path","glob"]}"#),
            context: ctx) { args in
        var argv = ["/usr/bin/grep", "-rnIE", "--exclude-dir=.git"]
        if let glob = stringArg(args, "glob"), !glob.isEmpty { argv.append("--include=\(glob)") }
        argv += ["-e", stringArg(args, "pattern") ?? "", "--", stringArg(args, "path") ?? "."]
        let r = await runProcess(argv, timeout: ctx.toolTimeout)
        if r.timedOut { return ToolOutput("timed out after \(pyG(ctx.toolTimeout)) s") }
        switch r.status {
        case 0: return ToolOutput(r.stdout.rstripped())
        case 1: return ToolOutput("no matches")
        default: return ToolOutput("error: " + r.stderr.rstripped())
        }
    }
}

private func listDir(_ ctx: ToolContext) -> AfmTool {
    AfmTool(name: "list_dir", description: "List a directory. Directories end with /.",
            parameters: schema(#"{"title":"ListDir","type":"object","properties":{"path":{"type":"string","description":"directory, relative to the working directory or absolute"}},"required":["path"]}"#),
            context: ctx) { args in
        let path = stringArg(args, "path") ?? "."
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: path) else {
            return ToolOutput("error: cannot list \(path)")
        }
        let lines = names.sorted().map { name -> String in
            var isDir: ObjCBool = false
            FileManager.default.fileExists(atPath: (path as NSString).appendingPathComponent(name), isDirectory: &isDir)
            return isDir.boolValue ? name + "/" : name
        }
        return ToolOutput(lines.isEmpty ? "(empty directory)" : lines.joined(separator: "\n"))
    }
}
