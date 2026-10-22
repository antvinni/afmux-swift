import io, json, os, tempfile, unittest
from contextlib import redirect_stdout
from cli import count_words, main

def run(text, args):
    d = tempfile.mkdtemp(); p = os.path.join(d, "t.txt")
    with open(p, "w") as f: f.write(text)
    buf = io.StringIO()
    with redirect_stdout(buf): code = main([p] + args)
    return code, buf.getvalue()

class T(unittest.TestCase):
    def test_count(self): self.assertEqual(count_words("A a b don't"), {"a": 2, "b": 1, "don't": 1})
    def test_top_text(self): self.assertEqual(run("b a a c b a", ["--top", "2"]), (0, "a 3\nb 2\n"))
    def test_ties(self): self.assertEqual(run("z y x", ["--top", "2"]), (0, "x 1\ny 1\n"))
    def test_json(self):
        code, out = run("b a a", ["--json"])
        self.assertEqual(code, 0)
        self.assertEqual(json.loads(out), {"a": 2, "b": 1})
