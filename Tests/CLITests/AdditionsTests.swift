import Foundation
import Testing

/// afmux-swift additions (MinionS ideas) and the read-mode fixes over the reference.

@Suite struct SamplesTests {
    @Test func samplesAreTriedBeforeTheRetry() throws {
        let pr = Project()
        pr.write("test_util.py", slugifyTests)
        pr.step("01-slugify")
        pr.reply(badSlugify)
        pr.reply("def slugify(title):\n    return title.lower()\n")
        pr.reply(goodSlugify)
        let r = try pr.run(["run", "steps", "--samples", "3"])
        #expect(r.code == 0, "\(r.stdout)\(r.stderr)")
        #expect(pr.responds.map { $0["sampling"] as! String } == ["greedy", "seeded:1", "seeded:2"])
        #expect(!pr.prompts[2].contains("Your previous implementation"), "a sample uses the first prompt")
        #expect(pr.read("util.py") == goodSlugify)
    }

    @Test func identicalSampleIsNotRetested() throws {
        let pr = Project()
        pr.step("01-x", test: "python3 -c \"open('runs','a').write('x'); raise SystemExit(1)\"")
        pr.reply("x = 1\n")
        pr.reply("x = 1\n")
        pr.reply("x = 2\n")
        let r = try pr.run(["run", "steps", "--samples", "2"])
        #expect(r.code == 1)
        #expect(pr.read("runs") == "xx", "the identical sample is skipped, the retry is tested")
        #expect(r.stdout.contains("attempt 2 produced identical code"))
    }

    @Test func defaultIsOneSampleLikeAfmux() throws {
        let pr = Project()
        pr.write("test_util.py", slugifyTests)
        pr.step("01-slugify")
        pr.reply(badSlugify)
        pr.reply(goodSlugify)
        try pr.run(["run", "steps"])
        #expect(pr.responds.map { $0["sampling"] as! String } == ["greedy", "default"])
    }

    @Test func badSamplesIsUsage() throws {
        let pr = Project()
        pr.step("01-a")
        let r = try pr.run(["run", "steps", "--samples", "0"])
        #expect(r.code == 2 && r.stderr.contains("--samples must be at least 1"))
    }
}

let twoFunctionSpec = """
Module util.py.

slugify(s): lowercase, each run of characters other than a-z and 0-9 becomes one hyphen, strip hyphens from both ends.
Examples: slugify("Hello, World!") == "hello-world".

double(x): return x * 2.
"""

let twoFunctionTests = """
import unittest
from util import slugify, double
class T(unittest.TestCase):
    def test_slug(self): self.assertEqual(slugify("Hello, World!"), "hello-world")
    def test_double(self): self.assertEqual(double(4), 8)

"""

@Suite struct SplitTests {
    @Test func functionsAreGeneratedOneAtATimeAndAssembled() throws {
        let pr = Project()
        pr.write("test_util.py", twoFunctionTests)
        pr.step("01-util", spec: twoFunctionSpec)
        pr.reply("import re\n\ndef slugify(s):\n    return re.sub(r\"[^a-z0-9]+\", \"-\", s.lower()).strip(\"-\")\n")
        pr.reply("import re\n\ndef double(x):\n    return x * 2\n")
        let r = try pr.run(["run", "steps", "--split"])
        #expect(r.code == 0, "\(r.stdout)\(r.stderr)")
        #expect(pr.responds.count == 2)
        #expect((pr.responds[0]["instructions"] as! String).contains("function slugify"))
        #expect(pr.prompts[0].contains("Module util.py.") && !pr.prompts[0].contains("double(x)"))
        #expect(pr.prompts[1].contains("Already written in this module") && pr.prompts[1].contains("def slugify"))
        let file = pr.read("util.py")
        #expect(file.hasPrefix("import re\n\n\ndef slugify"))
        #expect(file.components(separatedBy: "import re").count == 2, "imports appear once")
        #expect(r.stdout.contains("generated 2 functions one at a time"))
    }

    @Test func failingAssemblyFallsBackToTheNormalRetry() throws {
        let pr = Project()
        pr.write("test_util.py", twoFunctionTests)
        pr.step("01-util", spec: twoFunctionSpec)
        pr.reply("def slugify(s):\n    return s\n")
        pr.reply("def double(x):\n    return x * 2\n")
        pr.reply("import re\n\ndef slugify(s):\n    return re.sub(r\"[^a-z0-9]+\", \"-\", s.lower()).strip(\"-\")\n\ndef double(x):\n    return x * 2\n")
        let r = try pr.run(["run", "steps", "--split"])
        #expect(r.code == 0, "\(r.stdout)\(r.stderr)")
        #expect(pr.prompts[2].contains("Your previous implementation") && pr.prompts[2].contains("return s"))
    }

    @Test func singleFunctionSpecIsNotSplit() throws {
        let pr = Project()
        pr.write("test_util.py", slugifyTests)
        pr.step("01-slugify")
        pr.reply(goodSlugify)
        let r = try pr.run(["run", "steps", "--split"])
        #expect(r.code == 0, "\(r.stdout)\(r.stderr)")
        #expect((pr.responds[0]["instructions"] as! String).hasPrefix("You are a code implementer. Reply with source code only"))
    }

    @Test func existingFileIsNotSplit() throws {
        let pr = Project()
        pr.write("test_util.py", twoFunctionTests)
        pr.write("util.py", "# old\n")
        pr.step("01-util", spec: twoFunctionSpec)
        pr.reply("import re\n\ndef slugify(s):\n    return re.sub(r\"[^a-z0-9]+\", \"-\", s.lower()).strip(\"-\")\n\ndef double(x):\n    return x * 2\n")
        let r = try pr.run(["run", "steps", "--split"])
        #expect(r.code == 0, "\(r.stdout)\(r.stderr)")
        #expect(pr.responds.count == 1)
    }
}

@Suite struct ReadAdditionsTests {
    @Test func severalQuestionsAreAskedOfEveryChunk() throws {
        let pr = Project()
        pr.write("doc.md", doc)
        pr.reply(found("turned on with the enabled key"))
        pr.reply(notFound)
        let r = try pr.run(["read", "doc.md", "--ask", "How is the sandbox turned on?", "--ask", "Who wrote it?", "--chunk-tokens", "100000"])
        #expect(r.code == 0, "\(r.stdout)\(r.stderr)")
        #expect(pr.responds.count == 2)
        #expect(r.stdout.contains("Q1: How is the sandbox turned on?") && r.stdout.contains("Q2: Who wrote it?"))
        #expect(r.stdout.contains("enabled key") && r.stdout.contains("no chunk matched"))
        let j = try pr.run(["read", "doc.md", "--ask", "a", "--ask", "b", "--chunk-tokens", "100000", "--json"])
        let d = try JSONSerialization.jsonObject(with: Data(j.stdout.utf8)) as! [String: Any]
        #expect((d["questions"] as! [[String: Any]]).count == 2)
    }

    @Test func linesRestrictTheReadAndKeepNumbering() throws {
        let pr = Project()
        pr.write("doc.md", doc)
        pr.reply(found("turned on with the enabled key"))
        let r = try pr.run(["read", "doc.md", "--ask", "q", "--lines", "13-15", "--chunk-tokens", "100000"])
        #expect(r.code == 0, "\(r.stdout)\(r.stderr)")
        #expect(pr.prompts[0].hasPrefix("Chunk lines 13-15 of doc.md"))
        #expect(pr.prompts[0].contains("Chapter 7."))
        #expect(r.stdout.contains("[lines 13-13]"))
        #expect(try pr.run(["read", "doc.md", "--ask", "q", "--lines", "9-3"]).code == 2)
    }

    @Test func paragraphLargerThanAChunkIsSplitAtLines() throws {
        let pr = Project()
        let log = (1...400).map { "2026-10-22 INFO line \($0) of a log with no blank lines" }.joined(separator: "\n")
        pr.write("app.log", log)
        for _ in 0..<100 { pr.reply(notFound) }
        let r = try pr.run(["read", "app.log", "--ask", "q", "--chunk-tokens", "500"])
        #expect(r.code == 0, "\(r.stdout)\(r.stderr)")
        #expect(pr.responds.count > 4)
        #expect(pr.prompts[0].hasPrefix("Chunk lines 1-"))
        let joined = pr.prompts.map { $0.components(separatedBy: "---\n").dropFirst().joined(separator: "---\n") }.joined(separator: "\n")
        #expect(joined == log, "chunks cover the file in order")
    }

    @Test func oneFailedChunkDoesNotEndTheRead() throws {
        let pr = Project()
        pr.write("doc.md", doc)
        for _ in 0..<40 { pr.reply(found("turned on with the enabled key")) }
        let r = try pr.run(["read", "doc.md", "--ask", "q", "--chunk-tokens", "200"], respond: ["error": "guardrail", "failOnCall": 1])
        #expect(r.code == 0, "\(r.stdout)\(r.stderr)")
        #expect(r.stdout.contains("1 failed: chunk lines 1-1"))
        #expect(r.stdout.contains("enabled key"))
    }

    @Test func quoteIsCitedByItsOwnLines() throws {
        let pr = Project()
        pr.write("notes.md", "intro line\nsecond line\nthe key fact is here\nlast line\n")
        pr.reply(found("the key fact is here"))
        let r = try pr.run(["read", "notes.md", "--ask", "q"])
        #expect(r.code == 0, "\(r.stdout)\(r.stderr)")
        #expect(r.stdout.contains("[lines 3-3] \"the key fact is here\""))
    }
}
