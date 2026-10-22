import Foundation
import Testing

let packageRoot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
let afmPath = packageRoot.appendingPathComponent(".build/debug/afm").path

let goodSlugify = """
import re

def slugify(title):
    title = re.sub(r"[^a-z0-9]+", "-", title.lower())
    return title.strip("-")

"""
let badSlugify = """
def slugify(title):
    return title

"""
let slugifyTests = """
import unittest
from util import slugify
class T(unittest.TestCase):
    def test_basic(self): self.assertEqual(slugify("Hello, World!"), "hello-world")
    def test_empty(self): self.assertEqual(slugify("!!!"), "")

"""
let slugifySpec = "Write a Python function `slugify(title)` that lowercases, replaces runs of non-alphanumerics with one hyphen and strips hyphens."

struct Run {
    var code: Int32
    var stdout: String
    var stderr: String
}

/// afmux's test Project: a throwaway directory with a steps dir, scripted model replies and a log.
final class Project {
    let dir: URL
    var replies: [String] = []
    var fake: [String: Any] = [:]

    init() {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("afm-proj-" + UUID().uuidString)
        try! FileManager.default.createDirectory(at: dir.appendingPathComponent("steps"), withIntermediateDirectories: true)
    }

    deinit { try? FileManager.default.removeItem(at: dir) }

    func path(_ rel: String) -> String { dir.appendingPathComponent(rel).path }

    @discardableResult
    func write(_ rel: String, _ content: String) -> String {
        let url = dir.appendingPathComponent(rel)
        try! FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try! content.write(to: url, atomically: true, encoding: .utf8)
        return rel
    }

    func read(_ rel: String) -> String { (try? String(contentsOfFile: path(rel), encoding: .utf8)) ?? "" }
    func exists(_ rel: String) -> Bool { FileManager.default.fileExists(atPath: path(rel)) }

    @discardableResult
    func step(_ name: String, spec: String = slugifySpec, file: String? = "util.py", test: String? = "python3 -m unittest test_util",
              context: String? = nil, headerExtra: String = "") -> String {
        var lines: [String] = []
        if let file { lines.append("file: \(file)") }
        if let test { lines.append("test: \(test)") }
        if let context { lines.append("context: \(context)") }
        return write("steps/\(name).md", lines.joined(separator: "\n") + headerExtra + "\n---\n" + spec + "\n")
    }

    func reply(_ text: String) { replies.append(text) }

    /// Run afm in fake mode from the project directory. respond overrides merge into the script.
    @discardableResult
    func run(_ args: [String], respond: [String: Any] = [:], count: [String: Any] = [:], availability: String? = nil,
             withReplies: Bool = true) throws -> Run {
        var r: [String: Any] = withReplies ? ["replies": replies] : [:]
        r.merge(respond) { $1 }
        var script: [String: Any] = ["log": path("fm.log"), "respond": r, "count": count]
        if let availability { script["availability"] = availability }
        script.merge(fake) { $1 }
        try JSONSerialization.data(withJSONObject: script).write(to: URL(fileURLWithPath: path("fake.json")))
        let p = Process()
        p.executableURL = URL(fileURLWithPath: afmPath)
        p.arguments = args
        var e = ProcessInfo.processInfo.environment
        e["AFMUX_FAKE"] = path("fake.json")
        p.environment = e
        p.currentDirectoryURL = dir
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        p.standardInput = FileHandle.nullDevice
        try p.run()
        let o = out.fileHandleForReading.readDataToEndOfFile()
        let ee = err.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return Run(code: p.terminationStatus, stdout: String(decoding: o, as: UTF8.self), stderr: String(decoding: ee, as: UTF8.self))
    }

    var calls: [[String: Any]] {
        guard let text = try? String(contentsOfFile: path("fm.log"), encoding: .utf8) else { return [] }
        return text.split(separator: "\n").compactMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }
    }

    var responds: [[String: Any]] { calls.filter { $0["kind"] as? String == "respond" } }
    var prompts: [String] { responds.map { $0["prompt"] as? String ?? "" } }

    func clearLog() { try? FileManager.default.removeItem(atPath: path("fm.log")) }
}

func lines(_ s: String) -> [String] { s.components(separatedBy: "\n").filter { !$0.isEmpty } }
