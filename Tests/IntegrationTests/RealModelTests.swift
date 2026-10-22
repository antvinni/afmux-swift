import Foundation
import Testing

private let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
private let binary = root.appendingPathComponent(".build/debug/afm").path

private func run(_ args: [String], cwd: URL) throws -> (Int32, String, String) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: binary)
    p.arguments = args
    var e = ProcessInfo.processInfo.environment
    e.removeValue(forKey: "AFMUX_FAKE")
    p.environment = e
    p.currentDirectoryURL = cwd
    let out = Pipe(), err = Pipe()
    p.standardOutput = out
    p.standardError = err
    p.standardInput = FileHandle.nullDevice
    try p.run()
    let o = out.fileHandleForReading.readDataToEndOfFile(), r = err.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return (p.terminationStatus, String(decoding: o, as: UTF8.self), String(decoding: r, as: UTF8.self))
}

private func tmp() -> URL {
    let u = FileManager.default.temporaryDirectory.appendingPathComponent("afm-int-" + UUID().uuidString)
    try! FileManager.default.createDirectory(at: u.appendingPathComponent("steps"), withIntermediateDirectories: true)
    return u
}

private let realModelWorks: Bool = {
    guard FileManager.default.isExecutableFile(atPath: binary) else { return false }
    let dir = tmp()
    try? "hello\n".write(to: dir.appendingPathComponent("doc.md"), atomically: true, encoding: .utf8)
    return (try? run(["read", "doc.md", "--ask", "What does it say?"], cwd: dir).0) == 0
}()

@Suite(.enabled(if: realModelWorks, "on-device model not usable here"), .serialized)
struct RealModelTests {
    @Test func slugifyStepOnRealModel() throws {
        let dir = tmp()
        try """
        import unittest
        from util import slugify
        class T(unittest.TestCase):
            def test_basic(self): self.assertEqual(slugify("Hello, World!"), "hello-world")
            def test_empty(self): self.assertEqual(slugify("!!!"), "")

        """.write(to: dir.appendingPathComponent("test_util.py"), atomically: true, encoding: .utf8)
        try """
        file: util.py
        test: python3 -m unittest test_util
        ---
        Write a Python function `slugify(title)`. Lowercase the string, replace every run of characters that are not ASCII letters or digits with a single hyphen, and strip leading and trailing hyphens. Examples: slugify("Hello, World!") == "hello-world"; slugify("!!!") == "".

        """.write(to: dir.appendingPathComponent("steps/01-slugify.md"), atomically: true, encoding: .utf8)
        let (code, out, err) = try run(["run", "steps"], cwd: dir)
        #expect(code == 0, "\(out)\(err)")
        #expect(out.contains("pass"))
    }

    @Test func readFindsAnErrorInALogWithoutBlankLines() throws {
        let dir = tmp()
        var lines = (0..<3000).map { String(format: "2026-10-22T10:%02d:%02d INFO worker-%d processed batch %d", $0 / 60 % 60, $0 % 60, $0 % 9 + 1, $0) }
        lines[2400] = "2026-10-22T10:40:00 ERROR worker-3 disk quota exceeded on /var/data (used 98.7%)"
        try (lines.joined(separator: "\n") + "\n").write(to: dir.appendingPathComponent("app.log"), atomically: true, encoding: .utf8)
        let (code, out, err) = try run(["read", "app.log", "--ask", "Which error happened and on which path?"], cwd: dir)
        #expect(code == 0, "\(out)\(err)")
        #expect(out.contains("/var/data"), "\(out)")
    }
}
